#!/bin/bash
#
# bgd-cleanup.sh - Cleans up old or failed deployments
#
# Usage:
#   ./bgd-cleanup.sh [OPTIONS]
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
Blue/Green Deployment System - Cleanup Script
=================================================================

USAGE:
  ./bgd-cleanup.sh [OPTIONS]

REQUIRED OPTIONS:
  --app-name=NAME           Application name

CLEANUP OPTIONS:
  --all                     Clean up everything including current active environment
  --failed-only             Clean up only failed deployments
  --old-only                Clean up only old, inactive environments
  --cleanup-networks        Clean up orphaned networks
  --cleanup-volumes         Clean up volumes (excluding persistent volumes)
  --cleanup-orphans         Clean up orphaned containers
  --cleanup-all-resources   Clean up all resources (networks, volumes, containers)

ADVANCED OPTIONS:
  --dry-run                 Only show what would be cleaned without actually removing anything
  --notify-enabled          Enable notifications

EXAMPLES:
  # Clean up failed deployments
  ./bgd-cleanup.sh --app-name=myapp --failed-only

  # Clean up old environments and orphaned resources
  ./bgd-cleanup.sh --app-name=myapp --old-only --cleanup-orphans

  # Simulate cleaning up all resources
  ./bgd-cleanup.sh --app-name=myapp --cleanup-all-resources --dry-run

=================================================================
EOL
}

# Clean up orphaned containers
bgd_cleanup_orphaned_containers() {
  bgd_log "Cleaning up orphaned containers for ${APP_NAME}" "info"
  
  local orphaned_containers=$(docker ps -a --filter "name=${APP_NAME}" --filter "status=exited" --format "{{.Names}}")
  
  if [ -n "$orphaned_containers" ]; then
    bgd_log "Found orphaned containers: $orphaned_containers" "info"
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log "Would remove orphaned containers" "info"
    else
      # Using xargs for safer handling of container names
      echo "$orphaned_containers" | xargs -r docker rm || bgd_log "Failed to remove some containers" "warning"
      bgd_log "Removed orphaned containers" "success"
    fi
  else
    bgd_log "No orphaned containers found" "info"
  fi
}

# Clean up orphaned networks
bgd_cleanup_orphaned_networks() {
  bgd_log "Cleaning up orphaned networks for ${APP_NAME}" "info"
  
  # Find networks that match app name but exclude the shared network
  local orphaned_networks=$(docker network ls --filter "name=${APP_NAME}" --format "{{.Name}}" | grep -v "${APP_NAME}-shared-network" || true)
  
  if [ -n "$orphaned_networks" ]; then
    bgd_log "Found orphaned networks: $orphaned_networks" "info"
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log "Would remove orphaned networks" "info"
    else
      for network in $orphaned_networks; do
        # Check if network is still in use
        if ! docker network inspect "$network" | grep -q "\"Containers\": {}" 2>/dev/null; then
          bgd_log "Network $network is still in use, skipping removal" "warning"
          continue
        fi
        
        docker network rm "$network" || bgd_log "Failed to remove network $network" "warning"
      done
      bgd_log "Removed orphaned networks" "success"
    fi
  else
    bgd_log "No orphaned networks found" "info"
  fi
}

# Clean up volumes
bgd_cleanup_volumes() {
  bgd_log "Cleaning up volumes for ${APP_NAME}" "info"
  
  # Find volumes that match app name (excluding those we want to keep)
  local app_volumes=$(docker volume ls --filter "name=${APP_NAME}" --format "{{.Name}}" | grep -v "${APP_NAME}-db-data\|${APP_NAME}-redis-data" || true)
  
  if [ -n "$app_volumes" ]; then
    bgd_log "Found volumes: $app_volumes" "info"
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log "Would remove volumes" "info"
    else
      for volume in $app_volumes; do
        docker volume rm "$volume" || bgd_log "Failed to remove volume $volume, it might still be in use" "warning"
      done
      bgd_log "Removed volumes" "success"
    fi
  else
    bgd_log "No application volumes found for cleanup" "info"
  fi
}

# Main cleanup function
bgd_cleanup() {
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

  bgd_log "Starting cleanup for $APP_NAME" "info"

  # Get Docker Compose command
  DOCKER_COMPOSE=$(bgd_get_docker_compose_cmd)

  # Determine which environment is active
  read ACTIVE_ENV INACTIVE_ENV <<< $(bgd_get_environments)
  
  # List all containers for this app
  bgd_log "Listing environments for ${APP_NAME}" "info"
  
  # Collect all project names that match our app name pattern
  PROJECTS=$(docker ps -a --format "{{.Names}}" | grep -E "^${APP_NAME}-(blue|green)" | cut -d- -f2 | sort -u)
  
  if [ -z "$PROJECTS" ]; then
    bgd_log "No environments found for ${APP_NAME}" "info"
    
    # Still clean up orphaned resources if requested
    if [ "${CLEANUP_ORPHANS:-false}" = "true" ] || [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
      bgd_cleanup_orphaned_containers
    fi
    
    if [ "${CLEANUP_NETWORKS:-false}" = "true" ] || [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
      bgd_cleanup_orphaned_networks
    fi
    
    if [ "${CLEANUP_VOLUMES:-false}" = "true" ] || [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
      bgd_cleanup_volumes
    fi
    
    return 0
  fi
  
  # Track what we cleaned
  CLEANED_COUNT=0
  
  # Process each environment
  for ENV in $PROJECTS; do
    # Skip active environment unless --all is specified
    if [ "$ENV" = "$ACTIVE_ENV" ] && [ "${CLEAN_ALL:-false}" != "true" ]; then
      bgd_log "Skipping active environment: ${APP_NAME}-${ENV}" "info"
      continue
    fi
    
    # For --old-only, only clean environments that aren't the active one
    if [ "${CLEAN_OLD:-false}" = "true" ] && [ "$ENV" = "$ACTIVE_ENV" ]; then
      bgd_log "Skipping active environment: ${APP_NAME}-${ENV} (--old-only specified)" "info"
      continue
    fi
    
    # For --failed-only, check if the environment is healthy
    if [ "${CLEAN_FAILED:-false}" = "true" ]; then
      ENV_PORT=$([[ "$ENV" == "blue" ]] && echo "$BLUE_PORT" || echo "$GREEN_PORT")
      HEALTH_URL="http://localhost:${ENV_PORT}${HEALTH_ENDPOINT}"
      
      if curl -s -f -m "$TIMEOUT" "$HEALTH_URL" > /dev/null 2>&1; then
        bgd_log "Skipping healthy environment: ${APP_NAME}-${ENV} (--failed-only specified)" "info"
        continue
      fi
    fi
    
    # Clean this environment
    bgd_log "Cleaning environment: ${APP_NAME}-${ENV}" "info"
    
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log "Would run: $DOCKER_COMPOSE -p ${APP_NAME}-${ENV} down" "info"
    else
      $DOCKER_COMPOSE -p ${APP_NAME}-${ENV} down
      
      # Delete environment file if it exists
      if [ -f ".env.${ENV}" ]; then
        bgd_log "Removing .env.${ENV} file" "info"
        rm -f ".env.${ENV}"
      fi
      
      # Delete docker-compose override if it exists
      if [ -f "docker-compose.${ENV}.yml" ]; then
        bgd_log "Removing docker-compose.${ENV}.yml file" "info"
        rm -f "docker-compose.${ENV}.yml"
      fi
    fi
    
    CLEANED_COUNT=$((CLEANED_COUNT + 1))
  done
  
  # Report results
  if [ $CLEANED_COUNT -gt 0 ]; then
    if [ "${DRY_RUN:-false}" = "true" ]; then
      bgd_log "Would clean $CLEANED_COUNT environment(s)" "success"
    else
      bgd_log "Successfully cleaned $CLEANED_COUNT environment(s)" "success"
    fi
  else
    bgd_log "No environments were cleaned" "info"
  fi
  
  # Clean up orphaned resources if requested
  if [ "${CLEANUP_ORPHANS:-false}" = "true" ] || [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
    bgd_cleanup_orphaned_containers
  fi
  
  if [ "${CLEANUP_NETWORKS:-false}" = "true" ] || [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
    bgd_cleanup_orphaned_networks
  fi
  
  if [ "${CLEANUP_VOLUMES:-false}" = "true" ] || [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
    bgd_cleanup_volumes
  fi
  
  # Clean up shared services if --all is specified
  if [ "${CLEAN_ALL:-false}" = "true" ] && [ "${DRY_RUN:-false}" != "true" ]; then
    bgd_log "Cleaning shared services" "info"
    
    if [ -f "docker-compose.shared.yml" ]; then
      $DOCKER_COMPOSE -f docker-compose.shared.yml down || true
      rm -f docker-compose.shared.yml
    fi
    
    # Check if shared services are running and stop them
    if docker ps --format "{{.Names}}" | grep -q "${APP_NAME}-shared"; then
      bgd_log "Stopping shared services" "info"
      docker stop $(docker ps --format "{{.Names}}" | grep "${APP_NAME}-shared") || true
      docker rm $(docker ps -a --format "{{.Names}}" | grep "${APP_NAME}-shared") || true
    fi
    
    # Clean up networks and volumes if explicitly requested
    if [ "${CLEANUP_ALL_RESOURCES:-false}" = "true" ]; then
      bgd_log "Removing shared network and volumes" "warning"
      docker network rm ${APP_NAME}-shared-network 2>/dev/null || true
      docker volume rm ${APP_NAME}-db-data 2>/dev/null || true
      docker volume rm ${APP_NAME}-redis-data 2>/dev/null || true
    fi
  fi
  
  # Send notification if enabled
  if [ "${NOTIFY_ENABLED:-false}" = "true" ] && [ $CLEANED_COUNT -gt 0 ] && [ "${DRY_RUN:-false}" != "true" ]; then
    bgd_send_notification "Cleaned up $CLEANED_COUNT environment(s) for $APP_NAME" "info"
  fi
  
  return 0
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_cleanup "$@"
  exit $?
fi