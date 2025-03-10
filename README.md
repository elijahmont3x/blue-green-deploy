# Blue/Green Deployment System

A utility for implementing zero-downtime deployments using the blue/green deployment strategy. This tool helps application developers maintain two identical environments, gradually shift traffic between them, and achieve seamless updates with no downtime.

## What Is This?

This is **not** an application, but a collection of deployment scripts and configuration templates that you install **directly on your production server** to enable blue/green deployments. Think of it as a server-side deployment toolkit that works with your existing Docker-based applications.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Server Installation](#server-installation)
- [Deployment Workflow](#deployment-workflow)
- [Configuration Approach](#configuration-approach)
- [Command Reference](#command-reference)
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

This system is installed on your production server and works with your existing `docker-compose.yml` and `Dockerfile`:

1. It creates environment-specific versions of your Docker Compose setup
2. It configures Nginx as a load balancer in front of your application
3. It manages which environment receives traffic and at what percentage
4. It orchestrates the deployment, testing, and cutover process

Here's how the system modifies your server infrastructure:

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

## Server Installation

### Prerequisites

To use this tool, you need:
- A Linux server (like Vultr VPS)
- Docker and Docker Compose installed
- SSH access to your server
- An application with a health check endpoint

### Installation Process

This toolkit is installed **directly on your server**, not in your application repository:

```bash
# SSH into your server
ssh user@your-server-ip

# Create directory for your application deployment
mkdir -p /app/your-app-name
cd /app/your-app-name

# Download the deployment toolkit
curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1

# Install the deployment scripts
./install.sh your-app-name .
```

### Server Directory Structure

The toolkit creates this structure **on your server**:

```
/app/your-app-name/              # Root directory on server
├── docker-compose.yml           # Your application's compose file (uploaded to server)
├── Dockerfile                    # Your application's Dockerfile (uploaded to server)
├── scripts/                      # Added deployment scripts
│   ├── deploy.sh
│   ├── cutover.sh
│   ├── rollback.sh
│   └── ...
├── config/                       # Added configuration templates
│   └── templates/
├── plugins/                      # Optional deployment plugins  
└── config.env                    # Deployment configuration (created on server)
```

**Important**: These files exist only on your server. They are NOT part of your application's Git repository.

### Getting Your Application Files to the Server

You need to get your `docker-compose.yml` and `Dockerfile` to your server:

```bash
# From your local development machine
scp docker-compose.yml user@your-server-ip:/app/your-app-name/
scp Dockerfile user@your-server-ip:/app/your-app-name/
```

Alternatively, your CI/CD pipeline can copy these files during deployment.

## Configuration Approach

### Server-Side Configuration (config.env)

The `config.env` file is created on your server and contains deployment configuration:

```properties
# Application Settings - Non-sensitive values
APP_NAME=your-app-name
IMAGE_REPO=username/your-app
NGINX_PORT=80             # Port for public access
BLUE_PORT=8081            # Internal port for blue environment
GREEN_PORT=8082           # Internal port for green environment
HEALTH_ENDPOINT=/health   # Your application's health check URL
```

### Handling Sensitive Configuration

For sensitive data (passwords, API keys, etc.), use one of these approaches:

1. **CI/CD Secrets** (Recommended): Store sensitive info in GitHub Secrets or similar, and pass them to the server during deployment
   ```yaml
   # GitHub Actions example
   - name: Deploy
     uses: appleboy/ssh-action@master
     with:
       # ...
       script: |
         cd /app/your-app-name
         export DATABASE_URL="${{ secrets.DATABASE_URL }}"
         export API_KEY="${{ secrets.API_KEY }}"
         ./scripts/deploy.sh ${{ github.sha }}
   ```

2. **Server Environment Variables**: Set them on your server before deployment
   ```bash
   # On your server
   export DATABASE_URL="postgresql://user:password@host:5432/db"
   ./scripts/deploy.sh v1.0
   ```

3. **For Testing/Development Only**: Add to config.env on the server (not recommended for production)
   ```properties
   # config.env - ONLY FOR NON-SENSITIVE DATA
   DATABASE_URL=postgresql://user:password@localhost:5432/db
   ```

The deployment scripts will capture and use these environment variables during deployment.

## Deployment Workflow

Once the system is installed on your server, follow this workflow:

### 1. Build & Push Your Application Image

```bash
# From your local development machine or CI/CD
docker build -t username/your-app:v1.0 .
docker push username/your-app:v1.0
```

### 2. Deploy the New Version

```bash
# SSH into your server
ssh user@your-server-ip
cd /app/your-app-name

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
# Build and push the new version (from local or CI/CD)
docker build -t username/your-app:v1.1 .
docker push username/your-app:v1.1

# SSH into your server and deploy
ssh user@your-server-ip
cd /app/your-app-name
./scripts/deploy.sh v1.1
```

### 4. If You Need to Rollback

```bash
# SSH into your server
ssh user@your-server-ip
cd /app/your-app-name

# Rollback to the previous version
./scripts/rollback.sh
```

## Command Reference

The deployment toolkit provides these commands (all run on your server):

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

## CI/CD Integration

### GitHub Actions Example

Add this workflow file to your application repository:

```yaml
# .github/workflows/deploy.yml (in your application repository)
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
            cd /app/your-app-name
            # Pass secrets from GitHub to the server
            export DATABASE_URL="${{ secrets.DATABASE_URL }}"
            export API_KEY="${{ secrets.API_KEY }}"
            export REDIS_URL="${{ secrets.REDIS_URL }}"
            # Run deployment with the image version
            ./scripts/deploy.sh ${{ github.sha }}
```

### Required GitHub Secrets/Variables

Add these to your GitHub repository (Settings → Secrets and variables → Actions):

**Secrets** (for sensitive information):
- `SERVER_HOST`: Your server's IP address
- `SERVER_USER`: SSH username
- `SSH_PRIVATE_KEY`: Private SSH key for authentication
- `DOCKER_USERNAME`: Docker Hub username
- `DOCKER_PASSWORD`: Docker Hub password/token
- `DATABASE_URL`: Database connection string
- `API_KEY`: API key for your application
- `REDIS_URL`: Redis connection string

**Variables** (for non-sensitive configuration):
- `APP_NAME`: Your application name
- `IMAGE_REPO`: Docker image repository

## Supporting Multiple Applications

You can install this deployment system for multiple applications on the same server:

```bash
# First application
mkdir -p /app/app1
cd /app/app1
curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1
./install.sh app1 .

# Second application
mkdir -p /app/app2
cd /app/app2
curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1
./install.sh app2 .
```

Configure unique ports for each application in their respective config.env files:

```properties
# /app/app1/config.env
APP_NAME=app1
NGINX_PORT=80
BLUE_PORT=8081
GREEN_PORT=8082

# /app/app2/config.env
APP_NAME=app2
NGINX_PORT=81
BLUE_PORT=8083
GREEN_PORT=8084
```

## Integrating Backend Services

### Redis Integration

1. Add Redis to your application's `docker-compose.yml`:

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

2. Pass Redis connection info during deployment:

```yaml
# In GitHub Actions
- name: Deploy
  uses: appleboy/ssh-action@master
  with:
    # ...
    script: |
      cd /app/your-app-name
      export REDIS_URL="${{ secrets.REDIS_URL }}"
      ./scripts/deploy.sh ${{ github.sha }}
```

### PostgreSQL Integration

1. Add PostgreSQL to your application's `docker-compose.yml`:

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

2. Pass database connection info during deployment:

```yaml
# In GitHub Actions
- name: Deploy
  uses: appleboy/ssh-action@master
  with:
    # ...
    script: |
      cd /app/your-app-name
      export DB_USER="${{ secrets.DB_USER }}"
      export DB_PASSWORD="${{ secrets.DB_PASSWORD }}"
      export DB_NAME="${{ secrets.DB_NAME }}"
      export DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}"
      ./scripts/deploy.sh ${{ github.sha }}
```

3. For database migrations, create a plugin on your server:

```bash
# On your server
mkdir -p /app/your-app-name/plugins
cat > /app/your-app-name/plugins/db-migrate.sh << 'EOL'
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

chmod +x /app/your-app-name/plugins/db-migrate.sh
```

## Advanced Usage

### Plugin System

Create custom plugins on your server to extend the deployment process:

```bash
# On your server
mkdir -p /app/your-app-name/plugins
cat > /app/your-app-name/plugins/notifications.sh << 'EOL'
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

chmod +x /app/your-app-name/plugins/notifications.sh
```

Available hooks:
- `hook_pre_deploy`: Before deployment starts
- `hook_post_deploy`: After deployment completes
- `hook_pre_cutover`: Before traffic cutover
- `hook_post_cutover`: After traffic cutover
- `hook_pre_rollback`: Before rollback
- `hook_post_rollback`: After rollback

### Customizing Nginx Configuration

Edit the Nginx templates on your server to add custom routing, SSL configuration, or other requirements:

```bash
# On your server
nano /app/your-app-name/config/templates/nginx-single-env.conf.template
```

Example SSL configuration:

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
| Environment variables not passing | Verify they're exported before running deploy.sh |
| Database connection failing | Check network settings and credentials |

### Diagnosing Problems

```bash
# On your server
cd /app/your-app-name

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
# On your server
cd /app/your-app-name

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