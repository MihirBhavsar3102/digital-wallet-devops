import { ExecutionContext, UnauthorizedException } from '@nestjs/common';
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
});
