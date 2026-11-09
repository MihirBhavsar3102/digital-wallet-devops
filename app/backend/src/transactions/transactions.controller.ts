import {
  Controller,
  Post,
  Body,
  Get,
  Param,
  Query,
  BadRequestException,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { TransactionsService } from './transactions.service';
import {
  DepositDto,
  WithdrawDto,
  TransferDto,
} from './dto/create-transaction.dto';
import { CurrentUser } from '../users/current-user.decorator';

@ApiTags('Transactions')
@ApiBearerAuth()
@Controller('transactions')
export class TransactionsController {
  constructor(private readonly transactionsService: TransactionsService) {}

  @Post('deposit')
  @ApiOperation({ summary: 'Deposit money into an account' })
  async deposit(@CurrentUser() user, @Body() data: DepositDto) {
    return this.transactionsService.deposit(
      user.sub,
      data.accountId,
      data.amount,
    );
  }

  @Post('withdraw')
  @ApiOperation({ summary: 'Withdraw money from an account' })
  async withdraw(@CurrentUser() user, @Body() data: WithdrawDto) {
    return this.transactionsService.withdraw(
      user.sub,
      data.accountId,
      data.amount,
    );
  }

  @Post('transfer')
  @ApiOperation({ summary: 'Transfer money between accounts' })
  async transfer(@CurrentUser() user, @Body() data: TransferDto) {
    return this.transactionsService.transfer(
      user.sub,
      data.fromAccountId,
      data.toAccountId,
      data.amount,
    );
  }

  @Get('history/:accountId')
  @ApiOperation({ summary: 'Get transaction history for an account' })
  async getHistory(
    @CurrentUser() user,
    @Param('accountId') accountId: string,
    @Query('type') type?: string,
  ) {
    const numericAccountId = Number(accountId);
    if (isNaN(numericAccountId)) {
      throw new BadRequestException('Invalid account ID format');
    }
    return this.transactionsService.getTransactionHistory(
      user.sub,
      numericAccountId,
      type,
    );
  }
}
