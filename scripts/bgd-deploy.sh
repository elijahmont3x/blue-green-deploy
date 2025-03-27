#!/bin/bash
#
# bgd-deploy.sh - Main deployment script for Blue/Green Deployment toolkit
#
# Usage:
#   ./bgd-deploy.sh VERSION [OPTIONS]
#
# Required Arguments:
#   VERSION                Version identifier for the deployment

set -euo pipefail

# Get script directory and load core module
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Display help information
bgd_show_help() {
  cat << EOL
=================================================================
Blue/Green Deployment System - Deploy Script
=================================================================

USAGE:
  ./bgd-deploy.sh VERSION [OPTIONS]

ARGUMENTS:
  VERSION                   Version identifier for the deployment (REQUIRED)

REQUIRED OPTIONS:
  --app-name=NAME           Application name
  --image-repo=REPO         Docker image repository

PORT OPTIONS:
  --nginx-port=PORT         Nginx HTTP port (default: 80)
  --nginx-ssl-port=PORT     Nginx HTTPS port (default: 443)
  --blue-port=PORT          Blue environment port (default: 8081)
  --green-port=PORT         Green environment port (default: 8082)
  --auto-port-assignment    Automatically assign available ports

HEALTH CHECK OPTIONS:
  --health-endpoint=PATH    Health check endpoint (default: /health)
  --health-retries=N        Number of health check retries (default: 12)
  --health-delay=SEC        Delay between health checks (default: 5)
  --timeout=SEC             Timeout for health check requests (default: 5)
  --collect-logs            Collect container logs on health check failure
  --max-log-lines=N         Maximum number of log lines to collect (default: 100)
  --retry-backoff           Use exponential backoff for health check retries

DEPLOYMENT OPTIONS:
  --domain-name=DOMAIN      Domain name for multi-domain routing
  --frontend-image-repo=REPO Frontend image repository
  --frontend-version=VER    Frontend version (defaults to same as VERSION)
  --setup-shared            Initialize shared services (database, cache, etc.)
  --skip-migrations         Skip database migrations
  --migrations-cmd=CMD      Custom migrations command
  --force                   Force deployment even if target environment is active
  --no-shift                Don't shift traffic automatically

ADVANCED OPTIONS:
  --auto-rollback           Automatically roll back failed deployments
  --notify-enabled          Enable notifications
  --telegram-bot-token=TOK  Telegram bot token for notifications
  --telegram-chat-id=ID     Telegram chat ID for notifications
  --slack-webhook=URL       Slack webhook URL for notifications

EXAMPLES:
  # Basic deployment
  ./bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
  
  # Deploy with automatic port assignment and rollback
  ./bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp --auto-port-assignment --auto-rollback
  
  # Deploy with notifications
  ./bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp --notify-enabled --telegram-bot-token=TOKEN --telegram-chat-id=ID

=================================================================
EOL
}

# Main deployment function
bgd_deploy() {
  # Check for help flag first
  if [[ "$1" == "--help" ]]; then
    bgd_show_help
    return 0
  fi

  # Parse command-line parameters
  bgd_parse_parameters "$@"
  
  # Additional validation for required parameters
  for param in "APP_NAME" "VERSION" "IMAGE_REPO"; do
    if [ -z "${!param:-}" ]; then
      bgd_handle_error "missing_parameter" "$param"
      return 1
    fi
  done

  bgd_log "Starting deployment of version $VERSION for $APP_NAME" "info"
  bgd_log_deployment_event "$VERSION" "deployment_started" "starting"

  # Automatically assign ports if enabled
  bgd_manage_ports

  # Determine which environment to deploy to (blue or green)
  read CURRENT_ENV TARGET_ENV <<< $(bgd_get_environments)
  bgd_log "Current environment: $CURRENT_ENV, deploying to: $TARGET_ENV" "info"

  # Export TARGET_ENV so it's available for hooks and traffic shifting
  export TARGET_ENV

  # Set port based on target environment
  TARGET_PORT=$([[ "$TARGET_ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")

  # Check if target environment is already running
  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)
  if $DOCKER_COMPOSE -p "${APP_NAME}-${TARGET_ENV}" ps 2>/dev/null | grep -q "Up"; then
    if [ "${FORCE:-false}" = "true" ]; then
      bgd_log "Target environment $TARGET_ENV is already running, stopping it first..." "warning"
      $DOCKER_COMPOSE -p "${APP_NAME}-${TARGET_ENV}" down
    else
      bgd_handle_error "environment_start_failed" "Target environment $TARGET_ENV is already running. Use --force to override."
      return 1
    fi
  fi

  # Initialize shared services if requested
  if [ "${SETUP_SHARED:-false}" = "true" ]; then
    bgd_log "Setting up shared services (database, redis, etc.)" "info"
    
    # Create shared network if it doesn't exist
    if ! docker network inspect "${APP_NAME}-shared-network" &>/dev/null; then
      bgd_log "Creating shared network: ${APP_NAME}-shared-network" "info"
      docker network create "${APP_NAME}-shared-network" || bgd_handle_error "network_error" "Failed to create shared network"
    else
      bgd_log "Shared network already exists" "info"
    fi
    
    # Create shared volumes if they don't exist
    if ! docker volume inspect "${APP_NAME}-db-data" &>/dev/null; then
      bgd_log "Creating database volume: ${APP_NAME}-db-data" "info"
      docker volume create "${APP_NAME}-db-data" || bgd_handle_error "docker_error" "Failed to create database volume"
    fi
    
    if ! docker volume inspect "${APP_NAME}-redis-data" &>/dev/null; then
      bgd_log "Creating Redis volume: ${APP_NAME}-redis-data" "info"
      docker volume create "${APP_NAME}-redis-data" || bgd_handle_error "docker_error" "Failed to create Redis volume"
    fi
    
    # Start shared services
    bgd_log "Starting shared services" "info"
    
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
    
    $DOCKER_COMPOSE -f docker-compose.yml -f docker-compose.shared.yml --profile shared up -d || 
      bgd_handle_error "environment_start_failed" "Failed to start shared services"
    
    bgd_log "Shared services started successfully" "success"
    sleep 5  # Allow services to initialize
  fi

  # Create secure environment file for the target environment
  bgd_create_secure_env_file "$TARGET_ENV" "$TARGET_PORT"

  # Generate environment-specific docker-compose overrides
  bgd_log "Generating Docker Compose override for $TARGET_ENV environment" "info"
  DOCKER_COMPOSE_TEMPLATE="${BGD_TEMPLATES_DIR}/docker-compose.override.template"
  DOCKER_COMPOSE_OVERRIDE="docker-compose.${TARGET_ENV}.yml"

  if [ -f "$DOCKER_COMPOSE_TEMPLATE" ]; then
    # Use template if available
    cat "$DOCKER_COMPOSE_TEMPLATE" | \
      sed -e "s/{{ENV_NAME}}/$TARGET_ENV/g" | \
      sed -e "s/{{PORT}}/$TARGET_PORT/g" > "$DOCKER_COMPOSE_OVERRIDE"
  else
    # Create a minimal override if template not found
    bgd_log "Docker Compose template not found, creating minimal override" "warning"
    cat > "$DOCKER_COMPOSE_OVERRIDE" << EOL
# Generated environment-specific overrides for $TARGET_ENV environment
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
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
EOL
  fi

  # Generate initial nginx configuration
  bgd_log "Generating Nginx configuration" "info"
  NGINX_TEMPLATE="${BGD_TEMPLATES_DIR}/nginx-multi-domain.conf.template"
  if [ ! -f "$NGINX_TEMPLATE" ]; then
    NGINX_TEMPLATE="${BGD_TEMPLATES_DIR}/nginx-dual-env.conf.template"
  fi
  
  if [ ! -f "$NGINX_TEMPLATE" ]; then
    bgd_handle_error "file_not_found" "Nginx template file not found in templates directory"
    return 1
  fi
  
  # Set initial traffic weights
  if [ "$CURRENT_ENV" = "blue" ]; then
    # Blue is active, green gets no traffic initially
    BLUE_WEIGHT_VALUE=10
    GREEN_WEIGHT_VALUE=0
  else
    # Green is active, blue gets no traffic initially
    BLUE_WEIGHT_VALUE=0
    GREEN_WEIGHT_VALUE=10
  fi
  
  # Create the nginx.conf file before starting any containers
  cat "$NGINX_TEMPLATE" | \
    sed -e "s/BLUE_WEIGHT/$BLUE_WEIGHT_VALUE/g" | \
    sed -e "s/GREEN_WEIGHT/$GREEN_WEIGHT_VALUE/g" | \
    sed -e "s/APP_NAME/$APP_NAME/g" | \
    sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
    sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
    sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT}/g" > "nginx.conf"

  if [ ! -f "nginx.conf" ] || [ ! -s "nginx.conf" ]; then
    bgd_handle_error "file_not_found" "Failed to create nginx.conf file"
    return 1
  fi

  # Create directory for SSL certificates if it doesn't exist
  bgd_ensure_directory "certs"

  # Start the new environment
  bgd_log "Starting $TARGET_ENV environment with version $VERSION" "info"
  $DOCKER_COMPOSE -p "${APP_NAME}-${TARGET_ENV}" --env-file ".env.${TARGET_ENV}" \
    -f docker-compose.yml -f "$DOCKER_COMPOSE_OVERRIDE" up -d || 
    bgd_handle_error "environment_start_failed" "Failed to start $TARGET_ENV environment"

  bgd_log "Environment started successfully" "success"
  bgd_log_deployment_event "$VERSION" "environment_started" "success"

  # Run database migrations if enabled
  if [ "${SKIP_MIGRATIONS:-false}" != "true" ]; then
    bgd_log "Running database migrations" "info"
    
    # Default migration command if not specified
    local migrations_cmd="${MIGRATIONS_CMD:-npm run migrate}"
    
    # Execute migrations within the container
    $DOCKER_COMPOSE -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c "$migrations_cmd" || 
      bgd_handle_error "database_error" "Database migrations failed"
    
    bgd_log "Database migrations completed successfully" "success"
  else
    bgd_log "Skipping database migrations as requested" "info"
  fi

  # Verify environment health
  bgd_log "Verifying $TARGET_ENV environment health" "info"
  
  # Check application health endpoint
  HEALTH_URL="http://localhost:${TARGET_PORT}${HEALTH_ENDPOINT}"
  if ! bgd_check_health "$HEALTH_URL" "$HEALTH_RETRIES" "$HEALTH_DELAY" "$TIMEOUT"; then
    $DOCKER_COMPOSE -p "${APP_NAME}-${TARGET_ENV}" logs --tail="${MAX_LOG_LINES:-100}"
    bgd_handle_error "health_check_failed" "Application health check failed for $TARGET_ENV environment"
    return 1
  fi
  
  # Verify all services in the environment
  if ! bgd_verify_environment_health "$TARGET_ENV"; then
    bgd_handle_error "health_check_failed" "Not all services are healthy in $TARGET_ENV environment"
    return 1
  fi
  
  bgd_log_deployment_event "$VERSION" "health_check_passed" "success"

  # Gradually shift traffic if auto-shift is enabled
  if [ "${NO_SHIFT:-false}" != "true" ]; then
    bgd_log "Gradually shifting traffic to $TARGET_ENV environment" "info"
    
    # Traffic shift step 1: 90/10 split
    if [ "$CURRENT_ENV" = "blue" ]; then
      # Blue is active, shift 10% to green
      BLUE_WEIGHT_VALUE=9
      GREEN_WEIGHT_VALUE=1
    else
      # Green is active, shift 10% to blue
      BLUE_WEIGHT_VALUE=1
      GREEN_WEIGHT_VALUE=9
    fi
    
    cat "$NGINX_TEMPLATE" | \
      sed -e "s/BLUE_WEIGHT/$BLUE_WEIGHT_VALUE/g" | \
      sed -e "s/GREEN_WEIGHT/$GREEN_WEIGHT_VALUE/g" | \
      sed -e "s/APP_NAME/$APP_NAME/g" | \
      sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
      sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
      sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT}/g" > "nginx.conf"
    
    # Restart nginx to apply configuration
    $DOCKER_COMPOSE restart nginx || bgd_log "Failed to restart nginx" "warning"
    bgd_log "Traffic shifted: blue=$BLUE_WEIGHT_VALUE, green=$GREEN_WEIGHT_VALUE" "info"
    sleep 10
    
    # Traffic shift step 2: 50/50 split
    BLUE_WEIGHT_VALUE=5
    GREEN_WEIGHT_VALUE=5
    
    cat "$NGINX_TEMPLATE" | \
      sed -e "s/BLUE_WEIGHT/$BLUE_WEIGHT_VALUE/g" | \
      sed -e "s/GREEN_WEIGHT/$GREEN_WEIGHT_VALUE/g" | \
      sed -e "s/APP_NAME/$APP_NAME/g" | \
      sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
      sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
      sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT}/g" > "nginx.conf"
    
    # Restart nginx to apply configuration
    $DOCKER_COMPOSE restart nginx || bgd_log "Failed to restart nginx" "warning"
    bgd_log "Traffic shifted: blue=$BLUE_WEIGHT_VALUE, green=$GREEN_WEIGHT_VALUE" "info"
    sleep 10
    
    # Traffic shift step 3: 10/90 split favoring new environment
    if [ "$CURRENT_ENV" = "blue" ]; then
      # Blue is active, shift 90% to green
      BLUE_WEIGHT_VALUE=1
      GREEN_WEIGHT_VALUE=9
    else
      # Green is active, shift 90% to blue
      BLUE_WEIGHT_VALUE=9
      GREEN_WEIGHT_VALUE=1
    fi
    
    cat "$NGINX_TEMPLATE" | \
      sed -e "s/BLUE_WEIGHT/$BLUE_WEIGHT_VALUE/g" | \
      sed -e "s/GREEN_WEIGHT/$GREEN_WEIGHT_VALUE/g" | \
      sed -e "s/APP_NAME/$APP_NAME/g" | \
      sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
      sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
      sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT}/g" > "nginx.conf"
    
    # Restart nginx to apply configuration
    $DOCKER_COMPOSE restart nginx || bgd_log "Failed to restart nginx" "warning"
    bgd_log "Traffic shifted: blue=$BLUE_WEIGHT_VALUE, green=$GREEN_WEIGHT_VALUE" "info"
    
    bgd_log "Traffic gradually shifted to new $TARGET_ENV environment" "success"
    bgd_log "Run './scripts/bgd-cutover.sh $TARGET_ENV --app-name=$APP_NAME' to complete the cutover" "info"
  else
    bgd_log "Automatic traffic shifting is disabled" "info"
    bgd_log "Run './scripts/bgd-cutover.sh $TARGET_ENV --app-name=$APP_NAME' when ready to shift traffic" "info"
  fi

  # Send notification if enabled
  if [ "${NOTIFY_ENABLED:-false}" = "true" ]; then
    bgd_send_notification "Deployment of version $VERSION to $TARGET_ENV environment completed successfully" "success"
  fi

  bgd_log_deployment_event "$VERSION" "deployment_completed" "success"
  bgd_log "Deployment of version $VERSION to $TARGET_ENV environment completed successfully" "success"
  
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_deploy "$@"
  exit $?
fi