# Blue/Green Deployment System

A comprehensive toolkit for implementing zero-downtime deployments using the blue/green deployment strategy. This toolkit enables continuous integration and deployment pipelines to maintain two identical environments, gradually shift traffic between them, and achieve seamless updates with no downtime.

## What Is This?

This is a collection of deployment scripts and configuration templates that your CI/CD pipeline installs **directly on your production server** to enable blue/green deployments. Think of it as a server-side deployment toolkit that works with your existing Docker-based applications.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Application Requirements](#application-requirements)
- [CI/CD Integration](#cicd-integration)
- [Command Reference](#command-reference)
- [Plugin System](#plugin-system)
- [Multi-Container Support](#multi-container-support)
- [Domain-Based Routing](#domain-based-routing)
- [Advanced Configuration](#advanced-configuration)
- [Troubleshooting](#troubleshooting)
- [Security Best Practices](#security-best-practices)

## Overview

Blue/green deployment is a release technique that reduces downtime and risk by running two identical production environments called "Blue" and "Green":

- **Blue Environment**: One of the production environments
- **Green Environment**: The other production environment

At any time, only one of these environments receives production traffic. This toolkit adds blue/green deployment capabilities to your existing Docker applications by:

1. Creating two separate but identical environments on your server
2. Setting up Nginx as a reverse proxy for traffic control
3. Managing the deployment, health checking, and traffic shifting
4. Providing rollback capabilities if issues are detected

Key features:
- Zero-downtime deployments
- Gradual traffic shifting
- Automated health checks
- Simple rollback process
- Environment cleanup tools
- Comprehensive plugin system
- Multi-container and multi-domain support
- Database migration handling with rollback capabilities
- Service discovery and registry
- SSL certificate automation with Let's Encrypt
- Deployment event logging and monitoring

## How It Works

This toolkit works with your existing `docker-compose.yml` and `Dockerfile`:

1. It creates environment-specific versions of your Docker Compose setup
2. It configures Nginx as a load balancer in front of your application
3. It manages which environment receives traffic and at what percentage
4. It orchestrates the deployment, testing, and cutover process

### Infrastructure Changes

This system modifies your infrastructure from a single application to a blue/green deployment model:

```mermaid
flowchart LR
    subgraph before [" Before "]
        direction TB
        A["`**Docker**<br>Application`"]
    end
    
    before -.- after
    
    subgraph after [" After "]
        direction TB
        B["`**Nginx**<br>Load Balancer`"]
        C["`**Blue**<br>Environment`"]
        D["`**Green**<br>Environment`"]
        B --> C
        B --> D
    end
    
    classDef container fill:#f8f9fa,stroke:#343a40,stroke-width:2px,rx:5,ry:5
    classDef blue fill:#cce5ff,stroke:#004085,stroke-width:2px,rx:5,ry:5
    classDef green fill:#d4edda,stroke:#155724,stroke-width:2px,rx:5,ry:5
    
    class A,B container
    class C blue
    class D green
```

### Multi-Container Infrastructure

With the multi-container support, your infrastructure can support both stateless (blue/green deployed) and stateful (shared) services:

```mermaid
flowchart TB
    loadBalancer["`**Nginx**<br>Load Balancer`"]
    
    subgraph blue [" Blue Environment "]
        blueApp["`**App**<br>Service`"]
        blueFrontend["`**Frontend**<br>Service`"]
    end
    
    subgraph green [" Green Environment "]
        greenApp["`**App**<br>Service`"]
        greenFrontend["`**Frontend**<br>Service`"]
    end
    
    subgraph shared [" Shared Services "]
        db["`**Database**<br>Stateful`"]
        redis["`**Redis**<br>Stateful`"]
    end
    
    loadBalancer --> blueApp
    loadBalancer --> greenApp
    loadBalancer --> blueFrontend
    loadBalancer --> greenFrontend
    
    blueApp --> db
    blueApp --> redis
    greenApp --> db
    greenApp --> redis
    
    classDef container fill:#f8f9fa,stroke:#343a40,stroke-width:2px,rx:5,ry:5
    classDef blue fill:#cce5ff,stroke:#004085,stroke-width:2px,rx:5,ry:5
    classDef green fill:#d4edda,stroke:#155724,stroke-width:2px,rx:5,ry:5
    classDef shared fill:#ffe8cc,stroke:#995500,stroke-width:2px,rx:5,ry:5
    
    class loadBalancer container
    class blueApp,blueFrontend blue
    class greenApp,greenFrontend green
    class db,redis shared
```

### Deployment Flow Diagram

The deployment process follows this flow:

```mermaid
flowchart TD
    %% Styling and layout
    classDef primary fill:#4169E1,stroke:#0D47A1,color:white,stroke-width:2px
    classDef secondary fill:#FF6347,stroke:#B22222,color:white,stroke-width:2px
    classDef success fill:#2E8B57,stroke:#006400,color:white,stroke-width:2px
    classDef warning fill:#FF8C00,stroke:#D2691E,color:white,stroke-width:2px
    classDef process fill:#9370DB,stroke:#4B0082,color:white,stroke-width:2px
    classDef decision fill:#FFD700,stroke:#B8860B,color:black,stroke-width:2px
    
    %% Nodes
    A["`**Build & Push**<br>Docker Image`"] --> B["`**Deploy**<br>To Inactive Environment`"]
    B --> C{"`**Health Checks**<br>Application Ready?`"}
    C -->|Pass| D["`**Database Migrations**<br>Apply Schema Changes`"]
    D --> E{"`**Migration Checks**<br>Database Updated?`"}
    E -->|Pass| F["`**Traffic Shift**<br>10% to New Environment`"]
    E -->|Fail| G["`**Rollback**<br>Database Changes`"]
    G --> Z["`**Abort**<br>Deployment Failed`"]
    C -->|Fail| Z
    F --> H["`**Traffic Shift**<br>50% to New Environment`"]
    H --> I["`**Traffic Shift**<br>90% to New Environment`"]
    I --> J{"`**Verification**<br>All Systems Go?`"}
    J -->|Yes| K["`**Cutover**<br>100% Traffic to New`"]
    J -->|No| L["`**Rollback**<br>Revert to Original`"]
    K --> M["`**Service Registration**<br>Update Service Registry`"]
    M --> N["`**Cleanup**<br>Stop Old Environment`"]
    L --> O["`**Revert**<br>Shift Traffic Back`"]
    
    %% Apply classes
    class A,B process
    class C,E,J decision
    class D,F,H,I primary
    class G,L,O,Z secondary
    class K,M,N success
```

## Prerequisites

To use this toolkit, you need:
- A Linux server
- Docker and Docker Compose installed on your server
- CI/CD platform with SSH access to your server (GitHub Actions, GitLab CI, etc.)
- Server location for your deployments (e.g., `/app/your-project`)

For advanced features like SSL automation:
- DNS properly configured for your domain(s)
- Access to port 80 and 443 for Let's Encrypt verification
- Public IP address for your server

## Application Requirements

### Health Check Endpoint

Your application **must have a health check endpoint** for the blue/green deployment to work properly. This endpoint should:

1. Return a successful status code (200) when the application is healthy
2. Return an error status code when the application is not healthy
3. Check internal dependencies (database, cache, etc.) if appropriate

### Example Health Check Implementations

#### Node.js (Express) Example:

```javascript
// health.js
const express = require('express');
const router = express.Router();

router.get('/', async (req, res) => {
  try {
    // Optional: Check database connection
    // await db.query('SELECT 1');
    
    // Optional: Check cache connection
    // await redis.ping();
    
    res.status(200).json({ status: 'healthy' });
  } catch (error) {
    res.status(500).json({ status: 'unhealthy', error: error.message });
  }
});

module.exports = router;

// app.js
app.use('/health', require('./health'));
```

#### Python (Flask) Example:

```python
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/health')
def health_check():
    try:
        # Optional: Check database connection
        # db.session.execute('SELECT 1')
        
        return jsonify({"status": "healthy"}), 200
    except Exception as e:
        return jsonify({"status": "unhealthy", "error": str(e)}), 500
```

## CI/CD Integration

The blue/green deployment toolkit is designed to be integrated into your CI/CD pipeline. Here's a comprehensive GitHub Actions example:

```yaml
name: CI/CD with Blue-Green Deployment

on:
  push:
    branches: [main]
  schedule:
    # Run cleanup job every day at 2:00 AM UTC
    - cron: '0 2 * * *'

jobs:
  test-and-build:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.versioning.outputs.version }}
    steps:
      - uses: actions/checkout@v4
      
      # Add your testing steps here
      
      - name: Set version
        id: versioning
        run: echo "version=$(date +'%Y%m%d.%H%M%S')" >> $GITHUB_OUTPUT
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Login to Docker Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository }}:${{ steps.versioning.outputs.version }}
            ghcr.io/${{ github.repository }}:latest
    
  deploy:
    needs: test-and-build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      # Copy deployment toolkit and configuration to server
      - name: Copy deployment toolkit to server
        uses: appleboy/scp-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          source: "docker-compose.yml,Dockerfile"
          target: '/app/myapp'
          strip_components: 0
      
      # Deploy to Production
      - name: Deploy to Production
        uses: appleboy/ssh-action@master
        env:
          VERSION: ${{ needs.test-and-build.outputs.version }}
          IMAGE_REPO: "ghcr.io/${{ github.repository }}"
          # Application environment variables
          APP_API_ENDPOINT: ${{ vars.APP_API_ENDPOINT }}
          APP_CONFIG_VALUE: ${{ vars.APP_CONFIG_VALUE }}
          APP_SECRET_KEY: ${{ secrets.APP_SECRET_KEY }}
          APP_CORS_ORIGINS: ${{ vars.APP_CORS_ORIGINS }}
          # SSL configuration
          DOMAIN_NAME: ${{ vars.DOMAIN_NAME }}
          CERTBOT_EMAIL: ${{ vars.CERTBOT_EMAIL }}
          # Database configuration
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
          # Notification configuration
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          envs: VERSION,IMAGE_REPO,APP_API_ENDPOINT,APP_CONFIG_VALUE,APP_SECRET_KEY,APP_CORS_ORIGINS,DOMAIN_NAME,CERTBOT_EMAIL,DATABASE_URL,TELEGRAM_BOT_TOKEN,TELEGRAM_CHAT_ID
          script: |
            cd /app/myapp
            
            # Deploy with enhanced toolkit
            ./scripts/bgd-deploy.sh "$VERSION" \
              --app-name=myapp \
              --image-repo=$IMAGE_REPO \
              --auto-port-assignment \
              --auto-rollback \
              --notify-enabled \
              --telegram-bot-token="$TELEGRAM_BOT_TOKEN" \
              --telegram-chat-id="$TELEGRAM_CHAT_ID" \
              --domain-name="$DOMAIN_NAME" \
              --certbot-email="$CERTBOT_EMAIL"
            
            # Complete the cutover
            ./scripts/bgd-cutover.sh green --app-name=myapp
  
  cleanup:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - name: Cleanup old environments
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd /app/myapp
            ./scripts/bgd-cleanup.sh \
              --app-name=myapp \
              --old-only \
              --cleanup-orphans
```

### Configuring Your Deployment

The blue/green deployment system uses command-line parameters for configuration:

```bash
./scripts/bgd-deploy.sh "$VERSION" \
  --app-name=myapp \
  --image-repo=ghcr.io/myusername/myproject \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --database-url="postgresql://user:pass@host/db" \
  --domain-name="example.com" \
  --ssl-enabled=true \
  --certbot-email="admin@example.com" \
  --auto-port-assignment \
  --auto-rollback \
  --notify-enabled
```

Benefits of this approach:
- No need to create or maintain config files
- Explicit parameters make it clear what values are being passed
- Better traceability in logs and deployment history
- Easier to test different configurations

## Command Reference

The deployment toolkit provides these commands:

### Deploy

```bash
./scripts/bgd-deploy.sh VERSION [OPTIONS]

# Required Arguments:
#   VERSION                Version identifier for the deployment

# Required Options:
#   --app-name=NAME       Application name
#   --image-repo=REPO     Docker image repository

# Port Options:
#   --nginx-port=PORT     Nginx HTTP port (default: 80)
#   --nginx-ssl-port=PORT Nginx HTTPS port (default: 443)
#   --blue-port=PORT      Blue environment port (default: 8081)
#   --green-port=PORT     Green environment port (default: 8082)
#   --auto-port-assignment Automatically assign available ports

# Health Check Options:
#   --health-endpoint=PATH Health check endpoint (default: /health)
#   --health-retries=N    Number of health check retries (default: 12)
#   --health-delay=SEC    Delay between health checks (default: 5)
#   --timeout=SEC         Timeout for health check requests (default: 5)
#   --collect-logs        Collect container logs on failure
#   --max-log-lines=N     Maximum number of log lines to collect (default: 100)
#   --retry-backoff       Use exponential backoff for health check retries

# Deployment Options:
#   --domain-name=DOMAIN  Domain name for multi-domain routing
#   --frontend-image-repo=REPO Frontend image repository
#   --frontend-version=VER Frontend version (defaults to same as VERSION)
#   --setup-shared        Initialize shared services (database, cache, etc.)
#   --skip-migrations     Skip database migrations
#   --migrations-cmd=CMD  Custom migrations command
#   --force               Force deployment even if target environment is active
#   --no-shift            Don't shift traffic automatically

# Advanced Options:
#   --auto-rollback       Automatically roll back failed deployments
#   --notify-enabled      Enable notifications
#   --telegram-bot-token=TOK Telegram bot token for notifications
#   --telegram-chat-id=ID Telegram chat ID for notifications
#   --slack-webhook=URL   Slack webhook URL for notifications

# Examples:
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --domain-name=example.com --setup-shared
```

### Cutover

```bash
./scripts/bgd-cutover.sh [blue|green] [OPTIONS]

# Required Arguments:
#   [blue|green]          Target environment to cutover to

# Required Options:
#   --app-name=NAME       Application name

# Configuration Options:
#   --domain-name=DOMAIN  Domain name for multi-domain routing
#   --nginx-port=PORT     Nginx external port (default: 80)
#   --nginx-ssl-port=PORT Nginx HTTPS port (default: 443)
#   --blue-port=PORT      Blue environment port (default: 8081)
#   --green-port=PORT     Green environment port (default: 8082)
#   --keep-old            Don't stop the previous environment

# Examples:
./scripts/bgd-cutover.sh green --app-name=myapp
./scripts/bgd-cutover.sh blue --app-name=myapp --keep-old --domain-name=example.com
```

### Rollback

```bash
./scripts/bgd-rollback.sh [OPTIONS]

# Required Options:
#   --app-name=NAME       Application name

# Advanced Options:
#   --force               Force rollback even if environment is unhealthy

# Examples:
./scripts/bgd-rollback.sh --app-name=myapp
./scripts/bgd-rollback.sh --app-name=myapp --force
```

### Cleanup

```bash
./scripts/bgd-cleanup.sh [OPTIONS]

# Required Options:
#   --app-name=NAME       Application name

# Cleanup Options:
#   --all                 Clean up everything including current active environment
#   --failed-only         Clean up only failed deployments
#   --old-only            Clean up only old, inactive environments
#   --cleanup-networks    Clean up orphaned networks
#   --cleanup-volumes     Clean up volumes (excluding persistent volumes)
#   --cleanup-orphans     Clean up orphaned containers
#   --cleanup-all-resources Clean up all resources (networks, volumes, containers)
#   --dry-run             Only show what would be cleaned without actually removing anything

# Examples:
./scripts/bgd-cleanup.sh --app-name=myapp --failed-only
./scripts/bgd-cleanup.sh --app-name=myapp --old-only --cleanup-orphans
```

### Health Check

```bash
./scripts/bgd-health-check.sh [ENDPOINT] [OPTIONS]

# Arguments:
#   ENDPOINT              URL to check (e.g., http://localhost:8081/health)

# Health Check Options:
#   --app-name=NAME       Application name
#   --retries=N           Number of health check retries (default: 12)
#   --delay=SEC           Delay between health checks (default: 5)
#   --timeout=SEC         Timeout for each request (default: 5)
#   --retry-backoff       Use exponential backoff for retries
#   --collect-logs        Collect container logs on failure
#   --max-log-lines=N     Maximum number of log lines to collect (default: 100)

# Examples:
./scripts/bgd-health-check.sh http://localhost:8081/health
./scripts/bgd-health-check.sh http://localhost:8081/health --retries=10 --delay=5 --retry-backoff
```

## Plugin System

The plugin system allows you to extend the deployment process with custom hooks and functionality.

### Available Plugins

#### Database Migrations Plugin

The database migrations plugin provides advanced database migration capabilities:

- Schema and full database backups
- Zero-downtime migrations with shadow database approach
- Automatic rollback capabilities

```bash
# Enable database migrations with shadow database
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --database-url="postgresql://user:pass@host/db" \
  --db-shadow-enabled=true \
  --skip-migrations=false \
  --migrations-cmd="npm run migrate"
```

#### Service Discovery Plugin

The service discovery plugin enables automatic service registration and discovery:

- Registers services with internal registry
- Updates environment variables for service URLs
- Supports multi-service architectures

```bash
# Enable service discovery
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --service-registry-enabled=true \
  --service-auto-generate-urls=true
```

#### SSL Automation Plugin

The SSL automation plugin handles SSL certificate management:

- Automatic certificate generation with Let's Encrypt
- Nginx SSL configuration
- Certificate renewal management

```bash
# Enable SSL automation
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --domain-name="example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true
```

#### Notification Plugin

The notification plugin provides deployment event notifications:

- Telegram notifications
- Slack notifications
- Customizable notification levels and events

```bash
# Enable notifications
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --notify-enabled=true \
  --telegram-bot-token="your-token" \
  --telegram-chat-id="your-chat-id"
```

#### Audit Logging Plugin

The audit logging plugin provides deployment event tracking:

- Records deployment events with timestamps
- Captures environment details
- Provides deployment history and reports

```bash
# Configure audit logging
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --audit-log-level="info" \
  --audit-retention-days=90
```

## Multi-Container Support

The system supports deploying multiple containers as part of a single blue/green deployment:

- Deploy both backend and frontend applications
- Share stateful services (database, cache) between environments
- Configure network and volume management

### Stateless vs Stateful Services

The system distinguishes between two types of services:

- **Stateless services** (marked with `bgd.role=deployable`): These services are deployed in both blue and green environments and can be swapped without data loss
- **Stateful services** (marked with `bgd.role=persistent`): These services are shared between environments and persist data between deployments

### Shared Services Setup

To set up shared services during initial deployment:

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --setup-shared \
  --domain-name=example.com
```

This will:
1. Create shared Docker networks
2. Create persistent volumes for stateful services
3. Start shared services with the appropriate profiles

## Domain-Based Routing

The system supports routing traffic to different services based on domains:

- Configure multiple domains and subdomains
- Direct traffic to different services based on domain
- Support for SSL certificates for all domains

### Domain Configuration

```bash
# Configure domain-based routing
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --domain-name="example.com" \
  --ssl-enabled=true
```

This will generate an Nginx configuration that routes traffic based on domains:
- `example.com` and `www.example.com` -> Main application
- `api.example.com` -> API service

## Advanced Configuration

### Custom Nginx Configuration

For advanced Nginx configuration (SSL, custom routing, etc.), you can modify the templates:

- `config/templates/nginx-single-env.conf.template`
- `config/templates/nginx-dual-env.conf.template`
- `config/templates/nginx-multi-domain.conf.template`

### Docker Compose Override

For custom Docker Compose configuration, you can modify:

- `config/templates/docker-compose.override.template`

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Health check failing | Check application logs with `docker logs` |
| Port conflicts | Use `--auto-port-assignment` flag |
| Database migration failures | Check database credentials and migration script |
| SSL certificate generation fails | Verify domain DNS configuration and firewall settings |
| Shared services not starting | Check volume permissions and network configuration |

### Viewing Logs

```bash
# View logs from a specific environment
docker compose -p myapp-blue logs

# View logs from a specific service
docker compose -p myapp-blue logs app

# View recent deployment logs
cat logs/bgd-*.log
```

## Security Best Practices

### Docker Security

Run your application container as a non-root user:

```dockerfile
FROM node:18-alpine

WORKDIR /app

# Add a non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Set proper ownership
RUN chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Rest of your Dockerfile...
```

### CI/CD Security

Follow these security best practices in your CI/CD pipelines:

1. **Use secrets for sensitive data**: Store credentials, API keys, and other sensitive data as CI/CD secrets
2. **Limit SSH access**: Use dedicated deployment users with restricted permissions
3. **Use read-only tokens**: When pulling from Docker registries, use read-only tokens where possible
4. **Scan images**: Include container security scanning in your pipeline