#!/bin/bash
#
# deploy.sh - Enhanced deployment script with multi-container support
#
# Usage:
#   ./deploy.sh VERSION [OPTIONS]
#
# Arguments:
#   VERSION                Version identifier for the deployment
#
# Options:
#   --app-name=NAME           Application name (default: app)
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
#
# Examples:
#   ./deploy.sh v1.0.0 --app-name=myapp --image-repo=myorg/backend --domain-name=myproject.com
#   ./deploy.sh v1.0.0 --app-name=myapp --setup-shared --domain-name=myproject.com

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/common.sh"

# Parse arguments
if [ $# -lt 1 ]; then
  log_error "Missing version parameter"
  echo "Usage: $0 VERSION [OPTIONS]"
  exit 1
fi

VERSION="$1"
shift

# Parse command-line parameters
parse_parameters "$@" || {
  log_error "Invalid parameters"
  exit 1
}

# Set additional defaults
FRONTEND_VERSION=${FRONTEND_VERSION:-$VERSION}
DOMAIN_NAME=${DOMAIN_NAME:-example.com}
NGINX_SSL_PORT=${NGINX_SSL_PORT:-443}
SETUP_SHARED=${SETUP_SHARED:-false}
SKIP_MIGRATIONS=${SKIP_MIGRATIONS:-false}
MIGRATIONS_CMD=${MIGRATIONS_CMD:-"npm run migrate"}

log_info "Starting deployment of version $VERSION for $APP_NAME"
log_deployment_step "$VERSION" "deployment_started" "started"

# Run pre-deployment hook
run_hook "pre_deploy" "$VERSION" "$APP_NAME" || {
  log_error "Pre-deployment hook failed"
  log_deployment_step "$VERSION" "deployment_failed" "pre_deploy_hook_failed"
  exit 1
}

# Ensure Docker is running
ensure_docker_running || {
  log_error "Docker is not running. Please start Docker and try again."
  log_deployment_step "$VERSION" "deployment_failed" "docker_not_running"
  exit 1
}

# Get Docker Compose command
DOCKER_COMPOSE=$(get_docker_compose_cmd)

# Initialize shared services if requested
if [ "$SETUP_SHARED" = true ]; then
  log_info "Setting up shared services (database, redis, etc.)"
  
  # Create shared network if it doesn't exist
  if ! docker network inspect ${APP_NAME}-shared-network &>/dev/null; then
    log_info "Creating shared network: ${APP_NAME}-shared-network"
    docker network create ${APP_NAME}-shared-network
    export SHARED_NETWORK_EXISTS=true
  else
    log_info "Shared network already exists"
    export SHARED_NETWORK_EXISTS=true
  fi
  
  # Create shared volumes if they don't exist
  if ! docker volume inspect ${APP_NAME}-db-data &>/dev/null; then
    log_info "Creating database volume: ${APP_NAME}-db-data"
    docker volume create ${APP_NAME}-db-data
    export DB_DATA_EXISTS=true
  else
    log_info "Database volume already exists"
    export DB_DATA_EXISTS=true
  fi
  
  if ! docker volume inspect ${APP_NAME}-redis-data &>/dev/null; then
    log_info "Creating Redis volume: ${APP_NAME}-redis-data"
    docker volume create ${APP_NAME}-redis-data
    export REDIS_DATA_EXISTS=true
  else
    log_info "Redis volume already exists"
    export REDIS_DATA_EXISTS=true
  fi
  
  # Start shared services
  log_info "Starting shared services (database, redis)"
  
  # Create temporary compose file for shared services
  cat > "docker-compose.shared.yml" << EOL
version: '3.8'
name: ${APP_NAME}-shared
services:
  db:
    extends:
      file: docker-compose.yml
      service: db
  redis:
    extends:
      file: docker-compose.yml
      service: redis
networks:
  shared-network:
    external: true
    name: ${APP_NAME}-shared-network
volumes:
  db-data:
    external: true
    name: ${APP_NAME}-db-data
  redis-data:
    external: true
    name: ${APP_NAME}-redis-data
EOL
  
  $DOCKER_COMPOSE -f docker-compose.yml -f docker-compose.shared.yml --profile shared up -d db redis
  
  if [ $? -ne 0 ]; then
    log_error "Failed to start shared services"
    log_deployment_step "$VERSION" "deployment_failed" "shared_services_start_failed"
    exit 1
  fi
  
  log_info "Waiting for shared services to be healthy..."
  sleep 10
  
  # Check if shared services are healthy
  if ! docker ps --filter "name=${APP_NAME}-shared" --format "{{.Status}}" | grep -q "healthy"; then
    log_warning "Some shared services may not be fully healthy yet. Proceeding anyway..."
  else
    log_success "Shared services are healthy"
  fi
fi

# Determine which environment to deploy to (blue or green)
read CURRENT_ENV TARGET_ENV <<< $(get_environments)
log_info "Current environment: $CURRENT_ENV, deploying to: $TARGET_ENV"

CURRENT_PORT=$([[ "$CURRENT_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
TARGET_PORT=$([[ "$TARGET_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")

# Check if target environment is already active
if $DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV ps 2>/dev/null | grep -q "Up"; then
  if [ "$FORCE_FLAG" = true ]; then
    log_warning "Target environment $TARGET_ENV is already running, but --force is specified. Stopping it first..."
    $DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV down
  else
    log_error "Target environment $TARGET_ENV is already running. Use --force to override."
    log_deployment_step "$VERSION" "deployment_failed" "target_env_running"
    exit 1
  fi
fi

# Create environment file for target deployment
create_env_file "$TARGET_ENV" "$TARGET_PORT"

# Add additional variables to environment file
cat >> ".env.${TARGET_ENV}" << EOL
# Multi-container configuration
FRONTEND_VERSION=${FRONTEND_VERSION}
FRONTEND_IMAGE_REPO=${FRONTEND_IMAGE_REPO:-ghcr.io/example/frontend}
DOMAIN_NAME=${DOMAIN_NAME}
NGINX_SSL_PORT=${NGINX_SSL_PORT}
SHARED_NETWORK_EXISTS=true
DB_DATA_EXISTS=true
REDIS_DATA_EXISTS=true
EOL

# Generate environment-specific docker-compose overrides
TEMPLATE_DIR="${SCRIPT_DIR}/../config/templates"
DOCKER_COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.override.template"
DOCKER_COMPOSE_OVERRIDE="docker-compose.${TARGET_ENV}.yml"

if [ -f "$DOCKER_COMPOSE_TEMPLATE" ]; then
  cat "$DOCKER_COMPOSE_TEMPLATE" | \
    sed -e "s/{{ENV_NAME}}/$TARGET_ENV/g" | \
    sed -e "s/{{PORT}}/$TARGET_PORT/g" > "$DOCKER_COMPOSE_OVERRIDE"
  log_info "Generated docker-compose override for $TARGET_ENV environment"
else
  log_warning "Docker Compose template not found at $DOCKER_COMPOSE_TEMPLATE. Using default configuration."
  # Create a minimal override
  cat > "$DOCKER_COMPOSE_OVERRIDE" << EOL
# Auto-generated environment-specific overrides for $TARGET_ENV environment
version: '3.8'

services:
  app:
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - ENV_NAME=${TARGET_ENV}
    ports:
      - '${TARGET_PORT}:3000'

  nginx:
    container_name: ${APP_NAME}-nginx-${TARGET_ENV}
EOL
fi

# Generate initial nginx.conf file for multi-domain routing
NGINX_TEMPLATE="${TEMPLATE_DIR}/nginx-multi-domain.conf.template"
if [ -f "$NGINX_TEMPLATE" ]; then
  log_info "Generating initial nginx configuration for multi-domain routing..."
  
  if [ "$CURRENT_ENV" = "blue" ]; then
    # Blue is active, so it gets weight 10, green gets 0
    BLUE_WEIGHT_VALUE=10
    GREEN_WEIGHT_VALUE=0
  else
    # Green is active, so it gets weight 10, blue gets 0
    BLUE_WEIGHT_VALUE=0
    GREEN_WEIGHT_VALUE=10
  fi
  
  cat "$NGINX_TEMPLATE" | \
    sed -e "s/BLUE_WEIGHT/$BLUE_WEIGHT_VALUE/g" | \
    sed -e "s/GREEN_WEIGHT/$GREEN_WEIGHT_VALUE/g" | \
    sed -e "s/APP_NAME/$APP_NAME/g" | \
    sed -e "s/DOMAIN_NAME/$DOMAIN_NAME/g" | \
    sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
    sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT}/g" > "nginx.conf"
else
  log_error "Nginx template file not found at $NGINX_TEMPLATE"
  log_deployment_step "$VERSION" "deployment_failed" "nginx_template_missing"
  exit 1
fi

# Create directory for SSL certificates if it doesn't exist
ensure_directory "certs"

# Start the new environment
log_info "Starting $TARGET_ENV environment with version $VERSION..."
$DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV --env-file .env.${TARGET_ENV} \
  -f docker-compose.yml -f "docker-compose.${TARGET_ENV}.yml" up -d

if [ $? -ne 0 ]; then
  log_error "Failed to start $TARGET_ENV environment"
  log_deployment_step "$VERSION" "deployment_failed" "environment_start_failed"
  exit 1
fi

log_info "Environment started successfully"
log_deployment_step "$VERSION" "environment_started" "success"

# Run database migrations if needed
if [ "$SKIP_MIGRATIONS" = false ]; then
  log_info "Running database migrations..."
  
  # Execute migrations within the container
  $DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV exec -T app sh -c "$MIGRATIONS_CMD" || {
    log_error "Database migrations failed"
    log_deployment_step "$VERSION" "deployment_failed" "migrations_failed"
    exit 1
  }
  
  log_success "Database migrations completed successfully"
else
  log_info "Skipping database migrations as requested"
fi

# Wait for the new environment to be healthy
log_info "Waiting for $TARGET_ENV environment to be healthy..."
HEALTH_URL="http://localhost:${TARGET_PORT}${HEALTH_ENDPOINT}"
if ! check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
  log_error "New environment failed health checks. Deployment failed."
  $DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV logs
  log_deployment_step "$VERSION" "deployment_failed" "health_check_failed"
  exit 1
fi

log_deployment_step "$VERSION" "health_check_passed" "success"

# Run post-health hook
run_hook "post_health" "$VERSION" "$TARGET_ENV" || {
  log_error "Post-health hook failed"
  log_deployment_step "$VERSION" "deployment_warning" "post_health_hook_failed"
  # Continue despite warning
}

# If auto-shift is enabled, update traffic routing
if [ "$NO_SHIFT" != true ]; then
  log_info "Gradually shifting traffic to $TARGET_ENV environment..."
  
  # Create a dual environment nginx config with initially 90/10 traffic split
  if [ "$CURRENT_ENV" = "blue" ]; then
    # Blue is active, shift 10% to green
    update_traffic_distribution 9 1 "$NGINX_TEMPLATE" "nginx.conf"
  else
    # Green is active, shift 10% to blue
    update_traffic_distribution 1 9 "$NGINX_TEMPLATE" "nginx.conf"
  fi
  sleep 10
  
  # Update to 50/50 split
  update_traffic_distribution 5 5 "$NGINX_TEMPLATE" "nginx.conf"
  sleep 10
  
  # Final update to 10/90 split favoring new environment
  if [ "$CURRENT_ENV" = "blue" ]; then
    update_traffic_distribution 1 9 "$NGINX_TEMPLATE" "nginx.conf"
  else
    update_traffic_distribution 9 1 "$NGINX_TEMPLATE" "nginx.conf"
  fi
  
  log_success "Traffic gradually shifted to new $TARGET_ENV environment"
  log_info "Run '${SCRIPT_DIR}/cutover.sh $TARGET_ENV --app-name=$APP_NAME' to complete the deployment"
else
  log_info "Automatic traffic shifting is disabled"
  log_info "Run '${SCRIPT_DIR}/cutover.sh $TARGET_ENV --app-name=$APP_NAME' when ready to shift traffic"
fi

# Run post-deployment hook
run_hook "post_deploy" "$VERSION" "$TARGET_ENV" || {
  log_error "Post-deployment hook failed"
  log_deployment_step "$VERSION" "deployment_warning" "post_deploy_hook_failed"
  # Continue despite warning
}

log_deployment_step "$VERSION" "deployment_completed" "success"
log_success "Deployment of version $VERSION to $TARGET_ENV environment completed successfully!"