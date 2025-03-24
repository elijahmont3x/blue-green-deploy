#!/bin/bash
#
# bgd-rollback.sh - Rolls back to the previous environment
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
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Main rollback function
bgd_rollback() {
  # Parse command-line parameters
  bgd_parse_parameters "$@" || {
    bgd_log_error "Invalid parameters"
    return 1
  }

  bgd_log_info "Starting rollback procedure for $APP_NAME"

  # Run pre-rollback hook
  bgd_run_hook "pre_rollback" || {
    bgd_log_error "Pre-rollback hook failed"
    return 1
  }

  # Determine which environment is currently active and which is standby
  read ACTIVE_ENV ROLLBACK_ENV <<< $(bgd_get_environments)

  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)

  # Check if the rollback environment exists
  # Check if the rollback environment exists without assuming a specific service name
  if ! $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} ps 2>/dev/null | grep -q "Up\|Exit"; then
    bgd_log_error "Rollback environment ($ROLLBACK_ENV) doesn't exist! Cannot rollback."
    return 1
  fi

  bgd_log_info "Active environment: $ACTIVE_ENV, rolling back to: $ROLLBACK_ENV"

  # Check if rollback environment is up; if not, start it
  if ! $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} ps 2>/dev/null | grep -q "Up"; then
    if [ -f ".env.${ROLLBACK_ENV}" ]; then
      bgd_log_info "Starting rollback environment ($ROLLBACK_ENV)..."
      $DOCKER_COMPOSE -p ${APP_NAME}-${ROLLBACK_ENV} --env-file .env.${ROLLBACK_ENV} \
        -f docker-compose.yml -f docker-compose.${ROLLBACK_ENV}.yml up -d
      
      if [ $? -ne 0 ]; then
        bgd_log_error "Failed to start rollback environment"
        return 1
      fi
    else
      bgd_log_error "Rollback environment configuration not found at .env.${ROLLBACK_ENV}"
      return 1
    fi
  fi

  # Check health of rollback environment
  ROLLBACK_PORT=$([[ "$ROLLBACK_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
  HEALTH_URL="http://localhost:${ROLLBACK_PORT}${HEALTH_ENDPOINT}"

  if ! bgd_check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
    if [ "$FORCE_FLAG" = true ]; then
      bgd_log_warning "Rollback environment is NOT healthy, but --force was specified. Proceeding anyway."
    else
      bgd_log_error "Rollback environment is NOT healthy! Aborting rollback. Use --force to override."
      return 1
    fi
  fi

  # Update nginx to route traffic to rollback environment
  bgd_log_info "Updating nginx to route traffic to $ROLLBACK_ENV environment..."

  # Use the single environment template
  TEMPLATE_DIR="${BGD_SCRIPT_DIR}/../config/templates"
  NGINX_TEMPLATE="${TEMPLATE_DIR}/nginx-single-env.conf.template"

  if [ -f "$NGINX_TEMPLATE" ]; then
    cat "$NGINX_TEMPLATE" | \
      sed -e "s/ENVIRONMENT/$ROLLBACK_ENV/g" | \
      sed -e "s/APP_NAME/$APP_NAME/g" | \
      sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
      sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
      sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT:-443}/g" > nginx.conf
    bgd_log_info "Generated nginx config for $ROLLBACK_ENV environment"
  else
    bgd_log_error "Nginx template file not found at $NGINX_TEMPLATE"
    return 1
  fi

  # Reload nginx configuration
  bgd_log_info "Reloading nginx..."
  $DOCKER_COMPOSE restart nginx || bgd_log_warning "Failed to restart nginx"

  # Run post-rollback hook
  bgd_run_hook "post_rollback" "$ROLLBACK_ENV" || {
    bgd_log_warning "Post-rollback hook failed"
    # Continue despite warning
  }

  bgd_log_success "Rollback completed successfully! All traffic is now routed to the $ROLLBACK_ENV environment."
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_rollback "$@"
  exit $?
fi
