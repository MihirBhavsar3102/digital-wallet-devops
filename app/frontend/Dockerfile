# Frontend Dockerfile
FROM node:20 as build

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

# Stage 2: Serve with NGINX
FROM nginx:alpine

# Copy built app to NGINX's HTML directory
COPY --from=build /app/dist /usr/share/nginx/html

# Add a custom NGINX configuration to handle routing
COPY nginx.conf /etc/nginx/conf.d/default.conf

# Expose the default NGINX port
EXPOSE 80

# Start NGINX
CMD ["nginx", "-g", "daemon off;"]
