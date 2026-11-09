import { Injectable, BadRequestException } from '@nestjs/common';
import { PrismaService } from '../common/prisma.service';

@Injectable()
export class TransactionsService {
  constructor(private readonly prisma: PrismaService) {}

  async deposit(userId: number, accountId: number, amount: number) {
    if (amount <= 0) {
      throw new BadRequestException('Deposit amount must be greater than zero');
    }

    const account = await this.prisma.account.findUnique({
      where: { id: accountId },
    });
    if (!account || account.userId !== userId) {
      throw new BadRequestException('Access denied or account not found');
    }

    return this.prisma.$transaction(async (prisma) => {
      await prisma.account.update({
        where: { id: accountId },
        data: { balance: { increment: amount } },
      });

      return prisma.transaction.create({
        data: {
          fromAccountId: null,
          toAccountId: accountId,
          type: 'DEPOSIT',
          amount,
          status: 'SUCCESS',
        },
      });
    });
  }

  async withdraw(userId: number, accountId: number, amount: number) {
    const account = await this.prisma.account.findUnique({
      where: { id: accountId },
    });

    if (!account || account.userId !== userId || account.balance < amount) {
      throw new BadRequestException('Insufficient funds or access denied');
    }
    if (amount <= 0) {
      throw new BadRequestException(
        'Withdrawal amount must be greater than zero',
      );
    }

    return this.prisma.$transaction(async (prisma) => {
      await prisma.account.update({
        where: { id: accountId },
        data: { balance: { decrement: amount } },
      });

      return prisma.transaction.create({
        data: {
          fromAccountId: accountId,
          type: 'WITHDRAW',
          amount,
          status: 'SUCCESS',
        },
      });
    });
  }

  async transfer(
    userId: number,
    fromAccountId: number,
    toAccountId: number,
    amount: number,
  ) {
    if (amount <= 0) {
      throw new BadRequestException(
        'Transfer amount must be greater than zero',
      );
    }

    const fromAccount = await this.prisma.account.findUnique({
      where: { id: fromAccountId },
    });
    const toAccount = await this.prisma.account.findUnique({
      where: { id: toAccountId },
    });

    if (fromAccountId === toAccountId) {
      throw new BadRequestException('Cannot transfer to the same account');
    }

    if (!fromAccount || fromAccount.userId !== userId) {
      throw new BadRequestException('Invalid or unauthorized source account');
    }

    if (!toAccount) {
      throw new BadRequestException('Invalid destination account');
    }

    if (fromAccount.balance < amount) {
      throw new BadRequestException('Insufficient funds in source account');
    }

    return this.prisma.$transaction(async (prisma) => {
      await prisma.account.update({
        where: { id: fromAccountId },
        data: { balance: { decrement: amount } },
      });

      await prisma.account.update({
        where: { id: toAccountId },
        data: { balance: { increment: amount } },
      });

      return prisma.transaction.create({
        data: {
          fromAccountId,
          toAccountId,
          type: 'TRANSFER',
          amount,
          status: 'SUCCESS',
        },
      });
    });
  }

  async getTransactionHistory(
    userId: number,
    accountId: number,
    type?: string,
  ) {
    const account = await this.prisma.account.findUnique({
      where: { id: accountId },
    });

    if (!account || account.userId !== userId) {
      throw new BadRequestException('Access denied or account not found');
    }

    return this.prisma.transaction.findMany({
      where: {
        OR: [{ fromAccountId: accountId }, { toAccountId: accountId }],
        ...(type && { type }),
      },
      orderBy: { createdAt: 'desc' },
    });
  }
}
