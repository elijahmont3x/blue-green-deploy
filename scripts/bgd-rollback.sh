#!/bin/bash
#
# bgd-rollback.sh - Rollback utility for Blue/Green Deployment
#
# This script provides rollback functionality for applications deployed with the BGD system,
# allowing quick recovery from failed deployments.

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

OPTIONS:
  --app-name=NAME      Application name
  --force              Force rollback even if inactive environment is unhealthy
  --clean              Clean up the rolled back environment after rollback
  --db-rollback        Roll back database migrations (if applicable)
  --skip-health-check  Skip health check of inactive environment
  --help               Show this help message

EXAMPLES:
  # Rollback myapp to the inactive environment
  ./bgd-rollback.sh --app-name=myapp

  # Force rollback without health checks
  ./bgd-rollback.sh --app-name=myapp --force --skip-health-check

=================================================================
EOL
}

# Perform rollback operation
bgd_perform_rollback() {
  local app_name="$1"
  local force="${2:-false}"
  local db_rollback="${3:-false}"
  local skip_health="${4:-false}"
  
  bgd_log "Starting rollback process for $app_name" "info"
  
  # Load plugins required for rollback
  bgd_load_plugins
  
  # Get current active/inactive environments
  read active_env inactive_env <<< $(bgd_get_environments)
  
  bgd_log "Current active environment: $active_env" "info"
  bgd_log "Rolling back to: $inactive_env" "info"
  
  # Check if inactive environment is healthy
  if [ "$skip_health" != "true" ]; then
    bgd_log "Performing health check on $inactive_env environment" "info"
    
    if ! bgd_check_environment_health "$inactive_env" "$app_name"; then
      if [ "$force" != "true" ]; then
        bgd_log "Inactive environment ($inactive_env) is unhealthy. Use --force to roll back anyway." "error"
        return 1
      else
        bgd_log "Inactive environment ($inactive_env) is unhealthy, but proceeding with rollback due to --force flag" "warning"
      fi
    else
      bgd_log "Inactive environment ($inactive_env) is healthy, proceeding with rollback" "success"
    fi
  else
    bgd_log "Skipping health check as requested" "warning"
  fi
  
  # Call pre-rollback hooks if available
  if declare -F bgd_hook_pre_rollback >/dev/null; then
    bgd_hook_pre_rollback "$inactive_env"
  fi
  
  # Roll back database if requested
  if [ "$db_rollback" = "true" ]; then
    bgd_log "Rolling back database migrations" "info"
    
    # Check if DB migrations plugin is available and source it
    local db_plugin="${BGD_PLUGINS_DIR}/bgd-db-migrations.sh"
    if [ -f "$db_plugin" ]; then
      source "$db_plugin"
      
      # Use the rollback function if available
      if declare -f bgd_rollback_migrations >/dev/null; then
        if ! bgd_rollback_migrations "$inactive_env" "$app_name"; then
          bgd_log "Database rollback failed, but continuing with environment rollback" "warning"
        fi
      else
        bgd_log "Database rollback function not available" "warning"
      fi
    else
      bgd_log "Database migrations plugin not found, skipping database rollback" "warning"
    fi
  fi
  
  # Perform the rollback by directing traffic to inactive environment
  bgd_log "Updating Nginx configuration to point to $inactive_env environment" "info"
  
  # Generate Nginx configuration for single environment
  if ! bgd_create_single_env_nginx_conf "$inactive_env"; then
    bgd_log "Failed to create Nginx configuration" "error"
    return 1
  fi
  
  # Apply the new Nginx configuration
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Restart Nginx container to apply new configuration
  local nginx_container="${app_name}-${active_env}-nginx"
  if docker ps -q --filter "name=$nginx_container" | grep -q .; then
    docker restart "$nginx_container" || {
      bgd_log "Failed to restart Nginx container" "error"
      return 1
    }
  else
    bgd_log "Nginx container not found, trying to use docker-compose" "warning"
    
    # Try to restart with docker-compose
    $docker_compose -p "${app_name}-${active_env}" restart nginx || {
      bgd_log "Failed to restart Nginx with docker-compose" "error"
      return 1
    }
  fi
  
  # Call post-rollback hooks if available
  if declare -F bgd_hook_post_rollback >/dev/null; then
    bgd_hook_post_rollback "$inactive_env"
  fi
  
  # Update environment markers
  bgd_update_environment_markers "$inactive_env"
  
  bgd_log "Rollback to $inactive_env environment completed successfully" "success"
  
  # Log rollback event
  bgd_log_deployment_event "${VERSION:-unknown}" "rollback" "Rolled back to $inactive_env environment"
  
  return 0
}

# Update environment markers to reflect new active environment
bgd_update_environment_markers() {
  local new_active="$1"
  
  # Determine new inactive environment
  local new_inactive=$([ "$new_active" = "blue" ] && echo "green" || echo "blue")
  
  # Update environment markers
  echo "$new_active" > .bgd-active-env
  echo "$new_inactive" > .bgd-inactive-env
  
  bgd_log "Updated environment markers: active=$new_active, inactive=$new_inactive" "info"
}

# Clean up rolled back environment
bgd_cleanup_after_rollback() {
  local app_name="$1"
  
  read active_env inactive_env <<< $(bgd_get_environments)
  
  bgd_log "Cleaning up previous active environment ($inactive_env) after rollback" "info"
  
  # Use cleanup script if available
  local cleanup_script="${BGD_SCRIPT_DIR}/bgd-cleanup.sh"
  
  if [ -f "$cleanup_script" ] && [ -x "$cleanup_script" ]; then
    "$cleanup_script" --app-name="$app_name" --environment="$inactive_env" || {
      bgd_log "Failed to clean up environment $inactive_env" "warning"
      return 1
    }
  else
    bgd_log "Cleanup script not found: $cleanup_script" "warning"
    return 1
  fi
  
  bgd_log "Cleanup completed successfully" "success"
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
  
  # Set defaults for optional parameters
  FORCE="${FORCE:-false}"
  DB_ROLLBACK="${DB_ROLLBACK:-false}"
  SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-false}"
  CLEAN="${CLEAN:-false}"
  
  # Perform rollback
  if bgd_perform_rollback "$APP_NAME" "$FORCE" "$DB_ROLLBACK" "$SKIP_HEALTH_CHECK"; then
    # Clean up if requested
    if [ "$CLEAN" = "true" ]; then
      bgd_cleanup_after_rollback "$APP_NAME"
    fi
    
    bgd_log "Rollback process completed successfully" "success"
    exit 0
  else
    bgd_log "Rollback process failed" "error"
    exit 1
  fi
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_main "$@"
fi