import { Injectable, BadRequestException } from '@nestjs/common';
import { PrismaService } from '../common/prisma.service';

@Injectable()
export class AccountsService {
  constructor(private readonly prisma: PrismaService) {}

  async create(data: { userId: number; initialBalance: number }) {
    return this.prisma.account.create({
      data: {
        userId: data.userId,
        balance: data.initialBalance,
      },
    });
  }

  async findAllByUserId(userId: number) {
    return this.prisma.account.findMany({
      where: { userId },
      include: {
        user: {
          select: {
            username: true,
            email: true,
            createdAt: true,
          },
        },
      },
    });
  }

  async findAllAccounts() {
    return this.prisma.account.findMany({
      include: {
        user: {
          select: {
            username: true,
          },
        },
      },
    });
  }

  async findOneByUserId(userId: number, accountId: number) {
    const account = await this.prisma.account.findUnique({
      where: { id: accountId },
      include: {
        transactionsFrom: true,
        transactionsTo: true,
      },
    });

    if (!account || account.userId !== userId) {
      throw new BadRequestException('Access denied or account not found');
    }

    return account;
  }
}
