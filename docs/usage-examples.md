# Blue/Green Deployment System Usage Examples

This document provides practical examples of how to use the enhanced Blue/Green Deployment System in various scenarios.

## Table of Contents

- [Basic Deployment](#basic-deployment)
- [Multi-Container Deployment](#multi-container-deployment)
- [Using the Database Migrations Plugin](#using-the-database-migrations-plugin)
- [Using the Service Discovery Plugin](#using-the-service-discovery-plugin)
- [Using the SSL Automation Plugin](#using-the-ssl-automation-plugin)
- [Using the Audit Logging Plugin](#using-the-audit-logging-plugin)
- [Custom Plugin Example](#custom-plugin-example)
- [Advanced Scenarios](#advanced-scenarios)
  - [Full Multi-Environment Setup](#full-multi-environment-setup)
  - [Hybrid Frontend/Backend Deployment](#hybrid-frontendbackend-deployment)
  - [Multiple Independent Applications](#multiple-independent-applications)

## Basic Deployment

This example shows a basic deployment of a simple application:

```bash
# Initial deployment
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health

# After deployment completes, complete the cutover
./scripts/cutover.sh blue --app-name=myapp

# For the next deployment (to the green environment)
./scripts/deploy.sh v1.0.1 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health

# Complete the cutover to the new version
./scripts/cutover.sh green --app-name=myapp
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
            ./scripts/deploy.sh "${{ steps.versioning.outputs.version }}" \
              --app-name=myapp \
              --image-repo=ghcr.io/myorg/myapp \
              --nginx-port=80 \
              --blue-port=8081 \
              --green-port=8082 \
              --health-endpoint=/health
            
            # Complete the cutover
            ./scripts/cutover.sh $(grep -q blue nginx.conf && echo "green" || echo "blue") \
              --app-name=myapp
```

## Multi-Container Deployment

This example shows deploying multiple containers with shared services:

```bash
# Initial deployment with shared services setup
./scripts/deploy.sh v1.0.0 \
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
./scripts/deploy.sh v1.0.1 \
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
    image: postgres:14-alpine
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
./scripts/deploy.sh v1.0.0 \
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
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --database-url="postgresql://user:pass@localhost/myapp" \
  --migrations-cmd="./migrations.sh"
```

### GitHub Actions Workflow with Database Migrations

```yaml
name: Deploy with Migrations

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
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          envs: DATABASE_URL
          script: |
            cd /app/myapp
            
            # Export database URL
            export DATABASE_URL="$DATABASE_URL"
            
            # Deploy with migrations
            ./scripts/deploy.sh "${{ steps.versioning.outputs.version }}" \
              --app-name=myapp \
              --image-repo=ghcr.io/myorg/myapp \
              --db-shadow-enabled=true
```

## Using the Service Discovery Plugin

This example demonstrates using the service discovery plugin:

```bash
# Deploy with service discovery
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --service-registry-enabled=true \
  --service-registry-url="http://registry:8080" \
  --service-auto-generate-urls=true
```

### Multi-Service Discovery with External Registry

For applications with multiple services that need to discover each other:

```bash
# Deploy first service
./scripts/deploy.sh v1.0.0 \
  --app-name=auth-service \
  --image-repo=ghcr.io/myorg/auth-service \
  --nginx-port=8000 \
  --blue-port=8001 \
  --green-port=8002 \
  --health-endpoint=/health \
  --service-registry-enabled=true \
  --service-registry-url="http://registry.example.com"

# Deploy second service
./scripts/deploy.sh v1.0.0 \
  --app-name=api-service \
  --image-repo=ghcr.io/myorg/api-service \
  --nginx-port=8010 \
  --blue-port=8011 \
  --green-port=8012 \
  --health-endpoint=/health \
  --service-registry-enabled=true \
  --service-registry-url="http://registry.example.com"
```

## Using the SSL Automation Plugin

This example demonstrates using the SSL automation plugin with Let's Encrypt:

```bash
# Deploy with SSL automation
./scripts/deploy.sh v1.0.0 \
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
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --domain-name="example.com" \
  --alt-domains="www.example.com,api.example.com,admin.example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true
```

### GitHub Actions Workflow with SSL Automation

```yaml
name: Deploy with SSL

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
            
            # Deploy with SSL
            ./scripts/deploy.sh "${{ steps.versioning.outputs.version }}" \
              --app-name=myapp \
              --image-repo=ghcr.io/myorg/myapp \
              --domain-name="${{ secrets.DOMAIN_NAME }}" \
              --certbot-email="${{ secrets.ADMIN_EMAIL }}" \
              --ssl-enabled=true
```

## Using the Audit Logging Plugin

This example demonstrates using the audit logging plugin with Slack notifications:

```bash
# Deploy with audit logging
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --slack-webhook="https://hooks.slack.com/services/XXX/YYY/ZZZ" \
  --audit-log-level="info"
```

### Creating a Custom Notification Plugin

You can create a custom notification plugin:

```bash
#!/bin/bash
# plugins/teams-notification.sh

# Register plugin arguments
register_plugin_argument "teams-notification" "TEAMS_WEBHOOK" ""
register_plugin_argument "teams-notification" "NOTIFY_CHANNEL" "Deployments"

# Implement hooks
hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ -n "${TEAMS_WEBHOOK:-}" ]; then
    log_info "Sending deployment notification to Microsoft Teams"
    
    # Create JSON payload
    local payload=$(cat << EOF
{
  "@type": "MessageCard",
  "@context": "http://schema.org/extensions",
  "themeColor": "0076D7",
  "summary": "Deployment Notification",
  "sections": [{
    "activityTitle": "🚀 Deployment Successful",
    "facts": [
      { "name": "Application", "value": "${APP_NAME}" },
      { "name": "Version", "value": "${version}" },
      { "name": "Environment", "value": "${env_name}" },
      { "name": "Time", "value": "$(date "+%Y-%m-%d %H:%M:%S")" }
    ]
  }]
}
EOF
)
    
    # Send notification to Teams
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "${TEAMS_WEBHOOK}"
  fi
  
  return 0
}

hook_post_rollback() {
  local rollback_env="$1"
  
  if [ -n "${TEAMS_WEBHOOK:-}" ]; then
    log_info "Sending rollback notification to Microsoft Teams"
    
    # Create JSON payload
    local payload=$(cat << EOF
{
  "@type": "MessageCard",
  "@context": "http://schema.org/extensions",
  "themeColor": "FF0000",
  "summary": "Rollback Notification",
  "sections": [{
    "activityTitle": "⚠️ Rollback Performed",
    "facts": [
      { "name": "Application", "value": "${APP_NAME}" },
      { "name": "Environment", "value": "${rollback_env}" },
      { "name": "Time", "value": "$(date "+%Y-%m-%d %H:%M:%S")" }
    ]
  }]
}
EOF
)
    
    # Send notification to Teams
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "${TEAMS_WEBHOOK}"
  fi
  
  return 0
}
```

Then use it in your deployment:

```bash
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --teams-webhook="https://outlook.office.com/webhook/XXX" \
  --notify-channel="Production"
```

## Custom Plugin Example

This example demonstrates creating a custom plugin for performance monitoring:

```bash
#!/bin/bash
# plugins/performance-monitor.sh

# Register plugin arguments
register_plugin_argument "performance-monitor" "MONITOR_ENABLED" "false"
register_plugin_argument "performance-monitor" "MONITOR_ENDPOINT" ""
register_plugin_argument "performance-monitor" "MONITOR_API_KEY" ""

# Implement hooks
hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "$MONITOR_ENABLED" != "true" ] || [ -z "$MONITOR_ENDPOINT" ]; then
    return 0
  fi
  
  log_info "Registering deployment with performance monitor"
  
  # Create payload
  local payload=$(cat << EOF
{
  "event": "deployment",
  "app": "${APP_NAME}",
  "version": "${version}",
  "environment": "${env_name}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)
  
  # Send deployment event to monitoring service
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MONITOR_API_KEY}" \
    -d "$payload" \
    "${MONITOR_ENDPOINT}/api/events"
  
  return $?
}

hook_post_cutover() {
  local new_env="$1"
  local old_env="$2"
  
  if [ "$MONITOR_ENABLED" != "true" ] || [ -z "$MONITOR_ENDPOINT" ]; then
    return 0
  fi
  
  log_info "Registering cutover with performance monitor"
  
  # Create payload
  local payload=$(cat << EOF
{
  "event": "cutover",
  "app": "${APP_NAME}",
  "new_environment": "${new_env}",
  "old_environment": "${old_env}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)
  
  # Send cutover event to monitoring service
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MONITOR_API_KEY}" \
    -d "$payload" \
    "${MONITOR_ENDPOINT}/api/events"
  
  return $?
}

# Add a pre-cutover hook to check for performance degradation
hook_pre_cutover() {
  local new_env="$1"
  local old_env="$2"
  
  if [ "$MONITOR_ENABLED" != "true" ] || [ -z "$MONITOR_ENDPOINT" ]; then
    return 0
  fi
  
  log_info "Checking performance metrics before cutover"
  
  # Query performance metrics API
  local metrics=$(curl -s -X GET \
    -H "Authorization: Bearer ${MONITOR_API_KEY}" \
    "${MONITOR_ENDPOINT}/api/metrics?app=${APP_NAME}&environment=${new_env}&last=5m")
  
  # Check for any performance degradation
  local error_rate=$(echo "$metrics" | jq -r '.error_rate')
  local response_time=$(echo "$metrics" | jq -r '.avg_response_time')
  
  log_info "New environment metrics: Error rate: $error_rate%, Response time: ${response_time}ms"
  
  # If error rate is too high, abort cutover
  if (( $(echo "$error_rate > 5.0" | bc -l) )); then
    log_error "Error rate is too high ($error_rate%). Aborting cutover."
    return 1
  fi
  
  # If response time is too high, warn but continue
  if (( $(echo "$response_time > 500" | bc -l) )); then
    log_warning "Response time is high (${response_time}ms). Proceeding with caution."
  fi
  
  return 0
}
```

Then use it in your deployment:

```bash
./scripts/deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --monitor-enabled=true \
  --monitor-endpoint="https://monitor.example.com" \
  --monitor-api-key="your-api-key"
```

## Advanced Scenarios

### Full Multi-Environment Setup

This example demonstrates a complete multi-environment setup with all plugins enabled:

```bash
# Initial deployment with all features
./scripts/deploy.sh v1.0.0 \
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
  --slack-webhook="https://hooks.slack.com/services/XXX/YYY/ZZZ" \
  --monitor-enabled=true \
  --monitor-endpoint="https://monitor.example.com" \
  --monitor-api-key="your-api-key"
```

### Hybrid Frontend/Backend Deployment

This example shows how to deploy a separate frontend and backend:

```bash
# Deploy backend
./scripts/deploy.sh v1.0.0 \
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
./scripts/deploy.sh v2.0.0 \
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
./scripts/deploy.sh v1.0.0 \
  --app-name=app1 \
  --image-repo=ghcr.io/myorg/app1 \
  --nginx-port=8001 \
  --blue-port=8011 \
  --green-port=8012 \
  --health-endpoint=/health \
  --domain-name="app1.example.com" \
  --ssl-enabled=true

# Deploy second application
./scripts/deploy.sh v1.0.0 \
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