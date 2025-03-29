#!/bin/bash
#
# bgd-cutover.sh - Cuts over traffic to a specific environment
#
# Usage:
#   ./bgd-cutover.sh [blue|green] [OPTIONS]
#
# Required Arguments:
#   [blue|green]           Target environment to cutover to

set -euo pipefail

# Get script directory and load core module
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Display help information
bgd_show_help() {
  cat << EOL
=================================================================
Blue/Green Deployment System - Cutover Script
=================================================================

USAGE:
  ./bgd-cutover.sh [blue|green] [OPTIONS]

ARGUMENTS:
  [blue|green]              Target environment to cutover to (REQUIRED)

REQUIRED OPTIONS:
  --app-name=NAME           Application name

PROFILE OPTIONS:
  --profile=NAME            Specify Docker Compose profile to use (default: env name)

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
  --keep-old                Don't stop the previous environment
  --notify-enabled          Enable notifications

EXAMPLES:
  # Complete cutover to green environment
  ./bgd-cutover.sh green --app-name=myapp

  # Cutover to blue environment with routing configuration
  ./bgd-cutover.sh blue --app-name=myapp --paths="api:api:3000,admin:admin:3001"

=================================================================
EOL
}

# Main cutover function
bgd_cutover() {
  # Check for help flag first
  if [[ "$1" == "--help" ]]; then
    bgd_show_help
    return 0
  fi

  # Parse arguments
  if [ $# -lt 1 ] || [[ ! "$1" =~ ^(blue|green)$ ]]; then
    bgd_log "Missing or invalid environment parameter" "error"
    bgd_show_help
    return 1
  fi

  TARGET_ENV="$1"
  shift

  # Parse command-line parameters
  bgd_parse_parameters "$@"
  
  # Additional validation for required parameters
  if [ -z "${APP_NAME:-}" ]; then
    bgd_handle_error "missing_parameter" "APP_NAME"
    return 1
  fi

  bgd_log "Starting cutover to $TARGET_ENV environment for $APP_NAME" "info"
  
  # Determine which environment is currently active and which is standby
  read ACTIVE_ENV INACTIVE_ENV <<< $(bgd_get_environments)

  # Get Docker Compose command
  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)

  # Check if target environment matches inactive or active
  if [ "$TARGET_ENV" != "$INACTIVE_ENV" ] && [ "$TARGET_ENV" != "$ACTIVE_ENV" ]; then
    bgd_handle_error "invalid_parameter" "Target environment ($TARGET_ENV) doesn't match either active ($ACTIVE_ENV) or inactive ($INACTIVE_ENV) environment"
    return 1
  fi

  # If target is already active, nothing to do
  if [ "$TARGET_ENV" = "$ACTIVE_ENV" ]; then
    bgd_log "$TARGET_ENV environment is already active. Nothing to do." "info"
    return 0
  fi

  # Check if target environment is running
  if ! docker ps | grep -q "${APP_NAME}-${TARGET_ENV}"; then
    bgd_handle_error "environment_start_failed" "Target environment ($TARGET_ENV) is not running"
    return 1
  fi

  # Check health of target environment
  TARGET_PORT=$([[ "$TARGET_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
  HEALTH_URL="http://localhost:${TARGET_PORT}${HEALTH_ENDPOINT}"

  if ! bgd_check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY"; then
    bgd_handle_error "health_check_failed" "Target environment is NOT healthy"
    return 1
  fi

  # Update nginx to route all traffic to target environment
  bgd_log "Updating nginx to route all traffic to $TARGET_ENV environment" "info"

  # Use single-env template for direct routing
  bgd_create_single_env_nginx_conf "$TARGET_ENV"

  # Apply Nginx configuration
  if docker ps | grep -q "${APP_NAME}-${ACTIVE_ENV}-nginx"; then
    # Reload configuration on active nginx
    bgd_log "Reloading nginx on $ACTIVE_ENV" "info"
    docker cp nginx.conf "${APP_NAME}-${ACTIVE_ENV}-nginx:/etc/nginx/nginx.conf"
    docker exec "${APP_NAME}-${ACTIVE_ENV}-nginx" nginx -s reload

    # Allow connections to drain from old configuration
    bgd_log "Allowing connections to drain (5s)..." "info"
    sleep 5
  fi
  
  if docker ps | grep -q "${APP_NAME}-${TARGET_ENV}-nginx"; then
    # Also ensure target environment nginx has the config
    bgd_log "Updating nginx on $TARGET_ENV" "info"
    docker cp nginx.conf "${APP_NAME}-${TARGET_ENV}-nginx:/etc/nginx/nginx.conf"
    docker exec "${APP_NAME}-${TARGET_ENV}-nginx" nginx -s reload
  fi

  # Stop the previous environment unless --keep-old is specified
  if [ "${KEEP_OLD:-false}" != "true" ]; then
    bgd_log "Stopping inactive $ACTIVE_ENV environment" "info"
    
    # Determine profile if specified
    PROFILE_ARGS=""
    if [ -n "${PROFILE:-}" ]; then
      PROFILE_ARGS="--profile $PROFILE"
    fi
    
    $DOCKER_COMPOSE -p "${APP_NAME}-${ACTIVE_ENV}" $PROFILE_ARGS down || {
      bgd_log "Failed to stop $ACTIVE_ENV environment, continuing anyway" "warning"
    }
  else
    bgd_log "Keeping previous environment ($ACTIVE_ENV) running as requested" "info"
  fi

  # Send notification if enabled
  if [ "${NOTIFY_ENABLED:-false}" = "true" ]; then
    bgd_send_notification "Cutover to $TARGET_ENV environment completed successfully" "success"
  fi

  bgd_log "Cutover completed successfully! All traffic is now routed to the $TARGET_ENV environment." "success"
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_cutover "$@"
  exit $?
fi