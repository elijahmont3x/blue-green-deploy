#!/bin/bash
#
# bgd-cleanup.sh - Cleans up old or failed deployments
#
# Usage:
#   ./cleanup.sh [OPTIONS]
#
# Options:
#   --app-name=NAME       Application name
#   --all                 Clean up everything including current active environment
#   --failed-only         Clean up only failed deployments
#   --old-only            Clean up only old, inactive environments
#   --dry-run             Only show what would be cleaned without actually removing anything

set -euo pipefail

# Get script directory
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Main cleanup function
bgd_cleanup() {
  # Parse command-line parameters
  bgd_parse_parameters "$@" || {
    bgd_log_error "Invalid parameters"
    return 1
  }

  bgd_log_info "Starting cleanup for $APP_NAME"

  # Run cleanup hook
  bgd_run_hook "cleanup" || {
    bgd_log_warning "Cleanup hook failed, continuing anyway"
  }

  # Get Docker Compose command
  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)

  # Determine which environment is active
  read ACTIVE_ENV INACTIVE_ENV <<< $(bgd_get_environments)
  
  # List all containers for this app
  bgd_log_info "Listing environments for ${APP_NAME}..."
  
  # Collect all project names that match our app name pattern
  PROJECTS=$(docker ps -a --format "{{.Names}}" | grep -E "^${APP_NAME}-(blue|green)" | cut -d- -f2 | sort -u)
  
  if [ -z "$PROJECTS" ]; then
    bgd_log_info "No environments found for ${APP_NAME}"
    return 0
  fi
  
  # Track what we cleaned
  CLEANED_COUNT=0
  
  # Process each environment
  for ENV in $PROJECTS; do
    # Skip active environment unless --all is specified
    if [ "$ENV" = "$ACTIVE_ENV" ] && [ "${CLEAN_ALL:-false}" != "true" ]; then
      bgd_log_info "Skipping active environment: ${APP_NAME}-${ENV}"
      continue
    fi
    
    # For --old-only, only clean environments that aren't the active one
    if [ "${CLEAN_OLD:-false}" = "true" ] && [ "$ENV" = "$ACTIVE_ENV" ]; then
      bgd_log_info "Skipping active environment: ${APP_NAME}-${ENV} (--old-only specified)"
      continue
    fi
    
    # For --failed-only, check if the environment is healthy
    if [ "${CLEAN_FAILED:-false}" = "true" ]; then
      ENV_PORT=$([[ "$ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
      HEALTH_URL="http://localhost:${ENV_PORT}${HEALTH_ENDPOINT}"
      
      if curl -s -f -m "$TIMEOUT" "$HEALTH_URL" > /dev/null 2>&1; then
        bgd_log_info "Skipping healthy environment: ${APP_NAME}-${ENV} (--failed-only specified)"
        continue
      fi
    fi
    
    # Clean this environment
    bgd_log_info "Cleaning environment: ${APP_NAME}-${ENV}"
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log_info "Would run: $DOCKER_COMPOSE -p ${APP_NAME}-${ENV} down"
    else
      $DOCKER_COMPOSE -p ${APP_NAME}-${ENV} down
      
      # Delete environment file if it exists
      if [ -f ".env.${ENV}" ]; then
        bgd_log_info "Removing .env.${ENV} file"
        rm -f ".env.${ENV}"
      fi
      
      # Delete docker-compose override if it exists
      if [ -f "docker-compose.${ENV}.yml" ]; then
        bgd_log_info "Removing docker-compose.${ENV}.yml file"
        rm -f "docker-compose.${ENV}.yml"
      fi
    fi
    
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
  done
  
  # Report results
  if [ $CLEANED_COUNT -gt 0 ]; then
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log_success "Would clean $CLEANED_COUNT environment(s)"
    else
      bgd_log_success "Successfully cleaned $CLEANED_COUNT environment(s)"
    fi
  else
    bgd_log_info "No environments were cleaned"
  fi
  
  # Clean up shared services if --all is specified
  if [ "${CLEAN_ALL:-false}" = "true" ] && [ "${DRY_RUN:-false}" != "true" ]; then
    bgd_log_info "Cleaning shared services..."
    
    if [ -f "docker-compose.shared.yml" ]; then
      $DOCKER_COMPOSE -f docker-compose.shared.yml down || true
      rm -f docker-compose.shared.yml
    fi
    
    # Check if shared services are running and stop them
    if docker ps --format "{{.Names}}" | grep -q "${APP_NAME}-shared"; then
      bgd_log_info "Stopping shared services..."
      docker stop $(docker ps --format "{{.Names}}" | grep "${APP_NAME}-shared") || true
      docker rm $(docker ps -a --format "{{.Names}}" | grep "${APP_NAME}-shared") || true
    fi
    
    # Clean up networks and volumes if explicitly requested
    bgd_log_warning "Removing shared network and volumes..."
    docker network rm ${APP_NAME}-shared-network 2>/dev/null || true
    docker volume rm ${APP_NAME}-db-data 2>/dev/null || true
    docker volume rm ${APP_NAME}-redis-data 2>/dev/null || true
  fi
  
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_cleanup "$@"
  exit $?
fi
