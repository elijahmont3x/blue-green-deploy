#!/bin/bash
#
# bgd-cleanup.sh - Cleanup utility for Blue/Green Deployment
#
# This script cleans up unused environments and resources from BGD deployments

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

OPTIONS:
  --app-name=NAME      Application name
  --environment=ENV    Environment to clean up (blue|green)
                       If not specified, will clean up inactive environment
  --force              Force cleanup even if environment is active
  --keep-volumes       Keep volumes attached to the environment
  --keep-images        Don't remove unused Docker images
  --dry-run            Show what would be done without actually doing it
  --help               Show this help message

EXAMPLES:
  # Clean up inactive environment for myapp
  ./bgd-cleanup.sh --app-name=myapp

  # Clean up green environment for myapp
  ./bgd-cleanup.sh --app-name=myapp --environment=green

  # Perform cleanup simulation
  ./bgd-cleanup.sh --app-name=myapp --dry-run

=================================================================
EOL
}

# Clean up a specific environment
bgd_cleanup_environment() {
  local app_name="$1"
  local env_name="$2"
  local force="${3:-false}"
  local keep_volumes="${4:-false}"
  local keep_images="${5:-false}"
  local dry_run="${6:-false}"
  
  bgd_log "Cleaning up $env_name environment for $app_name" "info"
  
  # Check if the environment is active
  read active_env inactive_env <<< $(bgd_get_environments)
  
  if [ "$env_name" = "$active_env" ] && [ "$force" != "true" ]; then
    bgd_log "Cannot clean up active environment ($env_name). Use --force to override." "error"
    return 1
  elif [ "$env_name" = "$active_env" ]; then
    bgd_log "Cleaning up active environment ($env_name) due to --force flag" "warning"
  fi
  
  # Check if environment exists
  local container_check="${app_name}-${env_name}"
  local any_containers=$(docker ps -a --filter "name=$container_check" --format "{{.Names}}" | wc -l)
  
  if [ "$any_containers" -eq 0 ]; then
    bgd_log "No containers found for $app_name in $env_name environment" "warning"
    # Still continue with other cleanup operations
  fi
  
  # Call pre-cleanup hooks if available
  if declare -F bgd_hook_pre_cleanup >/dev/null; then
    bgd_hook_pre_cleanup "$app_name" "$force" "$env_name"
  fi
  
  # Get Docker Compose command
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Stop and remove containers
  if [ "$dry_run" = "true" ]; then
    bgd_log "[DRY RUN] Would execute: $docker_compose -p \"${app_name}-${env_name}\" down $([ "$keep_volumes" != "true" ] && echo "-v")" "info"
  else
    bgd_log "Stopping and removing containers for ${app_name}-${env_name}" "info"
    $docker_compose -p "${app_name}-${env_name}" down $([ "$keep_volumes" != "true" ] && echo "-v") || {
      bgd_log "Failed to stop containers, continuing with other cleanup operations" "warning"
    }
  fi
  
  # Remove unused networks
  if [ "$dry_run" = "true" ]; then
    bgd_log "[DRY RUN] Would remove unused networks for ${app_name}-${env_name}" "info"
  else
    local network_name="${app_name}-${env_name}-network"
    if docker network ls | grep -q "$network_name"; then
      bgd_log "Removing network: $network_name" "info"
      docker network rm "$network_name" 2>/dev/null || {
        bgd_log "Failed to remove network: $network_name" "warning"
      }
    fi
  fi
  
  # Remove unused volumes if requested
  if [ "$keep_volumes" != "true" ] && [ "$dry_run" != "true" ]; then
    local volume_prefix="${app_name}-${env_name}"
    local volumes=$(docker volume ls -q | grep "^$volume_prefix" || echo "")
    
    if [ -n "$volumes" ]; then
      bgd_log "Removing volumes for ${app_name}-${env_name}" "info"
      for volume in $volumes; do
        bgd_log "Removing volume: $volume" "debug"
        docker volume rm "$volume" 2>/dev/null || {
          bgd_log "Failed to remove volume: $volume, it may be in use" "warning"
        }
      done
    fi
  elif [ "$dry_run" = "true" ] && [ "$keep_volumes" != "true" ]; then
    bgd_log "[DRY RUN] Would remove volumes for ${app_name}-${env_name}" "info"
  fi
  
  # Clean up unused images if requested
  if [ "$keep_images" != "true" ] && [ "$dry_run" != "true" ]; then
    bgd_log "Cleaning up unused Docker images" "info"
    docker image prune -af || {
      bgd_log "Failed to clean up unused Docker images" "warning"
    }
  elif [ "$dry_run" = "true" ] && [ "$keep_images" != "true" ]; then
    bgd_log "[DRY RUN] Would clean up unused Docker images" "info"
  fi
  
  # Call post-cleanup hooks if available
  if declare -F bgd_hook_cleanup >/dev/null; then
    bgd_hook_cleanup "$app_name" "$force" "$env_name"
  fi
  
  bgd_log "Cleanup of $env_name environment for $app_name completed" "success"
  return 0
}

# Main function
bgd_main() {
  # Parse command line arguments
  bgd_parse_parameters "$@"
  
  # Show help if requested
  if [ "${HELP:-false}" = "true" ]; then
    bgd_show_help
    exit 0
  fi
  
  # Validate required parameters
  if [ -z "${APP_NAME:-}" ]; then
    bgd_log "Missing required parameter: APP_NAME" "error"
    bgd_show_help
    exit 1
  fi
  
  # Load plugins
  bgd_load_plugins
  
  # Get active and inactive environments
  read active_env inactive_env <<< $(bgd_get_environments)
  
  # Determine which environment to clean up
  local env_to_clean="${ENVIRONMENT:-$inactive_env}"
  
  # Set defaults for optional parameters
  FORCE="${FORCE:-false}"
  KEEP_VOLUMES="${KEEP_VOLUMES:-false}"
  KEEP_IMAGES="${KEEP_IMAGES:-false}"
  DRY_RUN="${DRY_RUN:-false}"
  
  # Perform cleanup
  if bgd_cleanup_environment "$APP_NAME" "$env_to_clean" "$FORCE" "$KEEP_VOLUMES" "$KEEP_IMAGES" "$DRY_RUN"; then
    # If cleanup was successful, log event
    bgd_log_deployment_event "${VERSION:-unknown}" "cleanup" "Cleaned up $env_to_clean environment for $APP_NAME"
    
    if [ "$DRY_RUN" = "true" ]; then
      bgd_log "Dry run completed. No actual changes were made." "success"
    else
      bgd_log "Cleanup process completed successfully" "success"
    fi
    
    exit 0
  else
    bgd_log "Cleanup process failed" "error"
    exit 1
  fi
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_main "$@"
fi