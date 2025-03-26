# Blue/Green Deployment System Usage Examples

This document provides practical examples of how to use the Blue/Green Deployment System in various scenarios.

## Table of Contents

- [Basic Deployment](#basic-deployment)
- [Multi-Container Deployment](#multi-container-deployment)
- [Using the Database Migrations Plugin](#using-the-database-migrations-plugin)
- [Using the Service Discovery Plugin](#using-the-service-discovery-plugin)
- [Using the SSL Automation Plugin](#using-the-ssl-automation-plugin)
- [Using the Notification Plugin](#using-the-notification-plugin)
- [Advanced Scenarios](#advanced-scenarios)
  - [Full Multi-Environment Setup](#full-multi-environment-setup)
  - [Hybrid Frontend/Backend Deployment](#hybrid-frontendbackend-deployment)
  - [Multiple Independent Applications](#multiple-independent-applications)

## Basic Deployment

This example shows a basic deployment of a simple application:

```bash
# Initial deployment
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health

# For subsequent deployments
./scripts/bgd-deploy.sh v1.0.1 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health

# Complete the cutover to the new version
./scripts/bgd-cutover.sh green --app-name=myapp
```

### GitHub Actions Workflow

```yaml
name: Basic Deployment

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set version
        id: versioning
        run: echo "version=$(date +'%Y%m%d.%H%M%S')" >> $GITHUB_OUTPUT
      
      - name: Deploy to Production
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd /app/myapp
            
            # Deploy
            ./scripts/bgd-deploy.sh "${{ steps.versioning.outputs.version }}" \
              --app-name=myapp \
              --image-repo=ghcr.io/myorg/myapp \
              --nginx-port=80 \
              --blue-port=8081 \
              --green-port=8082 \
              --health-endpoint=/health
            
            # Complete the cutover
            ./scripts/bgd-cutover.sh $(grep -q blue nginx.conf && echo "green" || echo "blue") \
              --app-name=myapp
```

## Multi-Container Deployment

This example shows deploying multiple containers with shared services:

```bash
# Initial deployment with shared services setup
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/backend \
  --frontend-image-repo=ghcr.io/myorg/frontend \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --setup-shared \
  --database-url="postgresql://user:pass@localhost/myapp"

# Subsequent deployment
./scripts/bgd-deploy.sh v1.0.1 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/backend \
  --frontend-image-repo=ghcr.io/myorg/frontend \
  --frontend-version=v2.0.0 \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --database-url="postgresql://user:pass@localhost/myapp"
```

### docker-compose.yml for Multi-Container Setup

```yaml
version: '3.8'
name: ${APP_NAME:-myapp}

networks:
  shared-network:
    name: ${APP_NAME}-shared-network
    external: ${SHARED_NETWORK_EXISTS:-false}
  env-network:
    name: ${APP_NAME}-${ENV_NAME}-network
    driver: bridge

volumes:
  db-data:
    name: ${APP_NAME}-db-data
    external: ${DB_DATA_EXISTS:-false}

services:
  # Backend API
  app:
    image: ${IMAGE_REPO:-ghcr.io/myorg/backend}:${VERSION:-latest}
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - DATABASE_URL=${DATABASE_URL}
    ports:
      - '${PORT:-3000}:3000'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:3000/health']
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - env-network
      - shared-network
    labels:
      - "bgd.role=deployable"

  # Frontend application
  frontend:
    image: ${FRONTEND_IMAGE_REPO:-ghcr.io/myorg/frontend}:${FRONTEND_VERSION:-latest}
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - API_URL=http://app:3000
    ports:
      - '${FRONTEND_PORT:-8080}:80'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:80/health']
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - env-network
      - shared-network
    labels:
      - "bgd.role=deployable"

  # Database (shared)
  db:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_DB=${DB_NAME:-myapp}
      - POSTGRES_USER=${DB_USER:-postgres}
      - POSTGRES_PASSWORD=${DB_PASSWORD:-postgres}
    volumes:
      - db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-postgres}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - shared-network
    labels:
      - "bgd.role=persistent"
    profiles:
      - shared

  # Nginx (reverse proxy)
  nginx:
    image: nginx:stable-alpine
    restart: unless-stopped
    ports:
      - '${NGINX_PORT:-80}:80'
      - '${NGINX_SSL_PORT:-443}:443'
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    networks:
      - env-network
      - shared-network
    depends_on:
      - app
      - frontend
```

## Using the Database Migrations Plugin

This example demonstrates using the database migrations plugin for zero-downtime migrations:

```bash
# Deploy with database migrations
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --database-url="postgresql://user:pass@localhost/myapp" \
  --db-shadow-enabled=true \
  --db-shadow-suffix="_shadow" \
  --migrations-cmd="npx prisma migrate deploy"
```

### Creating a Custom Migration Script

For applications with specific migration needs, you can create a custom migration script:

```bash
#!/bin/bash
# migrations.sh

# Run database migrations
echo "Running migrations for $DATABASE_URL"

# For Prisma
npx prisma migrate deploy

# For custom SQL migrations
psql "$DATABASE_URL" -f ./migrations/schema.sql

exit $?
```

Then use it in your deployment:

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --database-url="postgresql://user:pass@localhost/myapp" \
  --migrations-cmd="./migrations.sh"
```

## Using the Service Discovery Plugin

This example demonstrates using the service discovery plugin:

```bash
# Deploy with service discovery
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --service-registry-enabled=true \
  --service-auto-generate-urls=true
```

### Multi-Service Discovery

For applications with multiple services that need to discover each other:

```bash
# Deploy first service
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=auth-service \
  --image-repo=ghcr.io/myorg/auth-service \
  --nginx-port=8000 \
  --blue-port=8001 \
  --green-port=8002 \
  --health-endpoint=/health \
  --service-registry-enabled=true

# Deploy second service
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=api-service \
  --image-repo=ghcr.io/myorg/api-service \
  --nginx-port=8010 \
  --blue-port=8011 \
  --green-port=8012 \
  --health-endpoint=/health \
  --service-registry-enabled=true
```

## Using the SSL Automation Plugin

This example demonstrates using the SSL automation plugin with Let's Encrypt:

```bash
# Deploy with SSL automation
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --domain-name="example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true
```

### SSL with Multiple Domains

For applications that need SSL for multiple domains:

```bash
# Deploy with multiple domains
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --domain-name="example.com" \
  --ssl-domains="www.example.com,api.example.com,admin.example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true
```

## Using the Notification Plugin

This example demonstrates using the notification plugin:

```bash
# Deploy with Telegram notifications
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --notify-enabled=true \
  --telegram-bot-token="your-token" \
  --telegram-chat-id="your-chat-id"

# Deploy with Slack notifications
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --notify-enabled=true \
  --slack-webhook="https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

## Advanced Scenarios

### Full Multi-Environment Setup

This example demonstrates a complete multi-environment setup with all plugins enabled:

```bash
# Initial deployment with all features
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/backend \
  --frontend-image-repo=ghcr.io/myorg/frontend \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --setup-shared \
  --database-url="postgresql://user:pass@localhost/myapp" \
  --domain-name="example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true \
  --db-shadow-enabled=true \
  --service-registry-enabled=true \
  --notify-enabled=true \
  --slack-webhook="https://hooks.slack.com/services/XXX/YYY/ZZZ" \
  --auto-port-assignment \
  --auto-rollback
```

### Hybrid Frontend/Backend Deployment

This example shows how to deploy a separate frontend and backend:

```bash
# Deploy backend
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=backend \
  --image-repo=ghcr.io/myorg/backend \
  --nginx-port=8000 \
  --blue-port=8001 \
  --green-port=8002 \
  --health-endpoint=/health \
  --database-url="postgresql://user:pass@localhost/myapp" \
  --domain-name="api.example.com" \
  --ssl-enabled=true

# Deploy frontend
./scripts/bgd-deploy.sh v2.0.0 \
  --app-name=frontend \
  --image-repo=ghcr.io/myorg/frontend \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=3001 \
  --green-port=3002 \
  --health-endpoint=/health \
  --domain-name="example.com" \
  --ssl-enabled=true
```

### Multiple Independent Applications

This example shows how to manage multiple applications on the same server:

```bash
# Deploy first application
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=app1 \
  --image-repo=ghcr.io/myorg/app1 \
  --nginx-port=8001 \
  --blue-port=8011 \
  --green-port=8012 \
  --health-endpoint=/health \
  --domain-name="app1.example.com" \
  --ssl-enabled=true

# Deploy second application
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=app2 \
  --image-repo=ghcr.io/myorg/app2 \
  --nginx-port=8002 \
  --blue-port=8021 \
  --green-port=8022 \
  --health-endpoint=/health \
  --domain-name="app2.example.com" \
  --ssl-enabled=true
```

With this setup, each application operates independently with its own deployment cycle, but they can share the server resources efficiently.