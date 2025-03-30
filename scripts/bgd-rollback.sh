#!/bin/bash
#
# bgd-rollback.sh - Rolls back to the previous environment
#
# Usage:
#   ./bgd-rollback.sh [OPTIONS]
#
# Options:
#   --app-name=NAME         Application name (REQUIRED)

set -euo pipefail

# Get script directory and load core module
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Display help information
bgd_show_help() {
  cat << EOL
=================================================================
Blue/Green Deployment System - Rollback Script
=================================================================

USAGE:
  ./bgd-rollback.sh [OPTIONS]

REQUIRED OPTIONS:
  --app-name=NAME           Application name

PROFILE OPTIONS:
  --profile=NAME            Specify Docker Compose profile to use (default: env name)
  --services=LIST           Comma-separated list of services to start during rollback

ROUTING OPTIONS:
  --paths=LIST              Path:service:port mappings (comma-separated)
                           Example: "api:backend:3000,dashboard:frontend:80"
  --subdomains=LIST         Subdomain:service:port mappings (comma-separated)
                           Example: "api:backend:3000,team:frontend:80"
  --domain-name=DOMAIN      Domain name for routing
  --domain-aliases=LIST     Additional domain aliases (comma-separated)

CONFIGURATION OPTIONS:
  --nginx-port=PORT         Nginx external port (default: 80)
  --nginx-ssl-port=PORT     Nginx HTTPS port (default: 443)
  --blue-port=PORT          Blue environment port (default: 8081)
  --green-port=PORT         Green environment port (default: 8082)

HEALTH CHECK OPTIONS:
  --health-endpoint=PATH    Health check endpoint (default: /health)
  --health-retries=N        Number of health check retries (default: 12)
  --health-delay=SEC        Delay between health checks (default: 5)

ADVANCED OPTIONS:
  --force                   Force rollback even if environment is unhealthy
  --notify-enabled          Enable notifications

EXAMPLES:
  # Standard rollback
  ./bgd-rollback.sh --app-name=myapp

  # Rollback with specific profile and services
  ./bgd-rollback.sh --app-name=myapp --profile=blue --services=app,api

=================================================================
EOL
}

# Main rollback function
bgd_rollback() {
  # Check for help flag first
  if [[ "$1" == "--help" ]]; then
    bgd_show_help
    return 0
  fi

  # Parse command-line parameters
  bgd_parse_parameters "$@"
  
  # Additional validation for required parameters
  if [ -z "${APP_NAME:-}" ]; then
    bgd_handle_error "missing_parameter" "APP_NAME"
    return 1
  fi

  bgd_log "Starting rollback procedure for $APP_NAME" "info"

  # Determine which environment is currently active and which is standby
  read ACTIVE_ENV ROLLBACK_ENV <<< $(bgd_get_environments)

  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)

  # Check if the rollback environment exists
  if ! [ -f ".env.${ROLLBACK_ENV}" ]; then
    bgd_handle_error "file_not_found" "Rollback environment configuration not found (.env.${ROLLBACK_ENV})"
    return 1
  fi

  bgd_log "Active environment: $ACTIVE_ENV, rolling back to: $ROLLBACK_ENV" "info"

  # Check if rollback environment is up; if not, start it
  if ! docker ps | grep -q "${APP_NAME}-${ROLLBACK_ENV}"; then
    # Get deployment command for the rollback environment
    local deploy_cmd=$(bgd_get_deployment_cmd "$ROLLBACK_ENV" ".env.${ROLLBACK_ENV}" "$PROFILE" "$additional_profiles")
    
    bgd_log "Starting rollback environment ($ROLLBACK_ENV)" "info"
    
    # Start the environment with profiles or services
    if [ -n "${SERVICES:-}" ]; then
      # Convert comma-separated to space-separated for Docker Compose
      local service_args=$(echo "$SERVICES" | tr ',' ' ')
      eval "$deploy_cmd up -d $service_args" || 
        bgd_handle_error "environment_start_failed" "Failed to start rollback environment"
    else
      eval "$deploy_cmd up -d" || 
        bgd_handle_error "environment_start_failed" "Failed to start rollback environment"
    fi
  fi

  # Check health of rollback environment
  ROLLBACK_PORT=$([[ "$ROLLBACK_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
  HEALTH_URL="http://localhost:${ROLLBACK_PORT}${HEALTH_ENDPOINT}"

  if ! bgd_check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
    if [ "${FORCE:-false}" = "true" ]; then
      bgd_log "Rollback environment is NOT healthy, but --force was specified. Proceeding anyway." "warning"
    else
      bgd_handle_error "health_check_failed" "Rollback environment is NOT healthy"
      return 1
    fi
  fi

  # Update nginx to route traffic to rollback environment
  bgd_log "Updating nginx to route traffic to $ROLLBACK_ENV environment" "info"

  # Use single-env template for direct routing 
  bgd_create_single_env_nginx_conf "$ROLLBACK_ENV"

  # Apply Nginx configuration
  local active_nginx=$(docker ps --format "{{.Names}}" | grep "${APP_NAME}-${ACTIVE_ENV}-nginx" | head -n1)
  if [ -n "$active_nginx" ]; then
    # Reload configuration on active nginx
    bgd_log "Reloading nginx on $ACTIVE_ENV" "info"
    docker cp nginx.conf "$active_nginx:/etc/nginx/nginx.conf"
    docker exec "$active_nginx" nginx -s reload
  fi
  
  local rollback_nginx=$(docker ps --format "{{.Names}}" | grep "${APP_NAME}-${ROLLBACK_ENV}-nginx" | head -n1)
  if [ -n "$rollback_nginx" ]; then
    # Also ensure rollback environment nginx has the config
    bgd_log "Updating nginx on $ROLLBACK_ENV" "info"
    docker cp nginx.conf "$rollback_nginx:/etc/nginx/nginx.conf"
    docker exec "$rollback_nginx" nginx -s reload
  fi

  # Send notification if enabled
  if [ "${NOTIFY_ENABLED:-false}" = "true" ]; then
    bgd_send_notification "Rollback to $ROLLBACK_ENV environment completed" "warning"
  fi

  bgd_log "Rollback completed successfully! All traffic is now routed to the $ROLLBACK_ENV environment." "success"
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_rollback "$@"
  exit $?
fi