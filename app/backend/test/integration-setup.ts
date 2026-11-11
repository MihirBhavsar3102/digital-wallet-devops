// Runs before the test file is loaded. AppModule reads JWT_SECRET_KEY when it is imported, so it
// has to be set here and not inside the test.
process.env.JWT_SECRET_KEY ??= 'integration-test-secret';

if (!process.env.DATABASE_URL) {
  throw new Error(
    'DATABASE_URL is not set. Point it at a PostgreSQL database where "prisma migrate deploy" has ' +
      'already been run (see the README, "Local development and tests").',
  );
}
