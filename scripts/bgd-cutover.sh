#!/bin/bash
#
# bgd-cutover.sh - Cuts over traffic to a specific environment
#
# Usage:
#   ./cutover.sh [blue|green] [OPTIONS]
#
# Arguments:
#   [blue|green]           Target environment to cutover to
#
# Options:
#   --app-name=NAME       Application name
#   --domain-name=DOMAIN  Domain name for multi-domain routing
#   --keep-old            Don't stop the previous environment
#   --nginx-port=PORT     Nginx external port
#   --nginx-ssl-port=PORT Nginx HTTPS port
#   --blue-port=PORT      Blue environment port
#   --green-port=PORT     Green environment port
#   --health-endpoint=PATH Health check endpoint
#   --health-retries=N    Number of health check retries
#   --health-delay=SEC    Delay between health checks

set -euo pipefail

# Get script directory
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Main cutover function
bgd_cutover() {
  # Parse arguments
  if [ $# -lt 1 ] || [[ ! "$1" =~ ^(blue|green)$ ]]; then
    bgd_log_error "Missing or invalid environment parameter"
    echo "Usage: $0 [blue|green] [OPTIONS]"
    echo "Example: $0 green --app-name=myapp"
    return 1
  fi

  TARGET_ENV="$1"
  shift

  # Parse command-line parameters
  bgd_parse_parameters "$@" || {
    bgd_log_error "Invalid parameters"
    return 1
  }

  # Check if deploying to non-active environment
  read ACTIVE_ENV INACTIVE_ENV <<< $(bgd_get_environments)

  bgd_log_info "Starting cutover to $TARGET_ENV environment for $APP_NAME"
  
  # Run pre-cutover hook
  bgd_run_hook "pre_cutover" "$TARGET_ENV" || {
    bgd_log_error "Pre-cutover hook failed"
    return 1
  }

  # Check if target environment matches inactive
  if [ "$TARGET_ENV" != "$INACTIVE_ENV" ] && [ "$TARGET_ENV" != "$ACTIVE_ENV" ]; then
    bgd_log_error "Target environment ($TARGET_ENV) doesn't match either active ($ACTIVE_ENV) or inactive ($INACTIVE_ENV) environment"
    return 1
  fi

  # If target is already active, nothing to do
  if [ "$TARGET_ENV" = "$ACTIVE_ENV" ]; then
    bgd_log_info "$TARGET_ENV environment is already active. Nothing to do."
    return 0
  fi

  # Get Docker Compose command
  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)

  # Check if target environment is running
  if ! $DOCKER_COMPOSE -p ${APP_NAME}-${TARGET_ENV} ps 2>/dev/null | grep -q "Up"; then
    bgd_log_error "Target environment ($TARGET_ENV) is not running!"
    return 1
  fi

  # Check health of target environment
  TARGET_PORT=$([[ "$TARGET_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
  HEALTH_URL="http://localhost:${TARGET_PORT}${HEALTH_ENDPOINT}"

  if ! bgd_check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
    bgd_log_error "Target environment is NOT healthy! Aborting cutover."
    return 1
  fi

  # Update nginx to route all traffic to target environment
  bgd_log_info "Updating nginx to route all traffic to $TARGET_ENV environment..."

  # Use the single environment template
  TEMPLATE_DIR="${BGD_SCRIPT_DIR}/../config/templates"
  NGINX_TEMPLATE="${TEMPLATE_DIR}/nginx-single-env.conf.template"

  if [ -f "$NGINX_TEMPLATE" ]; then
    cat "$NGINX_TEMPLATE" | \
      sed -e "s/ENVIRONMENT/$TARGET_ENV/g" | \
      sed -e "s/APP_NAME/$APP_NAME/g" | \
      sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
      sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
      sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT:-443}/g" > nginx.conf
    bgd_log_info "Generated nginx config for $TARGET_ENV environment"
  else
    bgd_log_error "Nginx template file not found at $NGINX_TEMPLATE"
    return 1
  fi

  # Reload nginx configuration
  bgd_log_info "Reloading nginx..."
  $DOCKER_COMPOSE restart nginx || bgd_log_warning "Failed to restart nginx"

  # Stop the previous environment unless --keep-old is specified
  if [ "${KEEP_OLD:-false}" != "true" ]; then
    bgd_log_info "Stopping inactive $ACTIVE_ENV environment..."
    $DOCKER_COMPOSE -p ${APP_NAME}-${ACTIVE_ENV} down || {
      bgd_log_warning "Failed to stop $ACTIVE_ENV environment, continuing anyway"
    }
  else
    bgd_log_info "Keeping previous environment ($ACTIVE_ENV) running as requested"
  fi

  # Run post-cutover hook
  bgd_run_hook "post_cutover" "$TARGET_ENV" || {
    bgd_log_warning "Post-cutover hook failed, continuing anyway"
  }

  bgd_log_success "Cutover completed successfully! All traffic is now routed to the $TARGET_ENV environment."
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_cutover "$@"
  exit $?
fi
