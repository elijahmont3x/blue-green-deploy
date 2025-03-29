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

PROFILE OPTIONS:
  --profile=NAME            Specify Docker Compose profile to use (default: env name)
  --services=LIST           Comma-separated list of services to deploy 
                           (all profile services deployed if not specified)
  --include-persistence     Include persistence services in deployment (default: true)

PORT OPTIONS:
  --nginx-port=PORT         Nginx HTTP port (default: 80)
  --nginx-ssl-port=PORT     Nginx HTTPS port (default: 443)
  --blue-port=PORT          Blue environment port (default: 8081)
  --green-port=PORT         Green environment port (default: 8082)
  --auto-port-assignment    Automatically assign available ports

ROUTING OPTIONS:
  --paths=LIST              Path:service:port mappings (comma-separated)
                           Example: "api:backend:3000,dashboard:frontend:80"
  --subdomains=LIST         Subdomain:service:port mappings (comma-separated)
                           Example: "api:backend:3000,team:frontend:80"
  --domain-name=DOMAIN      Domain name for routing
  --domain-aliases=LIST     Additional domain aliases (comma-separated)
  --default-service=NAME    Default service to route root traffic to (default: app)
  --default-port=PORT       Default port for the default service (default: 3000)

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
  # Basic deployment using environment profile
  ./bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
  
  # Deploy specific services with explicit profile
  ./bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp --profile=blue --services=app,api
  
  # Deploy with path-based routing
  ./bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp --paths="api:api:3000,admin:admin:3001"

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
  export ENV_NAME="$TARGET_ENV"

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

  # Set initial traffic weights based on current environment
  if [ "$CURRENT_ENV" = "blue" ]; then
    # Blue is active, green gets no traffic initially
    BLUE_WEIGHT_VALUE=10
    GREEN_WEIGHT_VALUE=0
  else
    # Green is active, blue gets no traffic initially
    BLUE_WEIGHT_VALUE=0
    GREEN_WEIGHT_VALUE=10
  fi
  
  # Create valid nginx.conf BEFORE any containers start
  bgd_create_dual_env_nginx_conf "$BLUE_WEIGHT_VALUE" "$GREEN_WEIGHT_VALUE"

  # Create directory for SSL certificates if it doesn't exist
  bgd_ensure_directory "certs"

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
  # You can override specific service configurations here
  nginx:
    container_name: ${APP_NAME}-${TARGET_ENV}-nginx
    ports:
      - '${NGINX_PORT}:${NGINX_PORT}'
      - '${NGINX_SSL_PORT}:${NGINX_SSL_PORT}'
EOL
  fi

  # Determine which profile to use
  if [ -z "${PROFILE:-}" ]; then
    # If no profile specified, use the target environment name
    PROFILE="$TARGET_ENV"
    bgd_log "No profile specified, using environment name as profile: $PROFILE" "info"
  fi
  
  # Log available profiles if discovery is enabled
  if [ "${AUTO_DISCOVER_PROFILES:-true}" = "true" ] && type bgd_discover_profiles &>/dev/null; then
    local available_profiles=$(bgd_discover_profiles "docker-compose.yml" 2>/dev/null || echo "none")
    bgd_log "Available profiles in docker-compose.yml: $available_profiles" "info"
  fi

  # Process services to deploy
  if [ -z "${SERVICES:-}" ] && [ "${AUTO_DISCOVER_PROFILES:-true}" = "true" ]; then
    # Try to auto-discover services in the profile
    if type bgd_get_profile_services &>/dev/null; then
      SERVICES=$(bgd_get_profile_services "docker-compose.yml" "$PROFILE")
      if [ -n "$SERVICES" ]; then
        SERVICES=$(echo "$SERVICES" | tr '\n' ',' | sed 's/,$//')
        bgd_log "Auto-discovered services for profile '$PROFILE': $SERVICES" "info"
      else
        bgd_log "No services found for profile '$PROFILE' - check your docker-compose.yml configuration" "warning"
      fi
    fi
  fi

  # Log the selected services clearly
  if [ -n "${SERVICES:-}" ]; then
    SERVICE_COUNT=$(echo "$SERVICES" | tr ',' '\n' | wc -l)
    bgd_log "Selected $SERVICE_COUNT services for deployment: $SERVICES" "info"
  else
    bgd_log "No specific services selected, deploying all services in profile '$PROFILE'" "info"
  fi

  # Resolve dependencies if enabled
  if [ -n "${SERVICES:-}" ] && [ "${AUTO_RESOLVE_DEPENDENCIES:-true}" = "true" ]; then
    if type bgd_resolve_dependencies &>/dev/null; then
      bgd_log "Resolving service dependencies..." "info"
      OLD_SERVICES="$SERVICES"
      SERVICES=$(bgd_resolve_dependencies "docker-compose.yml" "$SERVICES")
      
      if [ "$OLD_SERVICES" != "$SERVICES" ]; then
        # Calculate and log the newly added dependencies
        local new_deps=""
        for svc in $(echo "$SERVICES" | tr ',' ' '); do
          if ! echo "$OLD_SERVICES" | grep -q "\b$svc\b"; then
            if [ -n "$new_deps" ]; then
              new_deps="$new_deps, $svc"
            else
              new_deps="$svc"
            fi
          fi
        done
        
        if [ -n "$new_deps" ]; then
          bgd_log "Added dependencies: $new_deps" "info"
        fi
        
        # Log full service list after dependency resolution
        SERVICE_COUNT=$(echo "$SERVICES" | tr ',' '\n' | wc -l)
        bgd_log "Final service list ($SERVICE_COUNT services): $SERVICES" "info"
      else
        bgd_log "No additional dependencies needed for selected services" "info"
      fi
    fi
  fi

  # Prepare Docker Compose command
  COMPOSE_CMD="$DOCKER_COMPOSE -p ${APP_NAME}-${TARGET_ENV} --env-file .env.${TARGET_ENV} -f docker-compose.yml -f $DOCKER_COMPOSE_OVERRIDE"
  
  # Add profile if specified
  if [ -n "${PROFILE:-}" ]; then
    COMPOSE_CMD="$COMPOSE_CMD --profile $PROFILE"
  fi
  
  # Add persistence profile if enabled
  if [ "${INCLUDE_PERSISTENCE:-true}" = "true" ]; then
    COMPOSE_CMD="$COMPOSE_CMD --profile persistence"
  fi
  
  # Add service arguments if specified
  SERVICE_ARGS=""
  if [ -n "${SERVICES:-}" ]; then
    # Convert comma-separated list to space-separated for Docker Compose
    SERVICE_ARGS=$(echo "$SERVICES" | tr ',' ' ')
  fi
  
  # Start the environment
  bgd_log "Starting $TARGET_ENV environment with version $VERSION" "info"
  if [ -n "${SERVICE_ARGS:-}" ]; then
    $COMPOSE_CMD up -d $SERVICE_ARGS || bgd_handle_error "environment_start_failed" "Failed to start $TARGET_ENV environment"
  else
    $COMPOSE_CMD up -d || bgd_handle_error "environment_start_failed" "Failed to start $TARGET_ENV environment"
  fi

  bgd_log "Environment started successfully" "success"
  bgd_log_deployment_event "$VERSION" "environment_started" "success"

  # Run database migrations if enabled
  if [ "${SKIP_MIGRATIONS:-false}" != "true" ]; then
    bgd_log "Running database migrations" "info"
    
    # Default migration command if not specified
    local migrations_cmd="${MIGRATIONS_CMD:-npm run migrate}"
    
    # Find the appropriate container to run migrations on
    local migration_container=""
    
    # Try app container first, then others
    potential_containers=("${APP_NAME}-${TARGET_ENV}-app" "${APP_NAME}-${TARGET_ENV}-api" "${APP_NAME}-${TARGET_ENV}-backend")
    for container in "${potential_containers[@]}"; do
      if docker ps | grep -q "$container"; then
        migration_container="$container"
        break
      fi
    done
    
    if [ -z "$migration_container" ]; then
      bgd_log "No suitable container found for migrations" "warning"
    else
      # Execute migrations within the container
      docker exec -t "$migration_container" sh -c "$migrations_cmd" || 
        bgd_handle_error "database_error" "Database migrations failed"
      
      bgd_log "Database migrations completed successfully" "success"
    fi
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
    
    # Use our core function to update nginx.conf
    bgd_create_dual_env_nginx_conf "$BLUE_WEIGHT_VALUE" "$GREEN_WEIGHT_VALUE"
    
    # Restart nginx to apply configuration
    docker restart "${APP_NAME}-${CURRENT_ENV}-nginx" || bgd_log "Failed to restart nginx" "warning"
    bgd_log "Traffic shifted: blue=$BLUE_WEIGHT_VALUE, green=$GREEN_WEIGHT_VALUE" "info"
    sleep 10
    
    # Traffic shift step 2: 50/50 split
    BLUE_WEIGHT_VALUE=5
    GREEN_WEIGHT_VALUE=5
    
    # Use our core function to update nginx.conf
    bgd_create_dual_env_nginx_conf "$BLUE_WEIGHT_VALUE" "$GREEN_WEIGHT_VALUE"
    
    # Restart nginx to apply configuration
    docker restart "${APP_NAME}-${CURRENT_ENV}-nginx" || bgd_log "Failed to restart nginx" "warning"
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
    
    # Use our core function to update nginx.conf
    bgd_create_dual_env_nginx_conf "$BLUE_WEIGHT_VALUE" "$GREEN_WEIGHT_VALUE"
    
    # Restart nginx to apply configuration
    docker restart "${APP_NAME}-${CURRENT_ENV}-nginx" || bgd_log "Failed to restart nginx" "warning"
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
  
  # Print deployment summary
  bgd_log "===== DEPLOYMENT SUMMARY =====" "info"
  bgd_log "Version: $VERSION" "info"
  bgd_log "Target Environment: $TARGET_ENV" "info"
  bgd_log "Profile: $PROFILE" "info"
  
  # Count deployed services
  local deployed_services_count=0
  if [ -n "${SERVICES:-}" ]; then
    deployed_services_count=$(echo "$SERVICES" | tr ',' '\n' | wc -l)
    bgd_log "Deployed Services: $deployed_services_count ($SERVICES)" "info"
  else
    # Try to count from running containers
    deployed_services_count=$(docker ps --filter "name=${APP_NAME}-${TARGET_ENV}" | wc -l)
    bgd_log "Deployed Services: $deployed_services_count (all profile services)" "info"
  fi
  
  # Check persistence status
  if [ "${INCLUDE_PERSISTENCE:-true}" = "true" ]; then
    local db_status="Not running"
    if docker ps | grep -q "${APP_NAME}-db"; then
      db_status="Running"
    fi
    bgd_log "Persistence Services: Included (Database: $db_status)" "info"
  else
    bgd_log "Persistence Services: Not included" "info"
  fi
  
  # Traffic status
  if [ "${NO_SHIFT:-false}" != "true" ]; then
    bgd_log "Traffic: Gradually shifted to $TARGET_ENV" "info"
  else
    bgd_log "Traffic: No automatic shift (manual cutover required)" "info"
  fi
  
  bgd_log "================================" "info"
  bgd_log "Deployment of version $VERSION to $TARGET_ENV environment completed successfully" "success"
  
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_deploy "$@"
  exit $?
fi