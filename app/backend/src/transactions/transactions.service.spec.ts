import { Test, TestingModule } from '@nestjs/testing';
import { TransactionsService } from './transactions.service';
import { PrismaService } from '../common/prisma.service';
import { BadRequestException } from '@nestjs/common';

describe('TransactionsService', () => {
  let service: TransactionsService;
  let prisma: PrismaService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      providers: [
        TransactionsService,
        {
          provide: PrismaService,
          useValue: {
            account: {
              findUnique: jest.fn(),
              update: jest.fn(),
            },
            transaction: {
              findMany: jest.fn(),
              create: jest.fn(),
            },
            $transaction: jest.fn((callback) => callback(prisma)),
          },
        },
      ],
    }).compile();

    service = module.get<TransactionsService>(TransactionsService);
    prisma = module.get<PrismaService>(PrismaService);
  });

  it('should be defined', () => {
    expect(service).toBeDefined();
  });

  describe('TransactionsService - deposit', () => {
    it('should successfully deposit money into an account', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 1000,
      });

      // Mock account update
      jest.spyOn(prisma.account, 'update').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 1500,
      });

      // Mock transaction creation
      jest.spyOn(prisma.transaction, 'create').mockResolvedValueOnce({
        id: 1,
        fromAccountId: null,
        toAccountId: 1,
        type: 'DEPOSIT',
        amount: 500,
        status: 'SUCCESS',
        createdAt: new Date(),
      });

      const result = await service.deposit(1, 1, 500);

      expect(result).toEqual({
        id: 1,
        fromAccountId: null,
        toAccountId: 1,
        type: 'DEPOSIT',
        amount: 500,
        status: 'SUCCESS',
        createdAt: expect.any(Date),
      });
      expect(prisma.account.update).toHaveBeenCalledWith({
        where: { id: 1 },
        data: { balance: { increment: 500 } },
      });
      expect(prisma.transaction.create).toHaveBeenCalledWith({
        data: {
          fromAccountId: null,
          toAccountId: 1,
          type: 'DEPOSIT',
          amount: 500,
          status: 'SUCCESS',
        },
      });
    });

    it('should throw an error if deposit amount is less than or equal to zero', async () => {
      await expect(service.deposit(1, 1, 0)).rejects.toThrow(
        new BadRequestException('Deposit amount must be greater than zero'),
      );
    });

    it('should throw an error if account does not belong to the user', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce(null);

      await expect(service.deposit(1, 1, 500)).rejects.toThrow(
        new BadRequestException('Access denied or account not found'),
      );
    });
  });

  describe('TransactionsService - withdraw', () => {
    it('should successfully withdraw money from an account', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 1000,
      });

      // Mock account update
      jest.spyOn(prisma.account, 'update').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 500, // Updated balance after withdrawal
      });

      // Mock transaction creation
      jest.spyOn(prisma.transaction, 'create').mockResolvedValueOnce({
        id: 1,
        fromAccountId: 1,
        toAccountId: null, // No toAccountId for withdrawals
        type: 'WITHDRAW',
        amount: 500,
        status: 'SUCCESS',
        createdAt: new Date(),
      });

      const result = await service.withdraw(1, 1, 500);

      expect(result).toEqual({
        id: 1,
        fromAccountId: 1,
        toAccountId: null, // Ensure this matches the mock response
        type: 'WITHDRAW',
        amount: 500,
        status: 'SUCCESS',
        createdAt: expect.any(Date),
      });
      expect(prisma.account.update).toHaveBeenCalledWith({
        where: { id: 1 },
        data: { balance: { decrement: 500 } },
      });
      expect(prisma.transaction.create).toHaveBeenCalledWith({
        data: {
          fromAccountId: 1,
          type: 'WITHDRAW',
          amount: 500,
          status: 'SUCCESS',
        },
      });
    });

    it('should throw an error if account has insufficient funds', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 400, // Insufficient balance
      });

      await expect(service.withdraw(1, 1, 500)).rejects.toThrow(
        new BadRequestException('Insufficient funds or access denied'),
      );
    });

    it('should throw an error if account does not belong to the user', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 2, // Account belongs to a different user
        balance: 1000,
      });

      await expect(service.withdraw(1, 1, 500)).rejects.toThrow(
        new BadRequestException('Insufficient funds or access denied'),
      );
    });

    it('should throw an error if withdrawal amount is less than or equal to zero', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 1000,
      });

      await expect(service.withdraw(1, 1, 0)).rejects.toThrow(
        new BadRequestException('Withdrawal amount must be greater than zero'),
      );
    });
  });

  describe('TransactionsService - transfer', () => {
    it('should successfully transfer money between accounts', async () => {
      // Mock source account lookup
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 1000 }) // Source account
        .mockResolvedValueOnce({ id: 2, userId: 2, balance: 500 }); // Destination account

      // Mock source account update
      jest
        .spyOn(prisma.account, 'update')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 500 }) // Updated source account
        .mockResolvedValueOnce({ id: 2, userId: 2, balance: 1000 }); // Updated destination account

      // Mock transaction creation
      jest.spyOn(prisma.transaction, 'create').mockResolvedValueOnce({
        id: 1,
        fromAccountId: 1,
        toAccountId: 2,
        type: 'TRANSFER',
        amount: 500,
        status: 'SUCCESS',
        createdAt: new Date(),
      });

      const result = await service.transfer(1, 1, 2, 500);

      expect(result).toEqual({
        id: 1,
        fromAccountId: 1,
        toAccountId: 2,
        type: 'TRANSFER',
        amount: 500,
        status: 'SUCCESS',
        createdAt: expect.any(Date),
      });
      expect(prisma.account.update).toHaveBeenCalledWith({
        where: { id: 1 },
        data: { balance: { decrement: 500 } },
      });
      expect(prisma.account.update).toHaveBeenCalledWith({
        where: { id: 2 },
        data: { balance: { increment: 500 } },
      });
      expect(prisma.transaction.create).toHaveBeenCalledWith({
        data: {
          fromAccountId: 1,
          toAccountId: 2,
          type: 'TRANSFER',
          amount: 500,
          status: 'SUCCESS',
        },
      });
    });

    it('should throw an error if transfer amount is less than or equal to zero', async () => {
      await expect(service.transfer(1, 1, 2, 0)).rejects.toThrow(
        new BadRequestException('Transfer amount must be greater than zero'),
      );
    });

    it('should throw an error if source account does not belong to the user', async () => {
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 2, balance: 1000 }); // Source account belongs to another user

      await expect(service.transfer(1, 1, 2, 500)).rejects.toThrow(
        new BadRequestException('Invalid or unauthorized source account'),
      );
    });

    it('should throw an error if destination account does not exist', async () => {
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 1000 }) // Source account
        .mockResolvedValueOnce(null); // Destination account does not exist

      await expect(service.transfer(1, 1, 2, 500)).rejects.toThrow(
        new BadRequestException('Invalid destination account'),
      );
    });

    it('should throw an error if transferring to the same account', async () => {
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 1000 }); // Source account

      await expect(service.transfer(1, 1, 1, 500)).rejects.toThrow(
        new BadRequestException('Cannot transfer to the same account'),
      );
    });

    it('should throw an error if source account has insufficient funds', async () => {
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 400 }) // Source account with insufficient funds
        .mockResolvedValueOnce({ id: 2, userId: 2, balance: 500 }); // Destination account

      await expect(service.transfer(1, 1, 2, 500)).rejects.toThrow(
        new BadRequestException('Insufficient funds in source account'),
      );
    });
  });

  describe('TransactionsService - transfer (double spending)', () => {
    it('should successfully deduct and credit the correct amounts atomically', async () => {
      // Mock source and destination account lookups
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 1000 }) // Source account
        .mockResolvedValueOnce({ id: 2, userId: 2, balance: 500 }); // Destination account

      // Mock account updates
      jest
        .spyOn(prisma.account, 'update')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 500 }) // Updated source account
        .mockResolvedValueOnce({ id: 2, userId: 2, balance: 1000 }); // Updated destination account

      // Mock transaction creation
      jest.spyOn(prisma.transaction, 'create').mockResolvedValueOnce({
        id: 1,
        fromAccountId: 1,
        toAccountId: 2,
        type: 'TRANSFER',
        amount: 500,
        status: 'SUCCESS',
        createdAt: new Date(),
      });

      const result = await service.transfer(1, 1, 2, 500);

      expect(result).toEqual({
        id: 1,
        fromAccountId: 1,
        toAccountId: 2,
        type: 'TRANSFER',
        amount: 500,
        status: 'SUCCESS',
        createdAt: expect.any(Date),
      });

      // Ensure the source account was decremented
      expect(prisma.account.update).toHaveBeenCalledWith({
        where: { id: 1 },
        data: { balance: { decrement: 500 } },
      });

      // Ensure the destination account was incremented
      expect(prisma.account.update).toHaveBeenCalledWith({
        where: { id: 2 },
        data: { balance: { increment: 500 } },
      });

      // Ensure the transaction was created
      expect(prisma.transaction.create).toHaveBeenCalledWith({
        data: {
          fromAccountId: 1,
          toAccountId: 2,
          type: 'TRANSFER',
          amount: 500,
          status: 'SUCCESS',
        },
      });
    });

    it('should fail the transaction if insufficient funds are detected during the operation', async () => {
      // Mock source and destination account lookups
      jest
        .spyOn(prisma.account, 'findUnique')
        .mockResolvedValueOnce({ id: 1, userId: 1, balance: 400 }) // Insufficient funds in source account
        .mockResolvedValueOnce({ id: 2, userId: 2, balance: 500 }); // Destination account

      await expect(service.transfer(1, 1, 2, 500)).rejects.toThrow(
        new BadRequestException('Insufficient funds in source account'),
      );

      // Ensure no updates or transactions were performed
      expect(prisma.account.update).not.toHaveBeenCalled();
      expect(prisma.transaction.create).not.toHaveBeenCalled();
    });
  });

  describe('TransactionsService - getTransactionHistory', () => {
    it('should fetch transaction history for a valid account', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 1000,
      });

      // Mock transaction history
      jest.spyOn(prisma.transaction, 'findMany').mockResolvedValueOnce([
        {
          id: 1,
          fromAccountId: null,
          toAccountId: 1,
          type: 'DEPOSIT',
          amount: 500,
          status: 'SUCCESS',
          createdAt: new Date(),
        },
        {
          id: 2,
          fromAccountId: 1,
          toAccountId: 2,
          type: 'TRANSFER',
          amount: 200,
          status: 'SUCCESS',
          createdAt: new Date(),
        },
      ]);

      const result = await service.getTransactionHistory(1, 1);

      expect(result).toEqual([
        {
          id: 1,
          fromAccountId: null,
          toAccountId: 1,
          type: 'DEPOSIT',
          amount: 500,
          status: 'SUCCESS',
          createdAt: expect.any(Date),
        },
        {
          id: 2,
          fromAccountId: 1,
          toAccountId: 2,
          type: 'TRANSFER',
          amount: 200,
          status: 'SUCCESS',
          createdAt: expect.any(Date),
        },
      ]);
      expect(prisma.account.findUnique).toHaveBeenCalledWith({
        where: { id: 1 },
      });
      expect(prisma.transaction.findMany).toHaveBeenCalledWith({
        where: {
          OR: [{ fromAccountId: 1 }, { toAccountId: 1 }],
        },
        orderBy: { createdAt: 'desc' },
      });
    });

    it('should throw an error if account does not belong to the user', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 2, // Account belongs to another user
        balance: 1000,
      });

      await expect(service.getTransactionHistory(1, 1)).rejects.toThrow(
        new BadRequestException('Access denied or account not found'),
      );
    });

    it('should filter transaction history by type', async () => {
      // Mock account lookup
      jest.spyOn(prisma.account, 'findUnique').mockResolvedValueOnce({
        id: 1,
        userId: 1,
        balance: 1000,
      });

      // Mock transaction history
      jest.spyOn(prisma.transaction, 'findMany').mockResolvedValueOnce([
        {
          id: 2,
          fromAccountId: 1,
          toAccountId: 2,
          type: 'TRANSFER',
          amount: 200,
          status: 'SUCCESS',
          createdAt: new Date(),
        },
      ]);

      const result = await service.getTransactionHistory(1, 1, 'TRANSFER');

      expect(result).toEqual([
        {
          id: 2,
          fromAccountId: 1,
          toAccountId: 2,
          type: 'TRANSFER',
          amount: 200,
          status: 'SUCCESS',
          createdAt: expect.any(Date),
        },
      ]);
      expect(prisma.account.findUnique).toHaveBeenCalledWith({
        where: { id: 1 },
      });
      expect(prisma.transaction.findMany).toHaveBeenCalledWith({
        where: {
          OR: [{ fromAccountId: 1 }, { toAccountId: 1 }],
          type: 'TRANSFER',
        },
        orderBy: { createdAt: 'desc' },
      });
    });
  });
});
