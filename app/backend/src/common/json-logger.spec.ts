import { JsonLogger } from './json-logger';

describe('JsonLogger', () => {
  const lines: string[] = [];
  const logger = new JsonLogger(
    (line) => lines.push(line),
    () => new Date('2026-11-12T10:00:00.000Z'),
  );
  const last = () => JSON.parse(lines[lines.length - 1]);

  beforeEach(() => {
    lines.length = 0;
  });

  it('writes one JSON object per call, with a timestamp, a level and the message', () => {
    logger.log('server started');

    expect(lines).toHaveLength(1);
    expect(last()).toEqual({
      time: '2026-11-12T10:00:00.000Z',
      level: 'info',
      message: 'server started',
    });
  });

  it.each([
    ['log', 'info'],
    ['warn', 'warn'],
    ['error', 'error'],
    ['debug', 'debug'],
    ['verbose', 'verbose'],
    ['fatal', 'fatal'],
  ] as const)('maps Nest\'s "%s" to the level "%s"', (method, level) => {
    logger[method]('x');

    expect(last().level).toBe(level);
  });

  it('takes the context from the last string parameter', () => {
    logger.log('route mapped', 'RoutesResolver');

    expect(last().context).toBe('RoutesResolver');
    expect(last().message).toBe('route mapped');
  });

  it('keeps a multi-line stack trace inside one line', () => {
    const stack = 'Error: boom\n    at a (a.ts:1:1)\n    at b (b.ts:2:2)';
    logger.error('request failed', stack, 'ExceptionsHandler');

    expect(lines).toHaveLength(1);
    expect(lines[0]).not.toContain('\n');
    expect(last()).toMatchObject({
      level: 'error',
      message: 'request failed',
      stack,
      context: 'ExceptionsHandler',
    });
  });

  it('does not mistake a stack trace for the context', () => {
    const stack = 'Error: boom\n    at a (a.ts:1:1)';
    logger.error('request failed', stack);

    expect(last().stack).toBe(stack);
    expect(last().context).toBeUndefined();
  });

  it('writes the message and the stack of an Error', () => {
    const error = new Error('database is down');
    logger.error(error);

    expect(last().message).toBe('database is down');
    expect(last().stack).toContain('database is down');
  });

  it('puts the fields of an object at the top level, so they can be queried', () => {
    logger.log(
      { message: 'request completed', status: 200, durationMs: 12.5 },
      'http',
    );

    expect(last()).toMatchObject({
      level: 'info',
      context: 'http',
      message: 'request completed',
      status: 200,
      durationMs: 12.5,
    });
  });

  it('does not let a field of an object overwrite the timestamp, the level or the context', () => {
    logger.log(
      { time: 'yesterday', level: 'error', context: 'forged', message: 'm' },
      'http',
    );

    expect(last()).toMatchObject({
      time: '2026-11-12T10:00:00.000Z',
      level: 'info',
      context: 'http',
      message: 'm',
    });
  });

  it('writes a value that is not a string, an Error or a plain object as text', () => {
    logger.log(42);
    expect(last().message).toBe('42');

    logger.log(['a', 'b']);
    expect(last().message).toContain('a');
  });

  it('keeps additional parameters instead of dropping them', () => {
    logger.log('with details', { id: 7 }, 'Ctx');

    expect(last().context).toBe('Ctx');
    expect(last().details).toEqual([{ id: 7 }]);
  });

  it('never throws on a circular object', () => {
    const loop: Record<string, unknown> = { name: 'loop' };
    loop.self = loop;

    expect(() => logger.log(loop)).not.toThrow();
    expect(lines).toHaveLength(1);
    // The object is written once, and the reference back to it is what gets replaced.
    expect(last().self).toEqual({ name: 'loop', self: '[Circular]' });
  });

  it('never throws when the output fails', () => {
    const broken = new JsonLogger(() => {
      throw new Error('stdout closed');
    });

    expect(() => broken.error('x')).not.toThrow();
  });
});
