# Blue/Green Deployment System

A utility for implementing zero-downtime deployments using the blue/green deployment strategy. This tool helps application developers maintain two identical environments, gradually shift traffic between them, and achieve seamless updates with no downtime.

## What Is This?

This is **not** an application, but a collection of deployment scripts and configuration templates that you add to your existing applications to enable blue/green deployments. Think of it as a deployment toolkit that integrates with your existing Docker-based applications.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Adding to Your Application](#adding-to-your-application)
- [Deployment Workflow](#deployment-workflow)
- [Command Reference](#command-reference)
- [Configuration Reference](#configuration-reference)
- [CI/CD Integration](#cicd-integration)
- [Supporting Multiple Applications](#supporting-multiple-applications)
- [Integrating Backend Services](#integrating-backend-services)
- [Advanced Usage](#advanced-usage)
- [Troubleshooting](#troubleshooting)

## Overview

Blue/green deployment is a release technique that reduces downtime and risk by running two identical production environments called "Blue" and "Green":

- **Blue Environment**: Currently in production serving live traffic
- **Green Environment**: New version being deployed and tested

This tool adds blue/green deployment capabilities to your existing Docker applications by:

1. Creating two separate but identical environments
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

This system sits alongside your application and works with your existing `docker-compose.yml` and `Dockerfile`:

1. It creates environment-specific versions of your Docker Compose setup
2. It configures Nginx as a load balancer in front of your application
3. It manages which environment receives traffic and at what percentage
4. It orchestrates the deployment, testing, and cutover process

Here's how the system modifies your infrastructure:

```
Before:                         After:
┌─────────────┐                 ┌─────────────┐
│   Docker    │                 │    Nginx    │
│ Application │                 │ Load Balancer│
└─────────────┘                 └───────┬─────┘
                                       / \
                                      /   \
                             ┌───────┘     └───────┐
                             │                     │
                         ┌───────────┐       ┌───────────┐
                         │   Blue    │       │   Green   │
                         │Environment│       │Environment│
                         └───────────┘       └───────────┘
```

## Adding to Your Application

### Prerequisites

To use this tool, your application must:
- Use Docker and Docker Compose
- Have a health check endpoint
- Be stateless or use external databases (or handle data synchronization)

### Installation

Add this deployment system to your existing application:

```bash
# Go to your application directory 
cd /path/to/your-app

# Download the deployment toolkit
curl -L https://github.com/yourusername/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1 -C ./deployment

# Install the deployment scripts
cd deployment
./install.sh your-app-name ..
```

This adds the deployment scripts and configuration alongside your existing application.

### Project Structure Before & After

Before:
```
your-app/
├── src/                  # Your application code
├── docker-compose.yml    # Your Docker Compose file
├── Dockerfile            # Your Dockerfile
└── ...
```

After:
```
your-app/
├── src/                  # Your application code
├── docker-compose.yml    # Your Docker Compose file
├── Dockerfile            # Your Dockerfile
├── scripts/              # Added deployment scripts
│   ├── deploy.sh
│   ├── cutover.sh
│   ├── rollback.sh
│   └── ...
├── config/               # Added configuration templates
│   └── templates/
├── plugins/              # Optional deployment plugins  
└── config.env            # Deployment configuration
```

### Configuration

Configure your deployment by editing `config.env`:

```properties
# Application Settings
APP_NAME=your-app-name
IMAGE_REPO=username/your-app
NGINX_PORT=80             # Port for public access
BLUE_PORT=8081            # Internal port for blue environment
GREEN_PORT=8082           # Internal port for green environment
HEALTH_ENDPOINT=/health   # Your application's health check URL

# Add any application-specific environment variables
DATABASE_URL=postgresql://user:password@postgres:5432/yourapp
REDIS_URL=redis://redis:6379/0
API_KEY=your_api_key_here
```

## Deployment Workflow

Once the deployment system is added to your application, follow this workflow:

### 1. Build & Push Your Application Image

```bash
# Build your application Docker image 
docker build -t username/your-app:v1.0 .

# Push to a registry
docker push username/your-app:v1.0
```

### 2. Deploy the New Version

```bash
# Run the deployment script with your version
./scripts/deploy.sh v1.0

# This will:
# - Set up the initial environment if none exists
# - Deploy to the inactive environment (blue or green)
# - Run health checks to verify the new version
# - Gradually shift traffic to the new version
```

### 3. When Updating to a New Version

```bash
# Build and push the new version
docker build -t username/your-app:v1.1 .
docker push username/your-app:v1.1

# Deploy the new version
./scripts/deploy.sh v1.1
```

### 4. If You Need to Rollback

```bash
# Rollback to the previous version
./scripts/rollback.sh
```

## Command Reference

The deployment toolkit provides these commands:

### Deploy

```bash
./scripts/deploy.sh VERSION [OPTIONS]

# Options:
#   --force     Force deployment even if target environment is active
#   --no-shift  Don't shift traffic automatically (manual cutover)
#   --config=X  Use alternate config file (default: config.env)

# Examples:
./scripts/deploy.sh v1.0              # Deploy version v1.0
./scripts/deploy.sh v1.1 --no-shift   # Deploy without auto traffic shifting
```

### Cutover

```bash
./scripts/cutover.sh [blue|green] [OPTIONS]

# Options:
#   --keep-old  Don't stop the previous environment
#   --config=X  Use alternate config file (default: config.env)

# Example:
./scripts/cutover.sh green            # Shift all traffic to green environment
```

### Rollback

```bash
./scripts/rollback.sh [OPTIONS]

# Options:
#   --force     Force rollback even if previous environment is unhealthy
#   --config=X  Use alternate config file (default: config.env)

# Example:
./scripts/rollback.sh                 # Roll back to previous environment
```

### Cleanup

```bash
./scripts/cleanup.sh [OPTIONS]

# Options:
#   --all          Clean up everything including current active environment
#   --failed-only  Clean up only failed deployments
#   --old-only     Clean up only old, inactive environments
#   --dry-run      Only show what would be cleaned without actually removing anything
#   --config=X     Use alternate config file (default: config.env)

# Example:
./scripts/cleanup.sh --failed-only    # Clean up only failed deployments
```

## Configuration Reference

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| APP_NAME | Application name used as prefix for containers | (required) |
| IMAGE_REPO | Docker image repository without tag | (required) |
| NGINX_PORT | External port for Nginx load balancer | 80 |
| BLUE_PORT | Internal port for blue environment | 8081 |
| GREEN_PORT | Internal port for green environment | 8082 |
| HEALTH_ENDPOINT | Health check URL path | /health |
| HEALTH_RETRIES | Number of health check attempts | 12 |
| HEALTH_DELAY | Seconds between health checks | 5 |

### Templates

The system includes these configuration templates:

- `config/templates/nginx-single-env.conf.template`: Nginx config for single environment
- `config/templates/nginx-dual-env.conf.template`: Nginx config for traffic splitting
- `config/templates/docker-compose.override.template`: Environment-specific overrides

## CI/CD Integration

### GitHub Actions Example

```yaml
# .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ secrets.DOCKER_USERNAME }}
          password: ${{ secrets.DOCKER_PASSWORD }}
      
      - name: Build and push Docker image
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: username/your-app:${{ github.sha }}
      
      - name: Deploy
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd /path/to/your-app
            export DATABASE_URL="${{ secrets.DATABASE_URL }}"
            export API_KEY="${{ secrets.API_KEY }}"
            ./scripts/deploy.sh ${{ github.sha }}
```

## Supporting Multiple Applications

This deployment system can be used with multiple independent applications. Install it separately for each application:

```bash
# First application
cd /path/to/app1
curl -L https://github.com/yourusername/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1 -C ./deployment
cd deployment
./install.sh app1 ..

# Second application
cd /path/to/app2
curl -L https://github.com/yourusername/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1 -C ./deployment
cd deployment
./install.sh app2 ..
```

Configure unique ports for each application:

```properties
# app1/config.env
APP_NAME=app1
NGINX_PORT=80
BLUE_PORT=8081
GREEN_PORT=8082

# app2/config.env
APP_NAME=app2
NGINX_PORT=81
BLUE_PORT=8083
GREEN_PORT=8084
```

## Integrating Backend Services

### Redis Integration

1. Add Redis to your `docker-compose.yml`:

```yaml
services:
  # Your existing services...
  
  redis:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redis-data:/data
    networks:
      - app-network

volumes:
  redis-data:
```

2. Add connection details to `config.env`:

```properties
REDIS_URL=redis://redis:6379/0
```

### PostgreSQL Integration

1. Add PostgreSQL to your `docker-compose.yml`:

```yaml
services:
  # Your existing services...
  
  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=${DB_USER:-dbuser}
      - POSTGRES_PASSWORD=${DB_PASSWORD:-dbpassword}
      - POSTGRES_DB=${DB_NAME:-appdb}
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      - app-network

volumes:
  postgres-data:
```

2. Add connection details to `config.env`:

```properties
DB_USER=dbuser
DB_PASSWORD=secure_password
DB_NAME=appdb
DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}
```

3. For database migrations, create a plugin:

```bash
# Create plugins/db-migrate.sh
mkdir -p plugins
cat > plugins/db-migrate.sh << 'EOL'
#!/bin/bash

hook_pre_deploy() {
  local version="$1"
  
  log_info "Running database migrations for version $version"
  
  docker run --rm \
    --network=${APP_NAME}_app-network \
    -e DATABASE_URL="${DATABASE_URL}" \
    ${IMAGE_REPO}:${version} \
    npm run migrate
    
  return $?
}
EOL

chmod +x plugins/db-migrate.sh
```

## Advanced Usage

### Plugin System

Create custom plugins to extend the deployment process:

```bash
# Create a plugin file
mkdir -p plugins
cat > plugins/notifications.sh << 'EOL'
#!/bin/bash

hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Send notification
  curl -X POST \
    -H "Content-Type: application/json" \
    -d "{\"text\":\"Deployed version $version to $env_name\"}" \
    "https://hooks.slack.com/services/your/webhook/url"
  
  return 0
}
EOL

chmod +x plugins/notifications.sh
```

Available hooks:
- `hook_pre_deploy`: Before deployment starts
- `hook_post_deploy`: After deployment completes
- `hook_pre_cutover`: Before traffic cutover
- `hook_post_cutover`: After traffic cutover
- `hook_pre_rollback`: Before rollback
- `hook_post_rollback`: After rollback

### Customizing Nginx Configuration

Edit the Nginx templates in `config/templates/` to add custom routing, SSL configuration, or other requirements:

```nginx
# Example modification for SSL
server {
    listen 80;
    server_name your-domain.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name your-domain.com;
    
    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    
    # Rest of your configuration...
}
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| Health check failing | Check logs with `docker-compose -p your-app-blue logs` |
| Nginx not routing | Check generated config with `cat nginx.conf` |
| Environment variables not passing | Verify they're in config.env or explicitly exported |
| Database connection failing | Check network settings and credentials |

### Diagnosing Problems

```bash
# Check which environment is active
grep -E "blue|green" nginx.conf

# View deployment logs
cat .deployment_logs/*.log

# Check environment files
cat .env.blue
cat .env.green

# View container logs
docker-compose -p your-app-blue logs --tail=100
```

### Manual Recovery

If things go wrong, you can manually reset:

```bash
# Stop all environments
./scripts/cleanup.sh --all

# Or manually:
docker-compose -p your-app-blue down
docker-compose -p your-app-green down

# Remove generated files
rm -f nginx.conf .env.blue .env.green docker-compose.blue.yml docker-compose.green.yml

# Start from scratch
./scripts/deploy.sh your-version
```