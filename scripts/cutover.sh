#!/bin/bash
#
# cutover.sh - Completes the cutover to the specified environment and stops the old one
#
# Usage:
#   ./cutover.sh [environment_name] [OPTIONS]
#
# Arguments:
#   environment_name      Environment to cutover to (blue or green)
#
# Options:
#   --app-name=NAME       Application name
#   --keep-old            Don't stop the previous environment
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
source "$SCRIPT_DIR/common.sh"

# Parse arguments
if [ $# -lt 1 ]; then
  log_error "Missing environment name parameter"
  echo "Usage: $0 environment_name [OPTIONS]"
  exit 1
fi

NEW_ENV="$1"
shift

if [[ "$NEW_ENV" != "blue" && "$NEW_ENV" != "green" ]]; then
  log_error "Environment must be 'blue' or 'green'"
  exit 1
fi

# Parse command-line parameters
parse_parameters "$@" || {
  log_error "Invalid parameters"
  exit 1
}

OLD_ENV=$([[ "$NEW_ENV" == "blue" ]] && echo "green" || echo "blue")
DOCKER_COMPOSE=$(get_docker_compose_cmd)

log_info "Starting cutover from $OLD_ENV to $NEW_ENV for $APP_NAME"

# Run pre-cutover hook
run_hook "pre_cutover" "$NEW_ENV" "$OLD_ENV" || {
  log_error "Pre-cutover hook failed"
  exit 1
}

# Update nginx configuration to route 100% traffic to the new environment
log_info "Updating nginx configuration to route 100% traffic to $NEW_ENV..."

# Use the single environment template
TEMPLATE_DIR="${SCRIPT_DIR}/../config/templates"
NGINX_TEMPLATE="${TEMPLATE_DIR}/nginx-single-env.conf.template"

if [ -f "$NGINX_TEMPLATE" ]; then
  cat "$NGINX_TEMPLATE" | \
    sed -e "s/ENVIRONMENT/$NEW_ENV/g" | \
    sed -e "s/APP_NAME/$APP_NAME/g" | \
    sed -e "s/NGINX_PORT/${NGINX_PORT}/g" > nginx.conf
  log_info "Generated nginx config for $NEW_ENV environment"
else
  log_error "Nginx template file not found at $NGINX_TEMPLATE"
  exit 1
fi

# Reload nginx configuration
log_info "Reloading nginx..."
$DOCKER_COMPOSE restart nginx || log_warning "Failed to restart nginx"

# Wait to ensure traffic is properly routed
log_info "Waiting for traffic to stabilize..."
sleep 5

# Check if the new environment is healthy
log_info "Verifying $NEW_ENV environment health..."
NEW_PORT=$([[ "$NEW_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
HEALTH_URL="http://localhost:${NEW_PORT}${HEALTH_ENDPOINT}"

if ! check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
  log_error "New environment ($NEW_ENV) is not healthy! Aborting cutover."
  exit 1
fi

# If not keeping the old environment, stop it
if [ "$KEEP_OLD" != true ]; then
  # Stop the old environment with proper cleanup
  log_info "Stopping old $OLD_ENV environment..."
  $DOCKER_COMPOSE -p ${APP_NAME}-${OLD_ENV} down --remove-orphans || \
    log_warning "Failed to stop old environment containers"

  # Remove environment file
  if [ -f ".env.${OLD_ENV}" ]; then
    log_info "Removing old environment file .env.${OLD_ENV}"
    rm -f ".env.${OLD_ENV}" || log_warning "Failed to remove .env.${OLD_ENV}"
  fi

  # Clean up any orphaned containers
  OLD_CONTAINERS=$(docker ps -a --filter "name=${APP_NAME}-${OLD_ENV}" --format "{{.ID}}" || echo "")
  if [ -n "$OLD_CONTAINERS" ]; then
    log_warning "Found orphaned containers for old environment, removing them..."
    docker rm -f $OLD_CONTAINERS || log_warning "Failed to remove some orphaned containers"
  fi
else
  log_info "Keeping old $OLD_ENV environment running as requested"
fi

# Run post-cutover hook
run_hook "post_cutover" "$NEW_ENV" "$OLD_ENV" || {
  log_warning "Post-cutover hook failed"
  # Continue despite warning
}

log_success "Cutover completed successfully! All traffic is now routed to the $NEW_ENV environment."