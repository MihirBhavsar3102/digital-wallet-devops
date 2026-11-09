import { Controller, Get, Post, Body, Param } from '@nestjs/common';
import { AccountsService } from './accounts.service';
import {
  ApiTags,
  ApiOperation,
  // ApiParam,
  ApiBearerAuth,
} from '@nestjs/swagger';
import { BadRequestException } from '@nestjs/common';
import { CreateAccountDto } from './dto/create-account.dto';
import { CurrentUser } from '../users/current-user.decorator';

@ApiTags('Accounts')
@ApiBearerAuth()
@Controller('accounts')
export class AccountsController {
  constructor(private readonly accountsService: AccountsService) {}

  @Post()
  @ApiOperation({ summary: 'Create an account for a user' })
  async create(@CurrentUser() user, @Body() data: CreateAccountDto) {
    return this.accountsService.create({
      userId: user.sub,
      initialBalance: data.initialBalance,
    });
  }

  @Get('my-accounts')
  @ApiOperation({ summary: 'Get my accounts' })
  async findAllByUser(@CurrentUser() user) {
    return this.accountsService.findAllByUserId(user.sub);
  }

  @Get('all')
  @ApiOperation({ summary: 'Fetch all accounts in the system' })
  async findAllAccounts() {
    return this.accountsService.findAllAccounts();
  }

  @Get(':id')
  @ApiOperation({ summary: 'Get account details by ID' })
  async findOne(@CurrentUser() user, @Param('id') id: string) {
    const numericId = Number(id);
    if (isNaN(numericId)) {
      throw new BadRequestException('Invalid account ID format');
    }
    return this.accountsService.findOneByUserId(user.sub, numericId);
  }
}
