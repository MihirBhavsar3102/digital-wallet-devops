import {
  ExecutionContext,
  Logger,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { AuthGuard } from './auth.guard';

describe('AuthGuard', () => {
  const secret = 'unit-test-secret';
  const jwt = new JwtService({ secret });
  const guard = new AuthGuard(jwt, new Reflector());
  let originalSecret: string | undefined;

  const contextFor = (request: object) =>
    ({
      getHandler: () => () => undefined,
      getClass: () => class {},
      switchToHttp: () => ({ getRequest: () => request }),
    }) as unknown as ExecutionContext;

  beforeEach(() => {
    originalSecret = process.env.JWT_SECRET_KEY;
    process.env.JWT_SECRET_KEY = secret;
  });

  afterEach(() => {
    process.env.JWT_SECRET_KEY = originalSecret;
    jest.restoreAllMocks();
  });

  it('attaches the token payload to the request when the token is valid', async () => {
    const token = await jwt.signAsync({ sub: 7, username: 'alice' });
    const request: Record<string, any> = {
      headers: { authorization: `Bearer ${token}` },
      url: '/api/accounts/my-accounts',
    };

    await expect(guard.canActivate(contextFor(request))).resolves.toBe(true);

    expect(request.user).toMatchObject({ sub: 7, username: 'alice' });
  });

  it('rejects a request without a token', async () => {
    const request = { headers: {}, url: '/api/accounts/my-accounts' };

    await expect(guard.canActivate(contextFor(request))).rejects.toThrow(
      UnauthorizedException,
    );
  });

  // The logs are shipped to CloudWatch, so a logged token or header is a leaked credential.
  it('does not write the bearer token or request headers to the logs', async () => {
    const token = await jwt.signAsync({ sub: 7, username: 'alice' });
    const log = jest.spyOn(console, 'log').mockImplementation(() => undefined);
    const error = jest
      .spyOn(console, 'error')
      .mockImplementation(() => undefined);
    const request = {
      headers: { authorization: `Bearer ${token}`, cookie: 'session=abc123' },
      url: '/api/accounts/my-accounts',
    };

    await guard.canActivate(contextFor(request));

    const written = JSON.stringify([...log.mock.calls, ...error.mock.calls]);
    expect(written).not.toContain(token);
    expect(written).not.toContain('session=abc123');
  });

  // The backend logs one JSON object per line, so a rejected token goes through Nest's logger (not console.error,
  // which printed the whole error object over several lines). A bad token is the caller's mistake, not the
  // server's, so it is a warning: the error-level lines are what the CloudWatch error metric counts.
  describe('when the token is rejected', () => {
    const rejectedWith = async (bearer: string) => {
      const warn = jest
        .spyOn(Logger.prototype, 'warn')
        .mockImplementation(() => undefined);
      const error = jest
        .spyOn(Logger.prototype, 'error')
        .mockImplementation(() => undefined);
      const consoleError = jest
        .spyOn(console, 'error')
        .mockImplementation(() => undefined);
      const request = {
        headers: { authorization: `Bearer ${bearer}` },
        url: '/api/accounts/my-accounts',
      };

      await expect(guard.canActivate(contextFor(request))).rejects.toThrow(
        UnauthorizedException,
      );
      return { warn, error, consoleError };
    };

    it('writes one warning, and nothing to console or at error level', async () => {
      const { warn, error, consoleError } = await rejectedWith('not.a.jwt');

      expect(warn).toHaveBeenCalledTimes(1);
      expect(String(warn.mock.calls[0][0])).toContain(
        'JWT verification failed',
      );
      expect(error).not.toHaveBeenCalled();
      expect(consoleError).not.toHaveBeenCalled();
    });

    it('does not write the rejected token to the logs', async () => {
      const forged = await new JwtService({
        secret: 'someone-elses',
      }).signAsync({ sub: 1, username: 'mallory' });

      const { warn } = await rejectedWith(forged);

      expect(warn).toHaveBeenCalledTimes(1); // so that "not logged" cannot pass because nothing was logged
      expect(JSON.stringify(warn.mock.calls)).not.toContain(forged);
    });
  });
});
