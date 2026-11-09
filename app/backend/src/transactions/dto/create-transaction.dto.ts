import { ApiProperty } from '@nestjs/swagger';
import { IsNumber, IsPositive } from 'class-validator';

export class DepositDto {
  @ApiProperty({ description: 'The account ID to deposit into', example: 1 })
  @IsNumber()
  @IsPositive()
  accountId: number;

  @ApiProperty({ description: 'The amount to deposit', example: 500.0 })
  @IsNumber()
  @IsPositive()
  amount: number;
}

export class WithdrawDto {
  @ApiProperty({ description: 'The account ID to withdraw from', example: 1 })
  @IsNumber()
  @IsPositive()
  accountId: number;

  @ApiProperty({ description: 'The amount to withdraw', example: 200.0 })
  @IsNumber()
  @IsPositive()
  amount: number;
}

export class TransferDto {
  @ApiProperty({ description: 'The account ID to transfer from', example: 1 })
  @IsNumber()
  @IsPositive()
  fromAccountId: number;

  @ApiProperty({ description: 'The account ID to transfer to', example: 2 })
  @IsNumber()
  @IsPositive()
  toAccountId: number;

  @ApiProperty({ description: 'The amount to transfer', example: 300.0 })
  @IsNumber()
  @IsPositive()
  amount: number;
}
