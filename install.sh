#!/bin/bash
#
# install.sh - Installs the blue/green deployment system
#
# Usage:
#   ./install.sh [APP_NAME] [TARGET_DIR]
#
# Arguments:
#   APP_NAME    Name of your application (default: "myapp")
#   TARGET_DIR  Directory to install to (default: current directory)

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
APP_NAME=${1:-"myapp"}
TARGET_DIR=${2:-"."}

# Source utility functions
source "$SCRIPT_DIR/scripts/common.sh" 2>/dev/null || {
  echo "Error: common.sh not found. Make sure you're running this script from the blue-green-deploy directory."
  exit 1
}

log_info "Installing blue/green deployment system for $APP_NAME in $TARGET_DIR"

# Create directory structure
ensure_directory "$TARGET_DIR"
ensure_directory "$TARGET_DIR/scripts"
ensure_directory "$TARGET_DIR/config/templates"
ensure_directory "$TARGET_DIR/plugins"
ensure_directory "$TARGET_DIR/.deployment_logs"

# Copy scripts
log_info "Copying scripts..."
cp "$SCRIPT_DIR/scripts/"*.sh "$TARGET_DIR/scripts/"
chmod +x "$TARGET_DIR/scripts/"*.sh

# Copy templates
log_info "Copying templates..."
cp "$SCRIPT_DIR/config/templates/"* "$TARGET_DIR/config/templates/"

# Create plugins directory placeholder
touch "$TARGET_DIR/plugins/.gitkeep"

# Create default .gitignore if it doesn't exist
if [ ! -f "$TARGET_DIR/.gitignore" ]; then
  cat > "$TARGET_DIR/.gitignore" << EOL
.env
.env.*
.deployment_logs/
nginx.conf
docker-compose.*.yml
EOL
  log_info "Created .gitignore file"
fi

# Create default config.env
if [ ! -f "$TARGET_DIR/config.env" ]; then
  cat > "$TARGET_DIR/config.env" << EOL
# Application Configuration
APP_NAME=$APP_NAME
IMAGE_REPO=example/image
NGINX_PORT=80
BLUE_PORT=8081
GREEN_PORT=8082
HEALTH_ENDPOINT=/health
HEALTH_RETRIES=12
HEALTH_DELAY=5

# Required Application Variables
# Add your application-specific variables here
APP_API_KEY=your_api_key_here
APP_DEBUG=false
EOL
  log_info "Created default config.env (please update with your settings)"
fi

# Create example docker-compose.yml if it doesn't exist
if [ ! -f "$TARGET_DIR/docker-compose.yml" ]; then
  cat > "$TARGET_DIR/docker-compose.yml" << EOL
version: '3.8'
name: \${APP_NAME}

networks:
  app-network:
    driver: bridge

services:
  backend-api:
    image: \${IMAGE:-example/image:latest}
    restart: unless-stopped
    environment:
      - NODE_ENV=\${NODE_ENV:-production}
      - ENV_NAME=\${ENV_NAME:-default}
      # Add your environment variables here
    ports:
      - '\${PORT:-3000}:3000'
    healthcheck:
      test: ['CMD', 'curl', '-f', 'http://localhost:3000/health']
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - app-network

  nginx:
    image: nginx:stable-alpine
    container_name: \${APP_NAME}-nginx
    restart: unless-stopped
    ports:
      - '\${NGINX_PORT:-80}:80'
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - backend-api
    networks:
      - app-network
EOL
  log_info "Created example docker-compose.yml"
fi

# Create a README file with deployment instructions
cat > "$TARGET_DIR/README.md" << EOL
# Blue/Green Deployment for $APP_NAME

## Overview
This system uses a blue/green deployment strategy to ensure zero downtime deployments.
Two environments (blue and green) are maintained, with traffic being routed between them
during deployments.

## Quick Start

1. **Configure your application**
   
   Edit \`config.env\` with your application settings.

2. **Deploy a new version**
   \`\`\`bash
   ./scripts/deploy.sh VERSION
   \`\`\`
   This will deploy to the inactive environment and gradually shift traffic to it.

3. **Complete cutover**
   \`\`\`bash
   ./scripts/cutover.sh [blue|green]
   \`\`\`
   This will shift 100% of traffic to the specified environment.

4. **Rollback if needed**
   \`\`\`bash
   ./scripts/rollback.sh
   \`\`\`
   This will revert traffic back to the previous environment.

5. **Cleanup old deployments**
   \`\`\`bash
   ./scripts/cleanup.sh
   \`\`\`
   This will clean up old and failed deployments.

## Required Environment Variables

Edit \`config.env\` to set these variables:

- \`APP_NAME\`: Your application name
- \`IMAGE_REPO\`: Docker image repository
- \`NGINX_PORT\`: Port for the nginx service
- \`BLUE_PORT\` and \`GREEN_PORT\`: Ports for blue and green environments
- \`HEALTH_ENDPOINT\`: Health check endpoint

## Advanced Usage

For more options, see the help for each script:

\`\`\`bash
./scripts/deploy.sh --help
./scripts/cutover.sh --help
./scripts/rollback.sh --help
./scripts/cleanup.sh --help
\`\`\`

## Plugin System

You can extend the deployment system by adding scripts to the \`plugins/\` directory.
EOL

log_success "Blue/Green deployment system installed successfully!"
log_info "Next steps:"
log_info "1. Edit config.env with your application settings"
log_info "2. Update docker-compose.yml for your application"
log_info "3. Run './scripts/deploy.sh VERSION' to start a deployment"