#!/bin/bash
#
# rollback.sh - Rolls back to the previous environment
#
# Usage:
#   ./rollback.sh [OPTIONS]
#
# Options:
#   --force          Force rollback even if the previous environment is unhealthy
#   --config=X       Use alternate config file (default: config.env)

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/common.sh"

# Default options
FORCE_ROLLBACK=false
CONFIG_FILE="config.env"

# Parse options
for arg in "$@"; do
  case $arg in
    --force)
      FORCE_ROLLBACK=true
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

# Load configuration
load_config "$CONFIG_FILE"

# Set defaults if not provided
APP_NAME=${APP_NAME:-"app"}
HEALTH_ENDPOINT=${HEALTH_ENDPOINT:-"/health"}
HEALTH_RETRIES=${HEALTH_RETRIES:-3}
HEALTH_DELAY=${HEALTH_DELAY:-5}

log_info "Starting rollback procedure"

# Run pre-rollback hook
run_hook "pre_rollback"

# Determine which environment is currently active and which is standby
read ACTIVE_ENV ROLLBACK_ENV <<< $(get_environments)

DOCKER_COMPOSE=$(get_docker_compose_cmd)

# Check if the rollback environment exists
if ! $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} ps 2>/dev/null | grep -q "Up"; then
  if [ -f ".env.${ROLLBACK_ENV}" ]; then
    log_warning "Rollback environment ($ROLLBACK_ENV) exists but is not running. Starting it..."
    $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} --env-file .env.${ROLLBACK_ENV} \
      -f docker-compose.yml -f docker-compose.${ROLLBACK_ENV}.yml up -d
    
    handle_error "Failed to start rollback environment" false
  else
    log_error "Rollback environment ($ROLLBACK_ENV) doesn't exist! Cannot rollback."
    exit 1
  fi
fi

log_info "Active environment: $ACTIVE_ENV, rolling back to: $ROLLBACK_ENV"

# Check health of rollback environment
ROLLBACK_PORT=$([[ "$ROLLBACK_ENV" == "blue" ]] && echo "${BLUE_PORT:-8081}" || echo "${GREEN_PORT:-8082}")
HEALTH_URL="http://localhost:${ROLLBACK_PORT}${HEALTH_ENDPOINT}"

if ! check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
  if [ "$FORCE_ROLLBACK" = true ]; then
    log_warning "Rollback environment is NOT healthy, but --force was specified. Proceeding anyway."
  else
    log_error "Rollback environment is NOT healthy! Aborting rollback. Use --force to override."
    exit 1
  fi
fi

# Update nginx to route traffic to rollback environment
log_info "Updating nginx to route traffic to $ROLLBACK_ENV environment..."

# Use the single environment template
TEMPLATE_DIR="${SCRIPT_DIR}/../config/templates"
NGINX_TEMPLATE="${TEMPLATE_DIR}/nginx-single-env.conf.template"

if [ -f "$NGINX_TEMPLATE" ]; then
  apply_template "$NGINX_TEMPLATE" "nginx.conf" "ENVIRONMENT" "$ROLLBACK_ENV" "APP_NAME" "$APP_NAME"
else
  log_error "Nginx template file not found at $NGINX_TEMPLATE"
  exit 1
fi

# Reload nginx configuration
log_info "Reloading nginx..."
$DOCKER_COMPOSE restart nginx || log_warning "Failed to restart nginx"

# Run post-rollback hook
run_hook "post_rollback" "$ROLLBACK_ENV"

log_success "Rollback completed successfully! All traffic is now routed to the $ROLLBACK_ENV environment."
