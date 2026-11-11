import { ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { AppModule } from '../app.module';
import { AuthGuard } from '../auth/auth.guard';
import { HealthController } from './health.controller';

describe('HealthController', () => {
  it('reports status ok', () => {
    expect(new HealthController().check()).toEqual({ status: 'ok' });
  });

  // The app registers AuthGuard globally, so without @Public() the load balancer's
  // unauthenticated health check would get a 401 and the target would never turn healthy.
  it('is reachable without a token through the global auth guard', async () => {
    const guard = new AuthGuard(new JwtService({}), new Reflector());
    const context = {
      getHandler: () => HealthController.prototype.check,
      getClass: () => HealthController,
      switchToHttp: () => ({
        getRequest: () => ({ headers: {}, url: '/api/health' }),
      }),
    } as unknown as ExecutionContext;

    await expect(guard.canActivate(context)).resolves.toBe(true);
  });

  it('is registered in AppModule, so the route exists', () => {
    const controllers: unknown[] = Reflect.getMetadata(
      'controllers',
      AppModule,
    );

    expect(controllers).toContain(HealthController);
  });
});
