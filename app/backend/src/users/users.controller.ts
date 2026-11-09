import {
  Controller,
  Get,
  Post,
  Body,
  // Param,
  Req,
  UnauthorizedException,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBody, ApiBearerAuth } from '@nestjs/swagger';
import { UsersService } from './users.service';

@ApiTags('Users')
@ApiBearerAuth()
@Controller('users')
export class UsersController {
  constructor(private readonly usersService: UsersService) {
    console.log('UsersController initialized');
  }

  @Post('register')
  @ApiOperation({ summary: 'Register a new user' })
  @ApiBody({
    schema: {
      properties: {
        username: { type: 'string' },
        email: { type: 'string' },
        password: { type: 'string' },
      },
    },
  })
  async register(
    @Body() data: { username: string; email: string; password: string },
  ) {
    return this.usersService.register(data);
  }

  @Get()
  @ApiOperation({ summary: 'Get all users' })
  async findAll() {
    return this.usersService.findAll();
  }

  // @Get(':username')
  // @ApiOperation({ summary: 'Get a user by username' })
  // async findOne(@Param('username') username: string) {
  //   return this.usersService.findOne(username);
  // }

  @Post('me')
  async getUserInfo(@Req() req: Request) {
    const userId = (req as any).user?.sub;
    if (!userId) {
      throw new UnauthorizedException('User ID is missing');
    }
    const userInfo = await this.usersService.getUserInfo(userId);
    return userInfo;
  }
}
