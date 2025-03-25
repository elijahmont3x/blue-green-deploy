# Blue/Green Deployment System

A comprehensive utility for implementing zero-downtime deployments using the blue/green deployment strategy. This toolkit enables continuous integration and deployment pipelines to maintain two identical environments, gradually shift traffic between them, and achieve seamless updates with no downtime.

## What Is This?

This is **not** an application, but a collection of deployment scripts and configuration templates that your CI/CD pipeline installs **directly on your production server** to enable blue/green deployments. Think of it as a server-side deployment toolkit that works with your existing Docker-based applications.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Application Requirements](#application-requirements)
- [CI/CD Integration](#cicd-integration)
- [Service Name Configuration](#service-name-configuration)
- [Command Reference](#command-reference)
- [Plugin System](#plugin-system)
  - [Database Migrations](#database-migrations)
  - [Service Discovery](#service-discovery)
  - [SSL Automation](#ssl-automation)
  - [Audit Logging](#audit-logging)
  - [Creating Custom Plugins](#creating-custom-plugins)
- [Multi-Container Support](#multi-container-support)
- [Domain-Based Routing](#domain-based-routing)
- [Advanced Configuration](#advanced-configuration)
- [Troubleshooting](#troubleshooting)
- [Security Best Practices](#security-best-practices)
- [Changelog](#changelog)
- [Namespace Management](#namespace-management)

## Overview

Blue/green deployment is a release technique that reduces downtime and risk by running two identical production environments called "Blue" and "Green":

- **Blue Environment**: Currently in production serving live traffic
- **Green Environment**: New version being deployed and tested

This toolkit adds blue/green deployment capabilities to your existing Docker applications by:

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

With the enhanced multi-container support, your infrastructure can now support both stateless (blue/green deployed) and stateful (shared) services:

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
- A Linux server (like Vultr VPS)
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
  pull_request:
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
      
      # Download deployment toolkit from release
      - name: Download deployment toolkit
        run: |
          mkdir -p deployment
          curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/refs/tags/v2.0.0.tar.gz -o deployment/toolkit.tar.gz
      
      # Copy deployment toolkit and configuration to server
      - name: Copy deployment toolkit to server
        uses: appleboy/scp-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          source: "deployment/toolkit.tar.gz,docker-compose.yml,Dockerfile"
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
          SSL_ENABLED: ${{ vars.SSL_ENABLED || 'true' }}
          # Database configuration
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
          DB_SHADOW_ENABLED: ${{ vars.DB_SHADOW_ENABLED || 'true' }}
          # Service discovery
          SERVICE_REGISTRY_ENABLED: ${{ vars.SERVICE_REGISTRY_ENABLED || 'true' }}
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          envs: VERSION,IMAGE_REPO,APP_API_ENDPOINT,APP_CONFIG_VALUE,APP_SECRET_KEY,APP_CORS_ORIGINS,DOMAIN_NAME,CERTBOT_EMAIL,SSL_ENABLED,DATABASE_URL,DB_SHADOW_ENABLED,SERVICE_REGISTRY_ENABLED
          script: |
            cd /app/myapp
            
            # Extract toolkit if not already installed
            if [ ! -f "./scripts/bgd-deploy.sh" ]; then
              tar -xzf toolkit.tar.gz
              chmod +x ./install.sh
              ./install.sh myapp
            fi
            
            # Make scripts executable (ensures permissions are correct)
            chmod +x ./scripts/*.sh
            
            # Export application-specific environment variables BEFORE deployment
            export APP_API_ENDPOINT="$APP_API_ENDPOINT"
            export APP_CONFIG_VALUE="$APP_CONFIG_VALUE"
            export APP_SECRET_KEY="$APP_SECRET_KEY"
            export APP_CORS_ORIGINS="$APP_CORS_ORIGINS"
            
            # Export plugin-specific environment variables
            export DOMAIN_NAME="$DOMAIN_NAME"
            export CERTBOT_EMAIL="$CERTBOT_EMAIL"
            export SSL_ENABLED="$SSL_ENABLED"
            export DATABASE_URL="$DATABASE_URL"
            export DB_SHADOW_ENABLED="$DB_SHADOW_ENABLED"
            export SERVICE_REGISTRY_ENABLED="$SERVICE_REGISTRY_ENABLED"
            
            # Clean up failed deployments
            ./scripts/bgd-cleanup.sh --app-name=myapp --failed-only
            
            # Run the deployment
            ./scripts/bgd-deploy.sh "$VERSION" \
              --app-name=myapp \
              --image-repo=$IMAGE_REPO \
              --nginx-port=80 \
              --nginx-ssl-port=443 \
              --blue-port=8081 \
              --green-port=8082 \
              --health-endpoint=/health \
              --setup-shared
  
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
            ./scripts/bgd-cleanup.sh --app-name=myapp --old-only
```

### Configuring Your Deployment

The blue/green deployment system uses command-line parameters for configuration:

```yaml
./scripts/bgd-deploy.sh "$VERSION" \
  --app-name=myapp \
  --image-repo=ghcr.io/myusername/myproject \
  --nginx-port=80 \
  --nginx-ssl-port=443 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --database-url="postgresql://user:pass@host/db" \
  --api-key="your-api-key" \
  --domain-name="example.com" \
  --ssl-enabled=true \
  --certbot-email="admin@example.com" \
  --db-shadow-enabled=true \
  --service-registry-enabled=true
```

Benefits of this approach:
- No need to create or maintain config files
- Explicit parameters make it clear what values are being passed
- Better traceability in logs and deployment history
- Easier to test different configurations

### Environment Variables and Secrets

Environment variables are automatically captured and propagated to your blue/green environments:

1. **Explicit parameters**: Variables passed as command-line parameters (like `--database-url`) take highest precedence
2. **Exported variables**: Any variables exported before running the deployment script are captured
3. **System-defined patterns**: Variables matching patterns like `DB_*` or `APP_*` are automatically included
4. **Plugin-defined variables**: Variables registered by plugins (like `SSL_*` or `SERVICE_*`) are included
5. **CI/CD variables**: Variables passed via the `env:` section in your CI/CD workflow propagate properly

## Supporting Multiple Applications

For organizations with multiple applications, you can set up multiple deployment pipelines:

```yaml
# In your GitHub Actions workflow
- name: Deploy to Production
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/soluigi/backend
      
      # Extract toolkit if not already installed
      if [ ! -f "./scripts/bgd-deploy.sh" ]; then
        mkdir -p toolkit && cd toolkit
        curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/refs/tags/v2.0.0.tar.gz | tar xz --strip-components=1
        chmod +x ./install.sh
        ./install.sh backend
        cd ..
      fi
      
      # Deploy backend
      ./scripts/bgd-deploy.sh "$VERSION" \
        --app-name=backend \
        --image-repo=soluigi/backend \
        --nginx-port=8080 \
        --blue-port=8081 \
        --green-port=8082
```

Each application maintains its own copy of the deployment toolkit, but they can be organized under a common directory structure:

```
/app/soluigi/              # Organization root
├── backend/               # Backend project
│   ├── scripts/           # Deployment scripts
│   ├── docker-compose.yml
│   └── ...
│
└── website/               # Website project
    ├── scripts/           # Deployment scripts
    ├── docker-compose.yml
    └── ...
```

## Service Name Configuration

By default, the deployment system assumes your main application service is named `app` in your docker-compose.yml file. If you use a different service name, you'll need to update the Nginx configuration templates accordingly.

### Example docker-compose.yml

Here's a sample docker-compose.yml with multi-container support that works with the default configuration:

```yaml
version: '3.8'
name: ${APP_NAME:-myapp}

# Define networks that can be shared across environments
networks:
  # This network is shared between blue/green environments
  shared-network:
    name: ${APP_NAME}-shared-network
    external: ${SHARED_NETWORK_EXISTS:-false}
  # This network is environment-specific
  env-network:
    name: ${APP_NAME}-${ENV_NAME}-network
    driver: bridge

# Define volumes that persist between deployments
volumes:
  db-data:
    name: ${APP_NAME}-db-data
    external: ${DB_DATA_EXISTS:-false}
  redis-data:
    name: ${APP_NAME}-redis-data
    external: ${REDIS_DATA_EXISTS:-false}

services:
  # Blue/Green deployable services (stateless)
  # ==================================
  
  # Main application service - will be blue/green deployed
  app:  # This is the main service name the system expects by default
    image: ${IMAGE_REPO:-ghcr.io/example/myapp}:${VERSION:-latest}
    restart: unless-stopped
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - ENV_NAME=${ENV_NAME:-default}
      - DATABASE_URL=${DATABASE_URL:-postgres://postgres:postgres@db:5432/myapp}
      - REDIS_URL=${REDIS_URL:-redis://redis:6379/0}
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
    depends_on:
      - db
      - redis
    labels:
      - "bgd.role=deployable"  # Marks service as suitable for blue/green deployment

  # Frontend service - will also be blue/green deployed
  frontend:
    image: ${FRONTEND_IMAGE_REPO:-ghcr.io/example/frontend}:${FRONTEND_VERSION:-latest}
    restart: unless-stopped
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - ENV_NAME=${ENV_NAME:-default}
      - API_URL=${API_URL:-http://app:3000}
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
      - "bgd.role=deployable"  # Marks service as suitable for blue/green deployment

  # Shared/persistent services (stateful)
  # =============================
  
  # Database service - shared between blue/green environments
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
      - "bgd.role=persistent"  # Marks service as shared between environments
    profiles:
      - shared  # Only starts when explicitly included

  # Redis service - shared between blue/green environments
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - shared-network
    labels:
      - "bgd.role=persistent"  # Marks service as shared between environments
    profiles:
      - shared  # Only starts when explicitly included

  # Reverse proxy/load balancer
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
    labels:
      - "bgd.role=proxy"  # Marks service as the proxy
```

### Customizing Service Names

If your main service has a different name (e.g., "web", "api", or "frontend"), include an additional step in your CI/CD pipeline to update the templates before installation:

```yaml
# In your GitHub Actions workflow
- name: Deploy to Production
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/myapp
      
      # Extract toolkit if not already installed
      if [ ! -f "./scripts/bgd-deploy.sh" ]; then
        tar -xzf toolkit.tar.gz
        chmod +x ./install.sh
        ./install.sh myapp
        
        # Update Nginx templates to use different service name
        sed -i 's/app-1:3000/web-1:3000/g' config/templates/nginx-single-env.conf.template
        sed -i 's/app-1:3000/web-1:3000/g' config/templates/nginx-dual-env.conf.template
        sed -i 's/app-1:3000/web-1:3000/g' config/templates/nginx-multi-domain.conf.template
        
        # Update docker-compose override template
        sed -i 's/^  app:/  web:/g' config/templates/docker-compose.override.template
      fi
      
      # Continue with deployment...
```

### Port Configuration

If your application runs on a port other than 3000:

1. Update the Nginx templates in your CI/CD workflow:
   ```bash
   sed -i 's/:3000/:8000/g' config/templates/nginx-single-env.conf.template
   sed -i 's/:3000/:8000/g' config/templates/nginx-dual-env.conf.template
   sed -i 's/:3000/:8000/g' config/templates/nginx-multi-domain.conf.template
   ```

2. Update your docker-compose.yml to expose the correct port:
   ```yaml
   services:
     app:
       ports:
         - '${PORT:-8000}:8000'
   ```

## Command Reference

The deployment toolkit provides these commands that your CI/CD pipeline can use:

### Deploy

```bash
./scripts/bgd-deploy.sh VERSION [OPTIONS]

# Options:
#   --app-name=NAME           Application name
#   --image-repo=REPO         Docker image repository
#   --frontend-image-repo=REPO Frontend image repository
#   --frontend-version=VER    Frontend version (defaults to same as backend VERSION)
#   --domain-name=DOMAIN      Domain name for multi-domain routing
#   --nginx-port=PORT         Nginx HTTP port (default: 80)
#   --nginx-ssl-port=PORT     Nginx HTTPS port (default: 443)
#   --blue-port=PORT          Blue environment port (default: 8081)
#   --green-port=PORT         Green environment port (default: 8082)
#   --health-endpoint=PATH    Health check endpoint (default: /health)
#   --health-retries=N        Number of health check retries (default: 12)
#   --health-delay=SEC        Delay between health checks (default: 5)
#   --timeout=SEC             Timeout for each request (default: 5)
#   --database-url=URL        Database connection string
#   --redis-url=URL           Redis connection string
#   --api-key=KEY             API key
#   --setup-shared            Initialize shared services (first deployment)
#   --skip-migrations         Skip database migrations
#   --migrations-cmd=CMD      Custom migrations command (default: npm run migrate)
#   --force                   Force deployment even if target environment is active
#   --no-shift                Don't shift traffic automatically (manual cutover)

# Examples:
./scripts/bgd-deploy.sh v1.0 --app-name=myapp --image-repo=myname/myapp
./scripts/bgd-deploy.sh v1.1 --app-name=myapp --domain-name=example.com --setup-shared
```

### Cutover

```bash
./scripts/bgd-cutover.sh [blue|green] [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --domain-name=DOMAIN  Domain name for multi-domain routing
#   --keep-old            Don't stop the previous environment
#   --nginx-port=PORT     Nginx external port
#   --nginx-ssl-port=PORT Nginx HTTPS port
#   --blue-port=PORT      Blue environment port
#   --green-port=PORT     Green environment port
#   --health-endpoint=PATH Health check endpoint
#   --health-retries=N    Number of health check retries
#   --health-delay=SEC    Delay between health checks

# Example:
./scripts/bgd-cutover.sh green --app-name=myapp --domain-name=example.com
```

### Rollback

```bash
./scripts/bgd-rollback.sh [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --force               Force rollback even if previous environment is unhealthy
#   --nginx-port=PORT     Nginx external port
#   --blue-port=PORT      Blue environment port
#   --green-port=PORT     Green environment port
#   --health-endpoint=PATH Health check endpoint
#   --health-retries=N    Number of health check retries
#   --health-delay=SEC    Delay between health checks

# Example:
./scripts/bgd-rollback.sh --app-name=myapp
```

### Cleanup

```bash
./scripts/bgd-cleanup.sh [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --all                 Clean up everything including current active environment
#   --failed-only         Clean up only failed deployments
#   --old-only            Clean up only old, inactive environments
#   --dry-run             Only show what would be cleaned without actually removing anything

# Example:
./scripts/bgd-cleanup.sh --app-name=myapp --failed-only
```

### Health Check

```bash
./scripts/bgd-health-check.sh [ENDPOINT] [OPTIONS]

# Arguments:
#   ENDPOINT              URL to check (default: http://localhost:3000/health)

# Options:
#   --app-name=NAME       Application name
#   --retries=N           Number of health check retries (default: 5)
#   --delay=SEC           Delay between health checks (default: 10)
#   --timeout=SEC         Timeout for each request (default: 5)

# Example:
./scripts/bgd-health-check.sh http://localhost:8081/health --retries=10 --delay=5
```

## Plugin System

The enhanced plugin system allows you to extend the deployment process with custom hooks and functionality. Plugins are shell scripts that your CI/CD pipeline can place in the `plugins/` directory of your deployment environment.

### Available Hooks

- `hook_pre_deploy`: Runs before deployment starts
- `hook_post_deploy`: Runs after deployment completes
- `hook_pre_cutover`: Runs before traffic cutover
- `hook_post_cutover`: Runs after traffic cutover
- `hook_pre_rollback`: Runs before rollback
- `hook_post_rollback`: Runs after rollback
- `hook_post_health`: Runs after health checks pass
- `hook_cleanup`: Runs during cleanup operations

### Plugin Registration System

Plugins can register custom arguments that will be automatically accepted by the deployment scripts:

```bash
# In your plugin file
register_plugin_argument "plugin-name" "ARG_NAME" "default-value"
```

These arguments can then be passed to the deployment script:

```bash
./scripts/bgd-deploy.sh v1.0 --app-name=myapp --arg-name=custom-value
```

### Database Migrations

The database migrations plugin (`bgd-db-migrations.sh`) provides advanced database migration capabilities:

- Schema and full database backups
- Migration history tracking
- Rollback capabilities
- Shadow database approach for zero-downtime migrations

#### Configuration

```bash
# Enable database migrations with shadow database
./scripts/bgd-deploy.sh v1.0 \
  --app-name=myapp \
  --database-url="postgresql://user:pass@host/db" \
  --db-shadow-enabled=true \
  --db-shadow-suffix="_shadow" \
  --skip-migrations=false \
  --migrations-cmd="npm run migrate"
```

#### Zero-Downtime Migration Process

1. The plugin creates a shadow database (copy of production database)
2. Migrations are applied to the shadow database
3. The shadow database is validated
4. The main and shadow databases are swapped (renamed)
5. The application continues running with the updated schema

This approach ensures zero-downtime during schema changes, as the application only ever sees a fully migrated database.

### Service Discovery

The service discovery plugin (`bgd-service-discovery.sh`) enables automatic service registration and discovery:

- Registers services with internal and/or external registries
- Generates service URLs for environment variables
- Updates Nginx configuration for discovered services

#### Configuration

```bash
# Enable service discovery
./scripts/bgd-deploy.sh v1.0 \
  --app-name=myapp \
  --service-registry-enabled=true \
  --service-registry-url="http://registry:8080" \
  --service-auto-generate-urls=true
```

#### Service Discovery Process

1. After a successful deployment, services are registered in a local registry file
2. If configured, services are also registered with an external registry
3. Service URLs are generated and added to environment variables
4. Nginx configuration is updated to include discovered services

### SSL Automation

The SSL automation plugin (`bgd-ssl.sh`) handles SSL certificate management with Let's Encrypt:

- Automatic certificate generation and renewal
- ACME challenge configuration
- Nginx SSL configuration

#### Configuration

```bash
# Enable SSL automation
./scripts/bgd-deploy.sh v1.0 \
  --app-name=myapp \
  --domain-name="example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true \
  --certbot-staging=false
```

#### SSL Automation Process

1. Before deployment, the plugin checks if SSL certificates exist
2. If not, it configures Nginx for ACME challenges
3. Certbot is used to obtain certificates from Let's Encrypt
4. Certificates are installed and Nginx is configured to use them
5. A renewal script and cron job are set up for automatic renewals

### Audit Logging

The audit logging plugin (`bgd-audit-logging.sh`) provides comprehensive deployment event tracking:

- Records deployment events with timestamps
- Captures environment details
- Integrates with external monitoring systems
- Provides deployment notifications

#### Configuration

```bash
# Enable audit logging with Slack notifications
./scripts/bgd-deploy.sh v1.0 \
  --app-name=myapp \
  --slack-webhook="https://hooks.slack.com/services/XXX/YYY/ZZZ" \
  --audit-log-level="info"
```

### Creating Custom Plugins

You can create your own plugins to extend the functionality of the deployment system:

1. Create a shell script in the `plugins/` directory
2. Implement the necessary hooks
3. Register any custom arguments
4. Include the plugin in your CI/CD pipeline

Example custom plugin:

```bash
#!/bin/bash
# plugins/custom-notification.sh

# Register plugin arguments
register_plugin_argument "custom-notification" "NOTIFY_EMAIL" ""
register_plugin_argument "custom-notification" "NOTIFY_SMS" ""

# Implement hooks
hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ -n "${NOTIFY_EMAIL:-}" ]; then
    log_info "Sending deployment notification email to $NOTIFY_EMAIL"
    # Email sending logic here
  fi
  
  if [ -n "${NOTIFY_SMS:-}" ]; then
    log_info "Sending deployment notification SMS to $NOTIFY_SMS"
    # SMS sending logic here
  fi
  
  return 0
}

hook_post_rollback() {
  local rollback_env="$1"
  
  if [ -n "${NOTIFY_EMAIL:-}" ]; then
    log_info "Sending rollback notification email to $NOTIFY_EMAIL"
    # Email sending logic here
  fi
  
  return 0
}
```

## Multi-Container Support

The enhanced system now supports deploying multiple containers as part of a single blue/green deployment:

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
./scripts/bgd-deploy.sh v1.0 \
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
./scripts/bgd-deploy.sh v1.0 \
  --app-name=myapp \
  --domain-name="example.com" \
  --ssl-enabled=true
```

This will generate an Nginx configuration that routes traffic based on domains:
- `example.com` and `www.example.com` -> Main application
- `api.example.com` -> API service
- `team.example.com` -> Frontend application

## Advanced Configuration

### Configuration File Updates

Your CI/CD pipeline should always copy the latest configuration files to the server as part of the deployment process:

```yaml
# In your GitHub Actions workflow
- name: Copy configuration files to server
  uses: appleboy/scp-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    source: "docker-compose.yml,Dockerfile,nginx/*.conf"
    target: "/app/your-app-name"
```

This ensures that your server always has the latest configuration files when deploying new versions.

### Custom Nginx Configuration

For advanced Nginx configuration (SSL, custom routing, etc.), include template modifications in your CI/CD pipeline:

```yaml
# In your GitHub Actions workflow
- name: Deploy with custom Nginx configuration
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/myapp
      
      # Update Nginx template with custom configuration
      cat > config/templates/nginx-single-env.conf.template << 'EOL'
      # Custom Nginx configuration with specialized routing
      worker_processes auto;
      events {
          worker_connections 1024;
      }
      
      http {
          # Custom configuration here
      }
      EOL
      
      # Continue with deployment...
```

## Troubleshooting

### Common Issues in CI/CD Pipelines

| Issue | Solution |
|-------|----------|
| SSH connection failures | Check credentials and server firewall settings |
| Permission denied errors | Ensure your CI/CD user has appropriate permissions |
| Health check failing | Check application logs in the CI/CD output |
| Environment variables not being passed | Verify they're correctly defined in the CI/CD platform |
| Service name mismatches | Ensure the service name in templates matches your docker-compose.yml |
| Database migration failures | Check database credentials and migration script |
| SSL certificate generation fails | Verify domain DNS configuration and firewall settings |
| Shared services not starting | Check volume permissions and network configuration |

### Including Diagnostic Steps in Pipelines

Add these diagnostic steps to your CI/CD workflow when troubleshooting:

```yaml
# In your GitHub Actions workflow
- name: Diagnostic checks
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/myapp
      
      # Check which environment is active
      echo "Active environment:"
      grep -E "blue|green" nginx.conf || echo "No active environment"
      
      # Check container status
      echo "Container status:"
      docker ps -a | grep myapp
      
      # Check logs
      echo "Deployment logs:"
      ls -la logs/
      cat logs/myapp-*.log | tail -n 50
      
      # Check plugin status
      echo "Plugin status:"
      ls -la plugins/
      
      # Check service registry
      echo "Service registry:"
      cat service-registry.json || echo "No service registry"
      
      # Check SSL certificates
      echo "SSL certificates:"
      ls -la certs/
```

### Rollback Plans

Always include rollback steps in your pipeline for when deployments fail:

```yaml
# In your GitHub Actions workflow
- name: Deploy with rollback capability
  uses: appleboy/ssh-action@master
  if: success()
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/myapp
      
      # Attempt deployment
      if ! ./scripts/bgd-deploy.sh "$VERSION" --app-name=myapp --image-repo=$IMAGE_REPO; then
        echo "Deployment failed, rolling back..."
        ./scripts/bgd-rollback.sh --app-name=myapp --force
        exit 1
      fi
```

## Security Best Practices

### Docker Security

Run your application container as a non-root user:

```dockerfile
FROM node:18-alpine

WORKDIR /app

RUN apk add --no-cache curl

# Add a non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build && \
    # Set proper ownership
    chown -R appuser:appgroup /app

ENV NODE_ENV=production

# Switch to non-root user
USER appuser

HEALTHCHECK --interval=5s --timeout=3s --start-period=30s --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

EXPOSE 3000
CMD ["node", "dist/main"]
```

### CI/CD Security

Follow these security best practices in your CI/CD pipelines:

1. **Use secrets for sensitive data**: Store credentials, API keys, and other sensitive data as CI/CD secrets
2. **Limit SSH access**: Use dedicated deployment users with restricted permissions
3. **Use read-only tokens**: When pulling from Docker registries, use read-only tokens where possible
4. **Scan images**: Include container security scanning in your pipeline
5. **Validate deployments**: Always run health checks after deployment to verify success
6. **Secure plugin arguments**: Use CI/CD secrets for sensitive plugin arguments
7. **Rotate credentials**: Regularly rotate API keys, database passwords, and other credentials

## Namespace Management

The Blue/Green Deployment System uses proper namespacing to avoid conflicts with user code:

### File Organization

- **Core Files**: All toolkit core files are prefixed with `bgd-` (e.g., `bgd-core.sh`, `bgd-deploy.sh`)
- **Plugin Files**: All plugin files follow the same convention (e.g., `bgd-db-migrations.sh`)
- **No Wrapper Scripts**: There are no backward compatibility wrapper scripts

### Function Namespacing

- **All Functions**: All functions use the `bgd_` prefix (e.g., `bgd_log_info()`, `bgd_create_env_file()`)
- **Plugin Hooks**: All plugin hooks follow the same convention (e.g., `bgd_hook_pre_deploy()`)

### Variable Namespacing

- **User-Facing Variables**: Variables intended for users remain simple (e.g., `APP_NAME`, `VERSION`)
- **Internal Variables**: Variables used by the toolkit are prefixed with `BGD_` (e.g., `BGD_LOGS_DIR`)

### Directory Management

The toolkit manages these directories:
- `scripts/`: Contains core scripts
- `plugins/`: Contains plugin scripts
- `config/templates/`: Contains configuration templates
- `logs/`: Contains deployment logs
- `certs/`: Contains SSL certificates

### Using Toolkit Functions in Custom Scripts

If you need to use toolkit functions in your custom scripts, source the core file:

```bash
#!/bin/bash

# Source the core script
source "./scripts/bgd-core.sh"

# Use toolkit functions
bgd_log_info "Starting custom operation"
bgd_ensure_directory "./my-custom-dir"
bgd_check_health "http://localhost:8080/health" 3 5

# Run your custom logic
# ...

bgd_log_success "Custom operation completed"
```
