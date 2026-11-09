# Use the official Node.js image
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

# Expose the application port
EXPOSE 8081

# Run migrations (create if needed) and start the application
CMD ["sh", "-c", "npx prisma migrate dev --name init && npm run start:dev"]
