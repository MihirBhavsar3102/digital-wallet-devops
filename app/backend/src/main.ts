import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { ValidationPipe } from '@nestjs/common';
import { JsonLogger } from './common/json-logger';
import { createRequestLogger } from './common/request-logger';

async function bootstrap() {
  // One JSON object per line on stdout, for CloudWatch (Docker's awslogs driver ships stdout).
  const logger = new JsonLogger();
  const app = await NestFactory.create(AppModule, { logger });
  app.use(createRequestLogger(logger));

  // global prefix for all routes
  app.setGlobalPrefix('api');
  // Enable global validation
  app.useGlobalPipes(new ValidationPipe());

  app.enableCors({
    origin: 'http://localhost:8080',
    methods: 'GET,HEAD,PUT,PATCH,POST,DELETE,OPTIONS',
    credentials: true,
  });

  // Swagger setup
  const config = new DocumentBuilder()
    .setTitle('Digital Wallet API')
    .setDescription('API documentation for the digital wallet application')
    .setVersion('1.0')
    .addBearerAuth()
    .build();
  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('api/docs', app, document);

  const port = process.env.PORT || 3000;
  await app.listen(port);
  logger.log(`Application is running on port ${port}`, 'Bootstrap');
  logger.log(`Swagger is available at /api/docs`, 'Bootstrap');
}
bootstrap();
