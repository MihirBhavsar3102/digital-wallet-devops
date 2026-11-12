import { LoggerService } from '@nestjs/common';
import { inspect } from 'node:util';

type Level = 'info' | 'warn' | 'error' | 'debug' | 'verbose' | 'fatal';

// A line written by the logger always has these three; a field of the same name in a logged object is ignored.
const RESERVED = new Set(['time', 'level', 'context']);

const looksLikeStack = (text: string) => /\n\s+at /.test(text);

const isPlainObject = (value: unknown): value is Record<string, unknown> => {
  if (typeof value !== 'object' || value === null) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
};

// JSON.stringify that cannot throw: a circular reference or a bigint must not take a request down.
function safeStringify(value: unknown): string {
  const seen = new WeakSet<object>();
  return JSON.stringify(value, (_key, item) => {
    if (typeof item === 'bigint') return item.toString();
    if (typeof item === 'object' && item !== null) {
      if (seen.has(item)) return '[Circular]';
      seen.add(item);
    }
    return item;
  });
}

/**
 * Nest's default logger prints coloured text. This one writes one JSON object per line to stdout, which is
 * what CloudWatch Logs Insights, a metric filter and `docker logs | jq` can all read.
 *
 * A line has a timestamp, a level (info, warn, error, debug, verbose or fatal) and, when Nest passes one, a
 * context. The message can be a string, an Error (its stack is kept), or a plain object, whose fields are
 * written at the top level so that they can be queried (the request logger relies on that).
 */
export class JsonLogger implements LoggerService {
  constructor(
    // Receives one finished line, without the trailing newline. Replaced only by the tests.
    private readonly write: (line: string) => void = (line) => {
      process.stdout.write(`${line}\n`);
    },
    private readonly now: () => Date = () => new Date(),
  ) {}

  log(message: unknown, ...rest: unknown[]) {
    this.emit('info', message, rest);
  }
  warn(message: unknown, ...rest: unknown[]) {
    this.emit('warn', message, rest);
  }
  error(message: unknown, ...rest: unknown[]) {
    this.emit('error', message, rest);
  }
  debug(message: unknown, ...rest: unknown[]) {
    this.emit('debug', message, rest);
  }
  verbose(message: unknown, ...rest: unknown[]) {
    this.emit('verbose', message, rest);
  }
  fatal(message: unknown, ...rest: unknown[]) {
    this.emit('fatal', message, rest);
  }

  private emit(level: Level, message: unknown, rest: unknown[]) {
    try {
      this.write(this.format(level, message, rest));
    } catch {
      // A logger must never make the request that is being logged fail.
    }
  }

  private format(level: Level, message: unknown, rest: unknown[]): string {
    const params = [...rest];

    // Nest calls logger.log(message, context) and logger.error(message, stack, context).
    let context: string | undefined;
    const last = params[params.length - 1];
    if (typeof last === 'string' && !looksLikeStack(last)) {
      context = last;
      params.pop();
    }
    let stack: string | undefined;
    const stackIndex = params.findIndex(
      (p) => typeof p === 'string' && looksLikeStack(p),
    );
    if (stackIndex >= 0) stack = params.splice(stackIndex, 1)[0] as string;

    let fields: Record<string, unknown> = {};
    if (message instanceof Error) {
      fields = { message: message.message };
      stack = message.stack ?? stack;
    } else if (isPlainObject(message)) {
      fields = Object.fromEntries(
        Object.entries(message).filter(([key]) => !RESERVED.has(key)),
      );
    } else if (typeof message === 'string') {
      fields = { message };
    } else if (message !== undefined) {
      fields = {
        message: inspect(message, { breakLength: Infinity, depth: 4 }),
      };
    }

    return safeStringify({
      time: this.now().toISOString(),
      level,
      ...(context ? { context } : {}),
      ...fields,
      ...(stack ? { stack } : {}),
      ...(params.length > 0 ? { details: params } : {}),
    });
  }
}
