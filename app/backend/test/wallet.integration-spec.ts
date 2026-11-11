import { INestApplication, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import * as request from 'supertest';
import { AppModule } from '../src/app.module';

// Runs the real application against a real PostgreSQL (DATABASE_URL, migrations already applied).
// Nothing is mocked: this is the check that migrations, Prisma, bcrypt, JWT and the money logic work
// together. Usernames carry a unique suffix, so the test can run again on the same database.
describe('wallet flow against a real database', () => {
  let app: INestApplication;
  let counter = 0;
  const run = Date.now();

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({
      imports: [AppModule],
    }).compile();
    app = moduleRef.createNestApplication();
    // The same global setup as main.ts: the /api prefix and request validation.
    app.setGlobalPrefix('api');
    app.useGlobalPipes(new ValidationPipe());
    await app.init();
  });

  afterAll(async () => {
    await app.close();
  });

  const http = () => request(app.getHttpServer());
  const bearer = (token: string) => ({ Authorization: `Bearer ${token}` });

  async function registerAndLogin(): Promise<string> {
    const username = `it_${run}_${++counter}`;
    const password = 'Passw0rd!';
    await http()
      .post('/api/users/register')
      .send({ username, email: `${username}@example.com`, password })
      .expect(201);
    const login = await http()
      .post('/api/auth/login')
      .send({ username, password })
      .expect(200);
    return login.body.access_token;
  }

  async function openAccount(token: string, initialBalance: number) {
    const res = await http()
      .post('/api/accounts')
      .set(bearer(token))
      .send({ initialBalance })
      .expect(201);
    return res.body.id as number;
  }

  async function balanceOf(token: string): Promise<number> {
    const res = await http()
      .get('/api/accounts/my-accounts')
      .set(bearer(token))
      .expect(200);
    return res.body[0].balance;
  }

  it('register, login, deposit and transfer leave the right balance on both accounts', async () => {
    const alice = await registerAndLogin();
    const bob = await registerAndLogin();
    const aliceAccount = await openAccount(alice, 500);
    const bobAccount = await openAccount(bob, 100);

    await http()
      .post('/api/transactions/deposit')
      .set(bearer(alice))
      .send({ accountId: aliceAccount, amount: 250 })
      .expect(201);
    await http()
      .post('/api/transactions/transfer')
      .set(bearer(alice))
      .send({
        fromAccountId: aliceAccount,
        toAccountId: bobAccount,
        amount: 300,
      })
      .expect(201);

    expect(await balanceOf(alice)).toBe(450); // 500 + 250 - 300
    expect(await balanceOf(bob)).toBe(400); // 100 + 300
  });

  it('refuses a transfer larger than the balance and changes nothing', async () => {
    const alice = await registerAndLogin();
    const bob = await registerAndLogin();
    const aliceAccount = await openAccount(alice, 100);
    const bobAccount = await openAccount(bob, 100);

    await http()
      .post('/api/transactions/transfer')
      .set(bearer(alice))
      .send({
        fromAccountId: aliceAccount,
        toAccountId: bobAccount,
        amount: 500,
      })
      .expect(400);

    expect(await balanceOf(alice)).toBe(100);
    expect(await balanceOf(bob)).toBe(100);
  });

  it('refuses requests without a token', async () => {
    await http().get('/api/accounts/my-accounts').expect(401);
  });
});
