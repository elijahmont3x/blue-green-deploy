#!/bin/bash
#
# rollback.sh - Rolls back to the previous environment
#
# Usage:
#   ./rollback.sh [OPTIONS]
#
# Options:
#   --app-name=NAME       Application name
#   --force               Force rollback even if environment is unhealthy
#   --nginx-port=PORT     Nginx external port
#   --blue-port=PORT      Blue environment port
#   --green-port=PORT     Green environment port
#   --health-endpoint=PATH Health check endpoint
#   --health-retries=N    Number of health check retries
#   --health-delay=SEC    Delay between health checks

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

# Parse command-line parameters
parse_parameters "$@" || {
  log_error "Invalid parameters"
  exit 1
}

log_info "Starting rollback procedure for $APP_NAME"

# Run pre-rollback hook
run_hook "pre_rollback" || {
  log_error "Pre-rollback hook failed"
  exit 1
}

# Determine which environment is currently active and which is standby
read ACTIVE_ENV ROLLBACK_ENV <<< $(get_environments)

DOCKER_COMPOSE=$(get_docker_compose_cmd)

# Check if the rollback environment exists
if ! $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} ps 2>/dev/null | grep -q "backend-api"; then
  log_error "Rollback environment ($ROLLBACK_ENV) doesn't exist! Cannot rollback."
  exit 1
fi

log_info "Active environment: $ACTIVE_ENV, rolling back to: $ROLLBACK_ENV"

# Check if rollback environment is up; if not, start it
if ! $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} ps 2>/dev/null | grep -q "Up"; then
  if [ -f ".env.${ROLLBACK_ENV}" ]; then
    log_info "Starting rollback environment ($ROLLBACK_ENV)..."
    $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} --env-file .env.${ROLLBACK_ENV} \
      -f docker-compose.yml -f docker-compose.${ROLLBACK_ENV}.yml up -d
    
    if [ $? -ne 0 ]; then
      log_error "Failed to start rollback environment"
      exit 1
    fi
  else
    log_error "Rollback environment configuration not found at .env.${ROLLBACK_ENV}"
    exit 1
  fi
fi

# Check health of rollback environment
ROLLBACK_PORT=$([[ "$ROLLBACK_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
HEALTH_URL="http://localhost:${ROLLBACK_PORT}${HEALTH_ENDPOINT}"

if ! check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
  if [ "$FORCE_FLAG" = true ]; then
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
  cat "$NGINX_TEMPLATE" | \
    sed -e "s/ENVIRONMENT/$ROLLBACK_ENV/g" | \
    sed -e "s/APP_NAME/$APP_NAME/g" | \
    sed -e "s/NGINX_PORT/${NGINX_PORT}/g" > nginx.conf
  log_info "Generated nginx config for $ROLLBACK_ENV environment"
else
  log_error "Nginx template file not found at $NGINX_TEMPLATE"
  exit 1
fi

# Reload nginx configuration
log_info "Reloading nginx..."
$DOCKER_COMPOSE restart nginx || log_warning "Failed to restart nginx"

# Run post-rollback hook
run_hook "post_rollback" "$ROLLBACK_ENV" || {
  log_warning "Post-rollback hook failed"
  # Continue despite warning
}

log_success "Rollback completed successfully! All traffic is now routed to the $ROLLBACK_ENV environment."