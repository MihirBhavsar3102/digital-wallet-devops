import { Injectable, NestMiddleware } from '@nestjs/common';

@Injectable()
export class DebugMiddleware implements NestMiddleware {
  use(req: any, res: any, next: () => void) {
    console.log(
      'Debug Middleware - Request:',
      //   req.url,
      //   req.method,
      //   req.headers,
    );
    next();
  }
}

//Add this in main.ts
//   app.use(new DebugMiddleware().use);
