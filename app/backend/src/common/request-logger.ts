import { randomUUID } from 'node:crypto';

// Only what the middleware uses, so that it can be tested without a web server.
interface RequestLike {
  method: string;
  url: string;
  originalUrl?: string;
  headers: Record<string, string | string[] | undefined>;
}
interface ResponseLike {
  statusCode: number;
  setHeader(name: string, value: string): unknown;
  on(event: 'finish', listener: () => void): unknown;
}
interface LevelLogger {
  log(message: unknown, context?: string): unknown;
  warn(message: unknown, context?: string): unknown;
  error(message: unknown, context?: string): unknown;
}

// What a caller may send as a request id: short, and nothing that could break a log line or fill the log.
const SAFE_REQUEST_ID = /^[A-Za-z0-9._-]{1,128}$/;
// The load balancer probes /api/health every few seconds from each of its nodes. Those lines would drown
// out the real requests, so a healthy answer is not logged. An unhealthy one is.
const HEALTH_PATH = '/api/health';

const first = (header: string | string[] | undefined) =>
  Array.isArray(header) ? header[0] : header;

/**
 * Express-style middleware that writes one log line per request, when the response has finished: the request
 * id, method, path (without the query string, which can carry a token), status and duration in milliseconds.
 * The level follows the status: 5xx is an error, 4xx a warning, anything else info. Because the line is a JSON
 * object, the CloudWatch metric filter and the saved Logs Insights queries can use these fields directly.
 *
 * The request id is the caller's `X-Request-Id` when it is safe to log, and a fresh UUID otherwise. It is also
 * returned in the response header. The load balancer's own trace id (`X-Amzn-Trace-Id`) is logged beside it, so
 * a line here can be matched to a line in the load balancer's access log.
 */
export function createRequestLogger(
  logger: LevelLogger,
  now: () => bigint = () => process.hrtime.bigint(),
) {
  return (req: RequestLike, res: ResponseLike, next: () => void) => {
    const started = now();
    const sent = first(req.headers['x-request-id']);
    const requestId = sent && SAFE_REQUEST_ID.test(sent) ? sent : randomUUID();
    res.setHeader('x-request-id', requestId);

    res.on('finish', () => {
      const path = (req.originalUrl ?? req.url).split('?')[0];
      const status = res.statusCode;
      if (path === HEALTH_PATH && status < 400) return;

      const traceId = first(req.headers['x-amzn-trace-id']);
      const line = {
        message: 'request completed',
        requestId,
        ...(traceId ? { traceId: traceId.slice(0, 200) } : {}),
        method: req.method,
        path,
        status,
        durationMs: Math.round(Number(now() - started) / 1e4) / 100,
      };
      if (status >= 500) logger.error(line, 'http');
      else if (status >= 400) logger.warn(line, 'http');
      else logger.log(line, 'http');
    });

    next();
  };
}
