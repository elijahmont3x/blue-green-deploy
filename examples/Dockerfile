FROM node:18-alpine

WORKDIR /app

RUN apk add --no-cache curl

# Add a non-root user - IMPORTANT SECURITY FEATURE
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Example with npm (generic)
COPY package*.json ./
RUN npm ci --only=production

# Example with pnpm (commented)
# COPY package.json pnpm-lock.yaml ./
# RUN corepack enable && corepack prepare pnpm@latest --activate && pnpm install --prod

COPY . .
RUN npm run build && \
    # Set proper ownership
    chown -R appuser:appgroup /app

ENV NODE_ENV=production

# Switch to non-root user - IMPORTANT SECURITY FEATURE
USER appuser

HEALTHCHECK --interval=5s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

# Make sure port 3000 is available to the host
EXPOSE 3000
CMD ["node", "dist/main"]