#!/bin/bash
#
# deploy.sh - Deploys a new version using blue/green deployment strategy
#
# Usage:
#   ./deploy.sh VERSION [OPTIONS]
#
# Arguments:
#   VERSION     Version identifier for the deployment
#
# Options:
#   --force     Force deployment even if target environment is active
#   --no-shift  Don't shift traffic automatically (manual cutover)
#   --config=X  Use alternate config file (default: config.env)

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

# Default options
FORCE_DEPLOY=false
AUTO_SHIFT=true
CONFIG_FILE="config.env"

# Parse additional options
for arg in "$@"; do
  case $arg in
    --force)
      FORCE_DEPLOY=true
      shift
      ;;
    --no-shift)
      AUTO_SHIFT=false
      shift
      ;;
    --config=*)
      CONFIG_FILE="${arg#*=}"
      shift
      ;;
    *)
      # Unknown option
      log_error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

log_info "Starting deployment of version $VERSION"
log_deployment_step "$VERSION" "deployment_started" "started"

# Load configuration
load_config "$CONFIG_FILE"

# Check required environment variables
validate_required_vars "APP_NAME" "IMAGE_REPO" "HEALTH_ENDPOINT" || {
  log_error "Missing required environment variables. Please set them in $CONFIG_FILE"
  log_deployment_step "$VERSION" "deployment_failed" "missing_variables"
  exit 1
}

# Set defaults if not provided
APP_NAME=${APP_NAME:-"app"}
BLUE_PORT=${BLUE_PORT:-"8081"}
GREEN_PORT=${GREEN_PORT:-"8082"}
HEALTH_ENDPOINT=${HEALTH_ENDPOINT:-"/health"}
HEALTH_RETRIES=${HEALTH_RETRIES:-12}
HEALTH_DELAY=${HEALTH_DELAY:-5}
IMAGE_REPO=${IMAGE_REPO:-"myapp"}
IMAGE_TAG=${VERSION}
NGINX_PORT=${NGINX_PORT:-"80"}

# Run pre-deployment hook
run_hook "pre_deploy" "$VERSION" "$APP_NAME"

# Determine which environment to deploy to (blue or green)
read CURRENT_ENV TARGET_ENV <<< $(get_environments)
log_info "Current environment: $CURRENT_ENV, deploying to: $TARGET_ENV"

CURRENT_PORT=$([[ "$CURRENT_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
TARGET_PORT=$([[ "$TARGET_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")

# Check if target environment is already active (should not happen normally)
DOCKER_COMPOSE=$(get_docker_compose_cmd)
if $DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV ps 2>/dev/null | grep -q "Up"; then
  if [ "$FORCE_DEPLOY" = true ]; then
    log_warning "Target environment $TARGET_ENV is already running, but --force is specified. Stopping it first..."
    $DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV down
    handle_error "Failed to stop target environment" false
  else
    log_error "Target environment $TARGET_ENV is already running. Use --force to override."
    log_deployment_step "$VERSION" "deployment_failed" "target_env_running"
    exit 1
  fi
fi

# Create environment file for target deployment
ENV_FILE=".env.${TARGET_ENV}"
cat > "$ENV_FILE" << EOL
APP_NAME=${APP_NAME}
IMAGE=${IMAGE_REPO}:${IMAGE_TAG}
PORT=${TARGET_PORT}
ENV_NAME=${TARGET_ENV}
# Additional environment variables
$(env | grep -E '^APP_|^SERVICE_' | sort)
EOL

# Secure the environment file
secure_env_file "$ENV_FILE"

# Create docker-compose override for target environment
TEMPLATE_DIR="${SCRIPT_DIR}/../config/templates"
DOCKER_COMPOSE_TEMPLATE="${TEMPLATE_DIR}/docker-compose.override.template"
DOCKER_COMPOSE_OVERRIDE="docker-compose.${TARGET_ENV}.yml"

apply_template "$DOCKER_COMPOSE_TEMPLATE" "$DOCKER_COMPOSE_OVERRIDE" \
  "APP_NAME" "$APP_NAME" \
  "ENV_NAME" "$TARGET_ENV" \
  "PORT" "$TARGET_PORT"

# Start the new environment
log_info "Starting $TARGET_ENV environment with version $VERSION..."
$DOCKER_COMPOSE -p ${APP_NAME}-$TARGET_ENV --env-file "$ENV_FILE" \
  -f docker-compose.yml -f "$DOCKER_COMPOSE_OVERRIDE" up -d

handle_error "Failed to start $TARGET_ENV environment" true
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

# If auto-shift is enabled, update traffic routing
if [ "$AUTO_SHIFT" = true ]; then
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
    log_info "Run '${SCRIPT_DIR}/cutover.sh $TARGET_ENV' to complete the deployment"
  else
    log_error "Nginx template file not found at $NGINX_TEMPLATE"
    log_deployment_step "$VERSION" "deployment_warning" "nginx_template_missing"
  fi
else
  log_info "Automatic traffic shifting is disabled"
  log_info "Run '${SCRIPT_DIR}/cutover.sh $TARGET_ENV' when ready to shift traffic"
fi

# Run post-deployment hook
run_hook "post_deploy" "$VERSION" "$TARGET_ENV"

log_deployment_step "$VERSION" "deployment_completed" "success"
log_success "Deployment of version $VERSION to $TARGET_ENV environment completed successfully!"
