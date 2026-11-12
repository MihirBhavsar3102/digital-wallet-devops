import { EventEmitter } from 'node:events';
import { createRequestLogger } from './request-logger';

type Call = { level: 'log' | 'warn' | 'error'; message: any; context?: string };

function setup(clockMs: number[] = [0, 12.345]) {
  const calls: Call[] = [];
  const logger = {
    log: (message: any, context?: string) =>
      calls.push({ level: 'log', message, context }),
    warn: (message: any, context?: string) =>
      calls.push({ level: 'warn', message, context }),
    error: (message: any, context?: string) =>
      calls.push({ level: 'error', message, context }),
  };
  const ticks = [...clockMs];
  const middleware = createRequestLogger(logger, () =>
    BigInt(Math.round((ticks.shift() ?? 0) * 1e6)),
  );

  // A request goes through the middleware and the response finishes with the given status.
  const run = (
    req: Record<string, unknown>,
    status: number,
  ): { res: any; next: jest.Mock } => {
    const res: any = new EventEmitter();
    res.statusCode = status;
    res.headers = {} as Record<string, string>;
    res.setHeader = (name: string, value: string) => {
      res.headers[name.toLowerCase()] = value;
    };
    const next = jest.fn();
    middleware(
      { method: 'GET', headers: {}, url: '/', ...req } as any,
      res,
      next,
    );
    res.emit('finish');
    return { res, next };
  };

  return { calls, run };
}

describe('createRequestLogger', () => {
  it('passes the request on', () => {
    const { run } = setup();

    const { next } = run({ originalUrl: '/api/accounts' }, 200);

    expect(next).toHaveBeenCalledTimes(1);
  });

  it('logs the method, path, status and duration once the response has finished', () => {
    const { calls, run } = setup([0, 12.345]);

    run({ method: 'POST', originalUrl: '/api/transactions' }, 201);

    expect(calls).toHaveLength(1);
    expect(calls[0]).toMatchObject({
      level: 'log',
      context: 'http',
      message: {
        message: 'request completed',
        method: 'POST',
        path: '/api/transactions',
        status: 201,
        durationMs: 12.35,
      },
    });
  });

  it('leaves the query string out, because it can hold a token', () => {
    const { calls, run } = setup();

    run({ originalUrl: '/api/accounts?token=secret&page=2' }, 200);

    expect(calls[0].message.path).toBe('/api/accounts');
    expect(JSON.stringify(calls[0])).not.toContain('secret');
  });

  it('logs a client error as a warning and a server error as an error', () => {
    const { calls, run } = setup([0, 1, 0, 1]);

    run({ originalUrl: '/api/accounts/9' }, 404);
    run({ originalUrl: '/api/accounts' }, 500);

    expect(calls.map((c) => c.level)).toEqual(['warn', 'error']);
  });

  it('gives every request an id, in the log and in the response header', () => {
    const { calls, run } = setup();

    const { res } = run({ originalUrl: '/api/accounts' }, 200);

    expect(calls[0].message.requestId).toMatch(/^[0-9a-f-]{36}$/);
    expect(res.headers['x-request-id']).toBe(calls[0].message.requestId);
  });

  it('keeps a request id the caller sent', () => {
    const { calls, run } = setup();

    const { res } = run(
      { originalUrl: '/api/accounts', headers: { 'x-request-id': 'abc-123' } },
      200,
    );

    expect(calls[0].message.requestId).toBe('abc-123');
    expect(res.headers['x-request-id']).toBe('abc-123');
  });

  it.each([['a b'], ['x'.repeat(200)], ['line\nbreak'], ['']])(
    "replaces a caller's request id that is not safe to log (%j)",
    (sent) => {
      const { calls, run } = setup();

      run(
        { originalUrl: '/api/accounts', headers: { 'x-request-id': sent } },
        200,
      );

      expect(calls[0].message.requestId).toMatch(/^[0-9a-f-]{36}$/);
    },
  );

  it("records the load balancer's trace id, so a line can be found in its access log", () => {
    const { calls, run } = setup();

    run(
      {
        originalUrl: '/api/accounts',
        headers: {
          'x-amzn-trace-id': 'Root=1-67891233-abcdef012345678912345678',
        },
      },
      200,
    );

    expect(calls[0].message.traceId).toBe(
      'Root=1-67891233-abcdef012345678912345678',
    );
  });

  it('does not log the health check while it succeeds, but does when it fails', () => {
    const { calls, run } = setup([0, 1, 0, 1]);

    run({ originalUrl: '/api/health' }, 200);
    expect(calls).toHaveLength(0);

    run({ originalUrl: '/api/health' }, 503);
    expect(calls).toHaveLength(1);
    expect(calls[0].level).toBe('error');
  });

  it('falls back to url when originalUrl is not set', () => {
    const { calls, run } = setup();

    run({ url: '/api/users?x=1' }, 200);

    expect(calls[0].message.path).toBe('/api/users');
  });
});
