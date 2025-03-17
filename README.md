# Blue/Green Deployment System

A utility for implementing zero-downtime deployments using the blue/green deployment strategy. This tool helps application developers maintain two identical environments, gradually shift traffic between them, and achieve seamless updates with no downtime.

## What Is This?

This is **not** an application, but a collection of deployment scripts and configuration templates that you install **directly on your production server** to enable blue/green deployments. Think of it as a server-side deployment toolkit that works with your existing Docker-based applications.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Server Installation](#server-installation)
- [Application Health Check Requirements](#application-health-check-requirements)
- [Deployment Workflow](#deployment-workflow)
- [Configuration Approach](#configuration-approach)
- [Command Reference](#command-reference)
- [CI/CD Integration](#cicd-integration)
- [Handling Configuration File Updates](#handling-configuration-file-updates)
- [Supporting Multiple Applications](#supporting-multiple-applications)
- [Integrating Backend Services](#integrating-backend-services)
- [Plugin System](#plugin-system)
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

## Quick Start

Get up and running quickly with these steps:

1. **Install on your server**:
   ```bash
   # SSH into your server
   ssh user@your-server-ip
   
   # Per-Project Installation (Default)
   mkdir -p /app/myapp && cd /app/myapp
   
   # Download only the essential deployment files
   curl -s https://raw.githubusercontent.com/elijahmont3x/blue-green-deploy/main/scripts/install.sh | bash -s myapp
   
   # OR Centralized Installation (For managing multiple projects)
   mkdir -p /apps/your-org/tools/blue-green-deploy && cd /apps/your-org/tools/blue-green-deploy
   curl -s https://raw.githubusercontent.com/elijahmont3x/blue-green-deploy/main/scripts/install.sh | bash -s your-org centralized
   ```

2. **Upload your application files**:
   ```bash
   # From your local machine
   scp docker-compose.yml user@your-server-ip:/app/myapp/
   scp Dockerfile user@your-server-ip:/app/myapp/
   ```

3. **Deploy your application**:
   ```bash
   # For per-project installation
   cd /app/myapp
   ./scripts/deploy.sh v1.0.0 --app-name=myapp --image-repo=yourusername/myapp
   
   # OR for centralized installation
   cd /apps/your-org/tools/blue-green-deploy
   ./scripts/deploy.sh v1.0.0 --app-name=myapp --project-dir=/apps/your-org/myapp --image-repo=yourusername/myapp
   ```

4. **Complete the cutover** (if using --no-shift option or manual control):
   ```bash
   # For per-project installation
   ./scripts/cutover.sh green --app-name=myapp
   
   # OR for centralized installation
   ./scripts/cutover.sh green --app-name=myapp --project-dir=/apps/your-org/myapp
   ```

That's it! Your application is now deployed with zero downtime using blue/green deployment.

## How It Works

This system is installed on your production server and works with your existing `docker-compose.yml` and `Dockerfile`:

1. It creates environment-specific versions of your Docker Compose setup
2. It configures Nginx as a load balancer in front of your application
3. It manages which environment receives traffic and at what percentage
4. It orchestrates the deployment, testing, and cutover process

Here's how the system modifies your server infrastructure:

### How It Works

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

# Install the deployment scripts (auto-fixes permissions)
./install.sh your-app-name .
```

The `install.sh` script will:
- Auto-fix its own permissions if needed
- Create only the essential directories needed for deployment
- Install required deployment scripts and configuration templates 
- Make all scripts executable

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

## Application Health Check Requirements

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
### Environment Files and Docker Compose

While you provide configuration via command-line parameters, the system still generates temporary environment files (`.env.blue` and `.env.green`) for Docker Compose to use. This is because Docker Compose requires environment files to properly isolate environments.

**This is normal and expected behavior** - these files are:
- Automatically generated based on your command-line parameters
- Isolated to each environment (blue/green)
- Cleaned up during environment cleanup
- Not meant to be manually edited

You don't need to manage these files directly - just use the command-line parameters and the system will handle the rest.

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

## Command Reference

The deployment toolkit provides these commands (all run on your server):

### Deploy

```bash
./scripts/deploy.sh VERSION [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --image-repo=REPO     Docker image repository
#   --project-dir=PATH    Project directory for centralized deployments
#   --logs-dir=PATH       Logs directory location
#   --nginx-port=PORT     Nginx external port
#   --blue-port=PORT      Blue environment port
#   --green-port=PORT     Green environment port
#   --database-url=URL    Database connection string
#   --api-key=KEY         API key
#   --force               Force deployment even if target environment is active
#   --no-shift            Don't shift traffic automatically (manual cutover)

# Examples:
./scripts/deploy.sh v1.0 --app-name=myapp --image-repo=myname/myapp
./scripts/deploy.sh v1.1 --app-name=myapp --no-shift --project-dir=/apps/myorg/myapp
```

### Cutover

```bash
./scripts/cutover.sh [blue|green] [OPTIONS]

# Options:
#   --app-name=NAME       Application name
#   --project-dir=PATH    Project directory for centralized deployments
#   --logs-dir=PATH       Logs directory location
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
      
      # Copy configuration files to server (Default)
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

### Production-Ready Backend Example

For production-grade Node.js backend applications, here's a complete example that handles permissions, environment variables, and proper script installation:

```yaml
name: Backend CI/CD with Blue-Green Deployment

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
    # ...build and test steps...
    
  deploy:
    needs: test-and-build
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      # Copy deployment scripts and configuration templates
      - name: Copy deployment scripts to server
        uses: appleboy/scp-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          source: "scripts/**,config/**"
          target: '/app/backend'
          strip_components: 0
          overwrite: true
      
      # Copy application configuration files
      - name: Copy application files to server
        uses: appleboy/scp-action@master
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USER }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          source: "docker-compose.yml,Dockerfile"
          target: '/app/backend'
          strip_components: 0
      
      # Deploy to Production
      - name: Deploy to Production
        uses: appleboy/ssh-action@master
        env:
          VERSION: ${{ needs.test-and-build.outputs.version }}
          IMAGE_REPO: "ghcr.io/example/backend"
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
            cd /app/backend
            
            # Make scripts executable
            chmod +x ./scripts/*.sh
            
            # Export application-specific environment variables BEFORE deployment
            export APP_API_ENDPOINT="$APP_API_ENDPOINT"
            export APP_CONFIG_VALUE="$APP_CONFIG_VALUE"
            export APP_SECRET_KEY="$APP_SECRET_KEY"
            export APP_CORS_ORIGINS="$APP_CORS_ORIGINS"
            
            # Clean up failed deployments
            ./scripts/cleanup.sh --app-name=backend --failed-only
            
            # Run the deployment
            ./scripts/deploy.sh "$VERSION" \
              --app-name=backend \
              --image-repo=$IMAGE_REPO \
              --nginx-port=80 \
              --blue-port=8081 \
              --green-port=8082 \
              --health-endpoint=/health
```

## Handling Configuration File Updates

An important consideration is how `docker-compose.yml` and `Dockerfile` get updated on your server when you make changes to them in your repository.

### Approaches for Updating Configuration Files

1. **Automatic with Every Deployment** (Recommended, used by default)
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

### Snippet: Automatic File Updates with GitHub Actions

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

## Supporting Multiple Organizational Structures

This toolkit supports both per-project and centralized organizational structures:

### Per-Project Structure (Default)

In this approach, each application has its own copy of the deployment scripts:

```
/app/
├── app1/                      # First application
│   ├── docker-compose.yml
│   ├── scripts/               # Deployment scripts for app1
│   ├── config/                # Configuration templates 
│   └── logs/                  # Application-specific logs
│
├── app2/                      # Second application
│   ├── docker-compose.yml
│   ├── scripts/               # Separate copy of deployment scripts
│   ├── config/                # Configuration templates
│   └── logs/                  # Application-specific logs
```

### Centralized Structure

In this approach, deployment scripts are stored in a central location and used for multiple projects:

```
/apps/
├── organization/              # Organization folder
│   ├── tools/                 # Centralized tools
│   │   └── blue-green-deploy/ # Single copy of deployment scripts
│   │
│   ├── logs/                  # Centralized logs (optional)
│   │
│   ├── backend/               # First application
│   │   ├── docker-compose.yml
│   │   └── Dockerfile
│   │
│   └── website/               # Second application
│       ├── docker-compose.yml
│       └── Dockerfile
```

To use the centralized structure, install the scripts in your tools directory:

```bash
# Install in centralized tools directory
mkdir -p /apps/your-org/tools/blue-green-deploy
cd /apps/your-org/tools/blue-green-deploy
curl -L https://github.com/elijahmont3x/blue-green-deploy/archive/main.tar.gz | tar xz --strip-components=1
./install.sh your-org .

# Create centralized logs directory (optional)
mkdir -p /apps/your-org/logs
```

Then deploy individual projects by specifying their directory:

```bash
# Deploy backend project
cd /apps/your-org/tools/blue-green-deploy
./scripts/deploy.sh v1.0.0 \
  --app-name=backend \
  --project-dir=/apps/your-org/backend \
  --image-repo=your-org/backend \
  --logs-dir=/apps/your-org/logs \
  --nginx-port=80
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

## Plugin System

The plugin system allows you to extend the deployment process with custom hooks. Plugins are shell scripts placed in the `plugins/` directory that define special functions that run at specific points in the deployment process.

### Available Hooks

- `hook_pre_deploy`: Runs before deployment starts
- `hook_post_deploy`: Runs after deployment completes
- `hook_pre_cutover`: Runs before traffic cutover
- `hook_post_cutover`: Runs after traffic cutover
- `hook_pre_rollback`: Runs before rollback
- `hook_post_rollback`: Runs after rollback

### Real-World Plugin Examples

#### Slack Notification Plugin

```bash
#!/bin/bash
# plugins/slack-notifications.sh

# Slack webhook URL (set during deployment)
# Example: ./scripts/deploy.sh v1.0 --app-name=myapp --slack-webhook="https://hooks.slack.com/..."

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

#### Database Backup Plugin

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

#### Performance Test Plugin

```bash
#!/bin/bash
# plugins/perf-test.sh

hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  local port=$([[ "$env_name" == "blue" ]] && echo "${BLUE_PORT}" || echo "${GREEN_PORT}")
  
  log_info "Running basic performance test on new deployment"
  
  # Run simple load test using Apache Bench (ab)
  if command -v ab > /dev/null; then
    ab -n 100 -c 10 "http://localhost:${port}${HEALTH_ENDPOINT}" > "perf-test-${version}.txt"
    
    # Extract results
    local rps=$(grep "Requests per second" "perf-test-${version}.txt" | awk '{print $4}')
    local time=$(grep "Time per request" "perf-test-${version}.txt" | head -n 1 | awk '{print $4}')
    
    log_info "Performance test results: ${rps} req/sec, ${time}ms per request"
  else
    log_warning "Apache Bench (ab) not found, skipping performance test"
  fi
  
  return 0
}
```

### Creating Your Own Plugins

1. Create a bash script in the plugins directory:
   ```bash
   touch plugins/my-plugin.sh
   chmod +x plugins/my-plugin.sh
   ```

2. Define hook functions in your script:
   ```bash
   #!/bin/bash
   
   hook_pre_deploy() {
     local version="$1"
     log_info "Running pre-deployment tasks for version $version"
     # Your custom code here
     return 0  # Return 0 for success, non-zero for failure
   }
   ```

3. The hooks will automatically be called during the deployment process.

## Advanced Usage

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
cat logs/${APP_NAME}-*.log

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

## Docker Security Best Practices

### Running as Non-Root User

It's highly recommended to run your application container as a non-root user for improved security. Here's how to set that up in your Dockerfile:

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

Benefits of using a non-root user:
- Reduces the potential impact of container escape vulnerabilities
- Follows the principle of least privilege
- Prevents accidental modification of host files if volumes are mounted incorrectly
- Complies with security best practices and many platform requirements

### Environment Variable Propagation

Environment variables are automatically captured and propagated to your blue/green environments following these rules:

1. **Explicit parameters**: Variables passed as command-line parameters (like `--database-url`) take highest precedence
2. **Exported variables**: Any variables exported before running the deployment script are captured
3. **System-defined patterns**: Variables matching patterns like `DB_*` or `APP_*` are automatically included
4. **CI/CD variables**: Variables passed via the `env:` section in your CI/CD workflow propagate properly

Example of how to set application-specific variables in your deployment script:

```bash
# Set these before calling deploy.sh
export API_KEY="your-api-key"
export DATABASE_URL="postgresql://user:pass@host/db"
export REDIS_HOST="redis.example.com"

# These will be automatically propagated to both blue and green environments
./scripts/deploy.sh v1.0 --app-name=your-app-name
```

The system will include these variables in the `.env.blue` and `.env.green` files that are used by Docker Compose.