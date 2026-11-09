import { Test, TestingModule } from '@nestjs/testing';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';

describe('AuthController', () => {
  let controller: AuthController;
  let authService: AuthService;

  beforeEach(async () => {
    const module: TestingModule = await Test.createTestingModule({
      controllers: [AuthController],
      providers: [
        {
          provide: AuthService,
          useValue: {
            signIn: jest.fn(),
          },
        },
      ],
    }).compile();

    controller = module.get<AuthController>(AuthController);
    authService = module.get<AuthService>(AuthService);
  });

  it('should be defined', () => {
    expect(controller).toBeDefined();
  });

  describe('signIn', () => {
    it('should call AuthService.signIn with correct parameters and return an access token', async () => {
      const mockSignInDto = { username: 'testuser', password: 'password123' };
      const mockToken = { access_token: 'valid-jwt-token' };

      jest.spyOn(authService, 'signIn').mockResolvedValueOnce(mockToken);

      const result = await controller.signIn(mockSignInDto);

      expect(authService.signIn).toHaveBeenCalledWith(
        mockSignInDto.username,
        mockSignInDto.password,
      );
      expect(result).toEqual(mockToken);
    });
  });
});
