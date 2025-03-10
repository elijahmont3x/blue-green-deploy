#!/bin/bash
#
# deploy.sh - Deploys a new version using blue/green deployment strategy
#
# Usage:
#   ./deploy.sh VERSION [OPTIONS]
#
# Arguments:
#   VERSION                Version identifier for the deployment
#
# Options:
#   --app-name=NAME       Application name (default: app)
#   --image-repo=REPO     Docker image repository
#   --nginx-port=PORT     Nginx external port (default: 80)
#   --blue-port=PORT      Blue environment port (default: 8081)
#   --green-port=PORT     Green environment port (default: 8082)
#   --health-endpoint=PATH Health check endpoint (default: /health)
#   --health-retries=N    Number of health check retries (default: 12)
#   --health-delay=SEC    Delay between health checks (default: 5)
#   --database-url=URL    Database connection string
#   --api-key=KEY         API key
#   --redis-url=URL       Redis connection string
#   --force               Force deployment even if target environment is active
#   --no-shift            Don't shift traffic automatically (manual cutover)
#
# Examples:
#   ./deploy.sh v1.0.0 --app-name=myapp --image-repo=myname/myapp
#   ./deploy.sh v1.0.0 --app-name=myapp --no-shift
#   ./deploy.sh v1.0.0 --app-name=myapp --force --database-url="postgresql://user:pass@host/db"

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

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

# Determine which environment to deploy to (blue or green)
read CURRENT_ENV TARGET_ENV <<< $(get_environments)
log_info "Current environment: $CURRENT_ENV, deploying to: $TARGET_ENV"

CURRENT_PORT=$([[ "$CURRENT_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
TARGET_PORT=$([[ "$TARGET_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")

# Check if target environment is already active (should not happen normally)
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
  backend-api:
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

# Start the new environment
log_info "Starting $TARGET_ENV environment with version $VERSION..."
$DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV --env-file .env.${TARGET_ENV} \
  -f docker-compose.yml -f "$DOCKER_COMPOSE_OVERRIDE" up -d

if [ $? -ne 0 ]; then
  log_error "Failed to start $TARGET_ENV environment"
  log_deployment_step "$VERSION" "deployment_failed" "environment_start_failed"
  exit 1
fi

log_info "Environment started successfully"
log_deployment_step "$VERSION" "environment_started" "success"

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
  NGINX_TEMPLATE="${TEMPLATE_DIR}/nginx-dual-env.conf.template"
  
  if [ -f "$NGINX_TEMPLATE" ]; then
    # Update to 90/10 split favoring current environment
    if [ "$CURRENT_ENV" = "blue" ]; then
      update_traffic_distribution 9 1 "$NGINX_TEMPLATE" "nginx.conf"
    else
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
    log_error "Nginx template file not found at $NGINX_TEMPLATE"
    log_deployment_step "$VERSION" "deployment_warning" "nginx_template_missing"
  fi
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