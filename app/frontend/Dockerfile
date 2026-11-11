# syntax=docker/dockerfile:1

# ---- build: Vite bundle
FROM node:22.23.4-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# Vite bakes VITE_* values into the bundle at build time, so this is a build argument. The
# relative "/api" lets one image work behind any load balancer hostname: the ALB sends /api/*
# to the backend. Local compose overrides it with the backend's full URL.
ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN npm run build

# ---- serve: nginx with our own config
FROM nginx:1.31.8-alpine
# The pinned base still carries libxslt 1.1.43-r3, which has two HIGH CVEs fixed in -r4, and the image
# scan in CI fails on fixable HIGH findings. Upgrade only that package. Remove this line once the
# base image ships the fixed version (the next nginx tag).
RUN apk upgrade --no-cache libxslt
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
