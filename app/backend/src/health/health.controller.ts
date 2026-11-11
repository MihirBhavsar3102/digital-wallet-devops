import { Controller, Get } from '@nestjs/common';
import { Public } from '../auth/auth.decorators';

@Controller('health')
export class HealthController {
  @Public()
  @Get()
  check() {
    return { status: 'ok' };
  }
}
