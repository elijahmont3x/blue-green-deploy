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
- [Handling Configuration File Updates](#handling-configuration-file-updates)
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
└── plugins/                      # Optional deployment plugins  
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

### Command-Line Parameters

The ideal approach is to pass configuration directly as parameters to the deployment scripts:

```yaml
# In GitHub Actions workflow
- name: Deploy
  uses: appleboy/ssh-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    script: |
      cd /app/your-app-name
      ./scripts/deploy.sh ${{ github.sha }} \
        --app-name=${{ vars.APP_NAME }} \
        --image-repo=${{ vars.IMAGE_REPO }} \
        --nginx-port=${{ vars.NGINX_PORT }} \
        --blue-port=${{ vars.BLUE_PORT }} \
        --green-port=${{ vars.GREEN_PORT }} \
        --database-url="${{ secrets.DATABASE_URL }}" \
        --api-key="${{ secrets.API_KEY }}"
```

Benefits of this approach:
- No need to create or maintain config files
- Explicit parameters make it clear what values are being passed
- Better traceability in logs and deployment history
- Easier to test different configurations

To implement this approach, update your deployment scripts to accept command-line parameters:

```bash
#!/bin/bash
# deploy.sh with parameter support

# Default values
APP_NAME="app"
NGINX_PORT=80
BLUE_PORT=8081
GREEN_PORT=8082

# Parse command-line arguments
VERSION=$1
shift

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --app-name=*) APP_NAME="${1#*=}" ;;
    --image-repo=*) IMAGE_REPO="${1#*=}" ;;
    --nginx-port=*) NGINX_PORT="${1#*=}" ;;
    --blue-port=*) BLUE_PORT="${1#*=}" ;;
    --green-port=*) GREEN_PORT="${1#*=}" ;;
    --database-url=*) DATABASE_URL="${1#*=}" ;;
    --api-key=*) API_KEY="${1#*=}" ;;
    *) echo "Unknown parameter: $1"; exit 1 ;;
  esac
  shift
done

# Use the parameters directly in your deployment logic
echo "Deploying version $VERSION with configuration:"
echo "  App Name: $APP_NAME"
echo "  Nginx Port: $NGINX_PORT"
# ...rest of the deployment script...
```

This approach also makes it easier to run deployments locally with different configurations:

```bash
./scripts/deploy.sh v1.0 --app-name=test-app --nginx-port=8080 --database-url=postgres://localhost/testdb
```

### Configuration Values to Consider

Whether using command-line parameters or any other approach, these are the key configuration values to manage:

**Infrastructure Settings**:
- `APP_NAME`: Your application name (used as prefix for containers)
- `IMAGE_REPO`: Docker image repository without tag
- `NGINX_PORT`: External port for Nginx load balancer
- `BLUE_PORT`: Internal port for blue environment
- `GREEN_PORT`: Internal port for green environment
- `HEALTH_ENDPOINT`: Health check URL path

**Sensitive Data**:
- `DATABASE_URL`: Database connection string
- `API_KEY`: API keys for your application
- `REDIS_URL`: Redis connection string
- Other application-specific secrets

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

# Run the deployment script with your version and configuration
./scripts/deploy.sh v1.0 --app-name=your-app-name --image-repo=username/your-app

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
./scripts/deploy.sh v1.1 --app-name=your-app-name --image-repo=username/your-app
```

### 4. If You Need to Rollback

```bash
# SSH into your server
ssh user@your-server-ip
cd /app/your-app-name

# Rollback to the previous version
./scripts/rollback.sh --app-name=your-app-name
```

## Command Reference

The deployment toolkit provides these commands (all run on your server):

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
      
      # Copy configuration files to server
      - name: Copy configuration files to server
        uses: appleboy/scp-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          source: "docker-compose.yml,Dockerfile"
          target: "/app/your-app-name"
      
      # Deploy with parameters
      - name: Deploy
        uses: appleboy/ssh-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd /app/your-app-name
            ./scripts/deploy.sh ${{ github.sha }} \
              --app-name=${{ vars.APP_NAME }} \
              --image-repo=${{ vars.IMAGE_REPO }} \
              --nginx-port=${{ vars.NGINX_PORT }} \
              --blue-port=${{ vars.BLUE_PORT }} \
              --green-port=${{ vars.GREEN_PORT }} \
              --database-url="${{ secrets.DATABASE_URL }}" \
              --api-key="${{ secrets.API_KEY }}" \
              --redis-url="${{ secrets.REDIS_URL }}"
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
- `NGINX_PORT`: Port for Nginx (default: 80)
- `BLUE_PORT`: Port for blue environment (default: 8081)
- `GREEN_PORT`: Port for green environment (default: 8082)
- `HEALTH_ENDPOINT`: Health check endpoint (default: /health)

## Handling Configuration File Updates

An important consideration is how `docker-compose.yml` and `Dockerfile` get updated on your server when you make changes to them in your repository.

### Approaches for Updating Configuration Files

1. **Automatic with Every Deployment** (Recommended)
   - Copy files to the server with each deployment
   - Ensures your server always has the latest configuration
   - Simple and reliable approach

2. **Conditional Updates**
   - Only copy files when they've changed in your repository
   - Slightly more efficient but adds complexity
   - Requires additional GitHub Actions steps

3. **Manual Updates**
   - Update files manually when needed
   - Not recommended for most teams
   - Prone to forgetting updates

### Example: Automatic File Updates with GitHub Actions

```yaml
# In your GitHub Actions workflow
- name: Copy configuration files to server
  uses: appleboy/scp-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    source: "docker-compose.yml,Dockerfile"
    target: "/app/your-app-name"
```

### Example: Conditional File Updates

```yaml
# In your GitHub Actions workflow
- name: Check if docker-compose.yml or Dockerfile changed
  id: changed-files
  uses: tj-actions/changed-files@v35
  with:
    files: |
      docker-compose.yml
      Dockerfile
      
- name: Copy configuration files to server if changed
  if: steps.changed-files.outputs.any_changed == 'true'
  uses: appleboy/scp-action@master
  with:
    host: ${{ secrets.SERVER_HOST }}
    username: ${{ secrets.SERVER_USER }}
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    source: "docker-compose.yml,Dockerfile"
    target: "/app/your-app-name"
```

### Additional Files to Consider

Depending on your application, you might need to copy other configuration files:

- Environment-specific configurations
- Nginx configuration templates
- Docker Compose override files
- SSL certificates

The important principle is ensuring your server-side deployment system has all the configuration files it needs to run your application properly.

## Supporting Multiple Applications

You can install this deployment system for multiple applications on the same server:

```bash
# First application
mkdir -p /app/app1
cd /app/app1
curl -L https://github.com/yourusername/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1
./install.sh app1 .

# Second application
mkdir -p /app/app2
cd /app/app2
curl -L https://github.com/yourusername/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1
./install.sh app2 .
```

Configure unique ports for each application using command-line parameters:

```bash
# For app1
./scripts/deploy.sh v1.0 \
  --app-name=app1 \
  --nginx-port=80 \
  --blue-port=8081 \
  --green-port=8082

# For app2
./scripts/deploy.sh v1.0 \
  --app-name=app2 \
  --nginx-port=81 \
  --blue-port=8083 \
  --green-port=8084
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

```bash
./scripts/deploy.sh v1.0 \
  --app-name=your-app-name \
  --redis-url="redis://redis:6379/0"
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

```bash
./scripts/deploy.sh v1.0 \
  --app-name=your-app-name \
  --database-url="postgresql://dbuser:dbpassword@postgres:5432/appdb"
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
| Environment variables not passing | Verify parameter values in deployment command |
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
./scripts/cleanup.sh --app-name=your-app-name --all

# Or manually:
docker-compose -p your-app-blue down
docker-compose -p your-app-green down

# Remove generated files
rm -f nginx.conf .env.blue .env.green docker-compose.blue.yml docker-compose.green.yml

# Start from scratch
./scripts/deploy.sh your-version --app-name=your-app-name
```