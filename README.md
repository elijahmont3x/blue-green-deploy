# Blue/Green Deployment System

A utility for implementing zero-downtime deployments using the blue/green deployment strategy. This toolkit enables continuous integration and deployment pipelines to maintain two identical environments, gradually shift traffic between them, and achieve seamless updates with no downtime.

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
- [Advanced Configuration](#advanced-configuration)
- [Troubleshooting](#troubleshooting)
- [Security Best Practices](#security-best-practices)

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
    C -->|Pass| D["`**Traffic Shift**<br>10% to New Environment`"]
    C -->|Fail| E["`**Abort**<br>Deployment Failed`"]
    D --> F["`**Traffic Shift**<br>50% to New Environment`"]
    F --> G["`**Traffic Shift**<br>90% to New Environment`"]
    G --> H{"`**Verification**<br>All Systems Go?`"}
    H -->|Yes| I["`**Cutover**<br>100% Traffic to New`"]
    H -->|No| J["`**Rollback**<br>Revert to Original`"]
    I --> K["`**Cleanup**<br>Stop Old Environment`"]
    J --> L["`**Revert**<br>Shift Traffic Back`"]
    
    %% Apply classes
    class A,B process
    class C,H decision
    class D,F,G primary
    class E,J secondary
    class I,K success
    class L warning
```

## Prerequisites

To use this toolkit, you need:
- A Linux server (like Vultr VPS)
- Docker and Docker Compose installed on your server
- CI/CD platform with SSH access to your server (GitHub Actions, GitLab CI, etc.)
- Server location for your deployments (e.g., `/app/your-project`)

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
          curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/refs/tags/v1.0.0.tar.gz -o deployment/toolkit.tar.gz
      
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
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          envs: VERSION,IMAGE_REPO,APP_API_ENDPOINT,APP_CONFIG_VALUE,APP_SECRET_KEY,APP_CORS_ORIGINS
          script: |
            cd /app/myapp
            
            # Extract toolkit if not already installed
            if [ ! -f "./scripts/deploy.sh" ]; then
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
            
            # Clean up failed deployments
            ./scripts/cleanup.sh --app-name=myapp --failed-only
            
            # Run the deployment
            ./scripts/deploy.sh "$VERSION" \
              --app-name=myapp \
              --image-repo=$IMAGE_REPO \
              --nginx-port=80 \
              --blue-port=8081 \
              --green-port=8082 \
              --health-endpoint=/health
  
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
            ./scripts/cleanup.sh --app-name=myapp --old-only
```

### Configuring Your Deployment

The blue/green deployment system uses command-line parameters for configuration:

```yaml
./scripts/deploy.sh "$VERSION" \
  --app-name=myapp \
  --image-repo=ghcr.io/myusername/myproject \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082 \
  --health-endpoint=/health \
  --database-url="postgresql://user:pass@host/db" \
  --api-key="your-api-key"
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
4. **CI/CD variables**: Variables passed via the `env:` section in your CI/CD workflow propagate properly

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
      if [ ! -f "./scripts/deploy.sh" ]; then
        mkdir -p toolkit && cd toolkit
        curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/refs/tags/v1.0.0.tar.gz | tar xz --strip-components=1
        chmod +x ./install.sh
        ./install.sh backend
        cd ..
      fi
      
      # Deploy backend
      ./scripts/deploy.sh "$VERSION" \
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

Here's a generic docker-compose.yml example that works with the default configuration:

```yaml
version: '3.8'
name: ${APP_NAME:-myapp}

networks:
  app-network:
    driver: bridge

services:
  app:  # This is the main service name the system expects by default
    image: ${IMAGE_REPO:-yourusername/myapp}:${VERSION:-latest}
    restart: unless-stopped
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - ENV_NAME=${ENV_NAME:-default}
    ports:
      - '${PORT:-3000}:3000'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:3000/health']
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - app-network

  nginx:
    image: nginx:stable-alpine
    restart: unless-stopped
    ports:
      - '${NGINX_PORT:-80}:80'
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - app
    networks:
      - app-network
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
      if [ ! -f "./scripts/deploy.sh" ]; then
        tar -xzf toolkit.tar.gz
        chmod +x ./install.sh
        ./install.sh myapp
        
        # Update Nginx templates to use different service name
        sed -i 's/app-1:3000/web-1:3000/g' config/templates/nginx-single-env.conf.template
        sed -i 's/app-1:3000/web-1:3000/g' config/templates/nginx-dual-env.conf.template
        
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
./scripts/deploy.sh VERSION [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --image-repo=REPO     Docker image repository
#   --nginx-port=PORT     Nginx external port
#   --blue-port=PORT      Blue environment port
#   --green-port=PORT     Green environment port
#   --database-url=URL    Database connection string
#   --api-key=KEY         API key
#   --force               Force deployment even if target environment is active
#   --no-shift            Don't shift traffic automatically (manual cutover)

# Examples:
./scripts/deploy.sh v1.0 --app-name=myapp --image-repo=myname/myapp
./scripts/deploy.sh v1.1 --app-name=myapp --no-shift
```

### Cutover

```bash
./scripts/cutover.sh [blue|green] [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --keep-old            Don't stop the previous environment

# Example:
./scripts/cutover.sh green --app-name=myapp
```

### Rollback

```bash
./scripts/rollback.sh [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --force               Force rollback even if previous environment is unhealthy

# Example:
./scripts/rollback.sh --app-name=myapp
```

### Cleanup

```bash
./scripts/cleanup.sh [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --all                 Clean up everything including current active environment
#   --failed-only         Clean up only failed deployments
#   --old-only            Clean up only old, inactive environments
#   --dry-run             Only show what would be cleaned without actually removing anything

# Example:
./scripts/cleanup.sh --app-name=myapp --failed-only
```

## Plugin System

The plugin system allows you to extend the deployment process with custom hooks. Plugins are shell scripts that your CI/CD pipeline can place in the `plugins/` directory of your deployment environment.

### Available Hooks

- `hook_pre_deploy`: Runs before deployment starts
- `hook_post_deploy`: Runs after deployment completes
- `hook_pre_cutover`: Runs before traffic cutover
- `hook_post_cutover`: Runs after traffic cutover
- `hook_pre_rollback`: Runs before rollback
- `hook_post_rollback`: Runs after rollback

### Implementing Plugins Through CI/CD

You can include plugin functionality directly in your CI/CD pipeline:

```yaml
# In your GitHub Actions workflow
- name: Deploy with Slack notifications
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/myapp
      
      # Create Slack notifications plugin
      mkdir -p plugins
      cat > plugins/slack-notifications.sh << 'EOL'
      #!/bin/bash
      
      hook_post_deploy() {
        local version="$1"
        local env_name="$2"
        
        curl -s -X POST \
          -H "Content-Type: application/json" \
          -d "{\"text\":\"🚀 *Deployment Successful*\n• Application: ${APP_NAME}\n• Version: ${version}\n• Environment: ${env_name}\"}" \
          "${SLACK_WEBHOOK}"
          
        return $?
      }
      EOL
      
      chmod +x plugins/slack-notifications.sh
      
      # Run deployment with Slack webhook
      ./scripts/deploy.sh "$VERSION" \
        --app-name=myapp \
        --image-repo=$IMAGE_REPO \
        --slack-webhook="${{ secrets.SLACK_WEBHOOK }}"
```

### Plugin Examples

#### Slack Notifications

```bash
#!/bin/bash
# plugins/slack-notifications.sh

hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ -z "${SLACK_WEBHOOK:-}" ]; then
    log_info "Skipping Slack notification (SLACK_WEBHOOK not set)"
    return 0
  fi
  
  log_info "Sending deployment notification to Slack"
  
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"🚀 *Deployment Successful*\n• Application: ${APP_NAME}\n• Version: ${version}\n• Environment: ${env_name}\"}" \
    "${SLACK_WEBHOOK}"
    
  return $?
}

hook_post_rollback() {
  local rollback_env="$1"
  
  if [ -z "${SLACK_WEBHOOK:-}" ]; then
    return 0
  fi
  
  log_info "Sending rollback notification to Slack"
  
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"⚠️ *Rollback Performed*\n• Application: ${APP_NAME}\n• Environment: ${rollback_env}\"}" \
    "${SLACK_WEBHOOK}"
    
  return $?
}
```

#### Database Backup

```bash
#!/bin/bash
# plugins/db-backup.sh

hook_pre_deploy() {
  local version="$1"
  
  if [ -z "${DATABASE_URL:-}" ]; then
    log_info "Skipping database backup (DATABASE_URL not set)"
    return 0
  fi
  
  # Extract DB info from connection string
  local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
  
  if [ -z "$db_name" ]; then
    log_warning "Could not extract database name from DATABASE_URL"
    return 0
  fi
  
  log_info "Creating database backup before deployment"
  
  # Create backup directory
  ensure_directory "backups"
  
  # Generate backup filename with timestamp
  local backup_file="backups/${APP_NAME}-${db_name}-$(date +%Y%m%d-%H%M%S).sql"
  
  # Run backup
  docker-compose exec -T postgres pg_dump -U "${DB_USER:-postgres}" "${db_name}" > "${backup_file}"
  
  if [ $? -eq 0 ]; then
    log_success "Database backup created: ${backup_file}"
  else
    log_warning "Database backup failed"
  fi
  
  return 0
}
```

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
- name: Deploy with SSL configuration
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/myapp
      
      # Update Nginx template with SSL configuration
      cat > config/templates/nginx-single-env.conf.template << 'EOL'
      worker_processes auto;
      events {
          worker_connections 1024;
      }
      
      http {
          include       /etc/nginx/mime.types;
          default_type  application/octet-stream;
          
          sendfile        on;
          keepalive_timeout  65;
          
          upstream backend {
              server APP_NAME-ENVIRONMENT-app-1:3000;
          }
      
          # Redirect HTTP to HTTPS
          server {
              listen NGINX_PORT;
              server_name myapp.example.com;
              return 301 https://$host$request_uri;
          }
          
          # HTTPS configuration
          server {
              listen 443 ssl;
              server_name myapp.example.com;
              
              ssl_certificate /etc/nginx/certs/fullchain.pem;
              ssl_certificate_key /etc/nginx/certs/privkey.pem;
              ssl_protocols TLSv1.2 TLSv1.3;
              
              location / {
                  proxy_pass http://backend;
                  proxy_set_header Host $host;
                  proxy_set_header X-Real-IP $remote_addr;
              }
          }
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
      if ! ./scripts/deploy.sh "$VERSION" --app-name=myapp --image-repo=$IMAGE_REPO; then
        echo "Deployment failed, rolling back..."
        ./scripts/rollback.sh --app-name=myapp --force
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