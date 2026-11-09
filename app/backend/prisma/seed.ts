import { PrismaClient } from '@prisma/client';
import * as bcrypt from 'bcrypt';

const prisma = new PrismaClient();

async function seedDatabase() {
  try {
    console.log('Seeding database...');

    // Clear existing data
    await prisma.transaction.deleteMany();
    await prisma.account.deleteMany();
    await prisma.user.deleteMany();
    console.log('Database cleaned.');

    // Seed users
    const hashedPassword = await bcrypt.hash('password123', 10);

    const user1 = await prisma.user.create({
      data: {
        username: 'john_doe',
        email: 'john@example.com',
        password: hashedPassword,
        createdAt: new Date(),
      },
    });

    const user2 = await prisma.user.create({
      data: {
        username: 'jane_smith',
        email: 'jane@example.com',
        password: hashedPassword,
        createdAt: new Date(),
      },
    });

    console.log('Users seeded:', { user1, user2 });

    // Seed accounts
    const account1 = await prisma.account.create({
      data: {
        userId: user1.id,
        balance: 1000.0,
      },
    });

    const account2 = await prisma.account.create({
      data: {
        userId: user2.id,
        balance: 2000.0,
      },
    });

    console.log('Accounts seeded:', { account1, account2 });

    // Seed transactions
    await prisma.transaction.createMany({
      data: [
        {
          fromAccountId: account1.id,
          toAccountId: account2.id,
          type: 'TRANSFER',
          amount: 200.0,
          status: 'SUCCESS',
          createdAt: new Date(),
        },
        {
          toAccountId: account1.id,
          type: 'DEPOSIT',
          amount: 500.0,
          status: 'SUCCESS',
          createdAt: new Date(),
        },
        {
          fromAccountId: account2.id,
          type: 'WITHDRAW',
          amount: 300.0,
          status: 'SUCCESS',
          createdAt: new Date(),
        },
      ],
    });

    console.log('Transactions seeded.');

    console.log('Database seeded successfully!');
  } catch (error) {
    console.error('Error seeding database:', error);
  } finally {
    await prisma.$disconnect();
  }
}

seedDatabase();
