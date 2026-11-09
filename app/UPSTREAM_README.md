# Digital Wallet Application

This is a full-stack digital wallet application that allows users to register, log in, deposit, withdraw, transfer funds, and view transaction history.

## Features

- User registration and authentication.
- Account management (deposit, withdrawal).
- Fund transfers with atomic transaction support.
- Transaction history.
- Fully Dockerized setup for backend (NestJS) and frontend (Vite).
- Swagger API documentation.
- **Prisma Studio** for database management and visualization.

## Technologies Used

- Backend: NestJS
- Frontend: Vite (React)
- Database: PostgreSQL
- Docker & Docker Compose
- Swagger for API Documentation
- Prisma for ORM and database management

## Setup Instructions

### Prerequisites

- Docker and Docker Compose installed on your system.

### Steps

1. Clone the repository:

   ```bash
   git clone https://github.com/your-repo/digital-wallet.git
   cd digital-wallet
   ```

2. Run the environment setup script:

   ```bash
   chmod +x setup_env.sh
   ./setup_env.sh
   ```

3. Start the application using Docker Compose:

   ```bash
   docker-compose up --build
   ```

4. Access the services:
   - **Frontend**: [http://localhost:8080](http://localhost:8080)
   - **Backend API**: [http://localhost:8081/api](http://localhost:8081/api)
   - **Swagger Documentation**: [http://localhost:8081/api/docs](http://localhost:8081/api/docs)
   - **Prisma Studio**: [http://localhost:5555](http://localhost:5555)

### Prisma Studio

**Prisma Studio** is included for database visualization and management during development. You can access it at [http://localhost:5555](http://localhost:5555).

Prisma Studio allows you to:

- View and manage your database tables and records.
- Test and inspect database relationships (e.g., `User`, `Account`, `Transaction`).

Note: **Prisma Studio should only be used in development environments** for security reasons.

## Environment Variables

### Backend (.env)

```env
DATABASE_URL="postgresql://pgadmin:1234@localhost:6432/digital_wallet"
PORT=8081
JWT_SECRET_KEY="fa7910286fe158fe1712b717a420ad5af92397cd6a081f45dec4840a20c1b4e3"
```

### Frontend (.env)

```env
VITE_API_BASE_URL="http://localhost:8081/api"
```

## Testing

### Backend

Unit tests for the backend are implemented using Jest. To run the tests, navigate to the backend directory and execute:

```bash
cd backend
npx jest
```

### Frontend

Currently, there are no tests implemented for the frontend.

## Swagger API Documentation

The backend includes Swagger documentation accessible at:
[http://localhost:8081/api/docs](http://localhost:8081/api/docs)

Swagger provides detailed API endpoint information and allows testing directly from the browser.

## Docker Overview

### Backend Dockerfile

```dockerfile
# Backend Dockerfile
FROM node:20

# Set working directory
WORKDIR /app

# Copy package.json and package-lock.json
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy the application code
COPY . .

# Generate Prisma client
RUN npx prisma generate

# Expose the port for the application and Prisma Studio
EXPOSE 8081 5555

# Start the application and Prisma Studio in parallel
CMD ["sh", "-c", "npx prisma migrate deploy && npm run start:dev & npx prisma studio --port 5555"]
```

### Frontend Dockerfile

```dockerfile
# Frontend Dockerfile
FROM node:20

# Set working directory
WORKDIR /app

# Copy package.json and package-lock.json
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy the application code
COPY . .

# Build the frontend
RUN npm run build

# Use a lightweight server for the built app
FROM nginx:alpine
COPY --from=0 /app/dist /usr/share/nginx/html

# Expose the default nginx port
EXPOSE 8080

# Start the server
CMD ["nginx", "-g", "daemon off;"]
```

### Docker-Compose File

```yaml
services:
  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    ports:
      - "8081:8081"
    environment:
      - DATABASE_URL=postgresql://pgadmin:1234@db:5432/digital_wallet
      - JWT_SECRET_KEY=fa7910286fe158fe1712b717a420ad5af92397cd6a081f45dec4840a20c1b4e3
      - PORT=8081
    depends_on:
      - db

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    ports:
      - "8080:80"
    environment:
      - VITE_API_BASE_URL=http://localhost:8081/api

  db:
    image: postgres:15
    container_name: postgres_db
    ports:
      - "6432:5432"
    environment:
      POSTGRES_USER: pgadmin
      POSTGRES_PASSWORD: 1234
      POSTGRES_DB: digital_wallet
    volumes:
      - db_data:/var/lib/postgresql/data

  prisma-studio:
    image: node:20
    working_dir: /app
    ports:
      - "5555:5555"
    volumes:
      - ./backend:/app
    command: >
      sh -c "npm install && npx prisma generate && npx prisma studio --port 5555"
    depends_on:
      - db

volumes:
  db_data:
```

---

## Contributing

Feel free to fork the repository and submit pull requests to enhance the project.

## License

This project is open-source and available under the [MIT License](LICENSE).
