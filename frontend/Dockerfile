# Specify the Node.js version explicitly
FROM node:20.19.6-alpine AS base

# Set working directory
WORKDIR /app

# Install dependencies only when needed
FROM base AS deps
RUN apk add --no-cache libc6-compat

# Copy package files for better caching
COPY package*.json ./

# Install dependencies with caching
RUN \
  if [ -f package-lock.json ]; then \
  npm ci --legacy-peer-deps --prefer-offline; \
  else \
  npm install --legacy-peer-deps --prefer-offline; \
  fi

# Rebuild the source code only when needed
FROM base AS builder

# Accept build arguments with default values for flexibility (Docker Compose)
ARG NEXT_PUBLIC_APP_NAME=""
ARG NEXT_PUBLIC_API_URL=""
ARG NEXT_PUBLIC_CART_API_URL=""
ARG NEXT_PUBLIC_CHAT_DEPLOYMENT=""
ARG NEXT_PUBLIC_CHAT_TITLE=""

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Set environment variables and build
RUN if [ -f .env ]; then \
  set -a && . ./.env && set +a; \
  else \
  export NEXT_PUBLIC_APP_NAME="${NEXT_PUBLIC_APP_NAME}"; \
  export NEXT_PUBLIC_API_URL="${NEXT_PUBLIC_API_URL}"; \
  export NEXT_PUBLIC_CART_API_URL="${NEXT_PUBLIC_CART_API_URL}"; \
  export NEXT_PUBLIC_CHAT_DEPLOYMENT="${NEXT_PUBLIC_CHAT_DEPLOYMENT}"; \
  export NEXT_PUBLIC_CHAT_TITLE="${NEXT_PUBLIC_CHAT_TITLE}"; \
  fi && \
  npm run build --legacy-peer-deps

# Build with output tracing for better optimization
# RUN npm run build --legacy-peer-deps (moved to the builder stage)

# Production image, copy all the files and run next
FROM base AS runner

RUN addgroup --system --gid 1001 nodejs && \
  adduser --system --uid 1001 nextjs

# Copy only necessary files
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000
CMD ["node", "server.js"]