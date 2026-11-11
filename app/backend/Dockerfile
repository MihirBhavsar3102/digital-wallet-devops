# syntax=docker/dockerfile:1

# One pinned base for every stage. Node 20 reached end of life in April 2026, so this is 22 LTS.
# Debian (glibc) rather than Alpine: Prisma's engines and bcrypt's prebuilt binary both target it.
ARG NODE_IMAGE=node:22.23.4-bookworm-slim

# ---- base: Node plus OpenSSL.
# Prisma picks its engine binaries by the OpenSSL version it detects. The slim image has no
# OpenSSL, and without it Prisma falls back to "openssl-1.1.x" engines that then do not load
# here. Every stage derives from this one, so install and runtime detect the same platform.
FROM ${NODE_IMAGE} AS base
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# ---- build: all dependencies, Prisma client, Nest build -> dist/
FROM base AS build
COPY package.json package-lock.json ./
RUN npm ci
COPY nest-cli.json tsconfig.json tsconfig.build.json ./
COPY prisma ./prisma
COPY src ./src
RUN npx prisma generate && npm run build

# ---- prod-deps: production dependencies only, with the Prisma client generated for them.
# Generating after the install (not pruning afterwards) keeps the generated client in place.
FROM base AS prod-deps
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY prisma ./prisma
RUN npx prisma generate

# ---- runtime
FROM base AS runtime
ENV NODE_ENV=production \
    PORT=8081
COPY --from=prod-deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
# schema + migrations: deploy.sh runs "prisma migrate deploy" from this image before restarting.
COPY --chown=node:node prisma ./prisma
# The base image's non-root "node" user (uid and gid 1000), as numbers so that the host and
# Kubernetes-style policies can verify it is not root.
USER 1000:1000
EXPOSE 8081
# node directly, not npm, so SIGTERM from "docker stop" reaches the app.
CMD ["node", "dist/main.js"]
