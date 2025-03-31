#!/bin/bash
#
# bgd-cutover.sh - Traffic cutover utility for Blue/Green Deployment
#
# This script manages traffic shifting between blue and green environments,
# supporting both immediate cutover and gradual shifting strategies.

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
  ./bgd-cutover.sh [OPTIONS]

OPTIONS:
  --app-name=NAME      Application name
  --target=ENV         Target environment to cut over to (blue|green)
  --gradual            Use gradual traffic shifting instead of immediate cutover
  --initial-weight=N   Initial traffic weight for target environment (default: 10)
  --step=N             Weight increase per step for gradual shifting (default: 10)
  --interval=SEC       Seconds between weight adjustments (default: 60)
  --skip-health-check  Skip health check of target environment
  --force              Force cutover even if target environment is unhealthy
  --help               Show this help message

EXAMPLES:
  # Immediate cutover to green environment
  ./bgd-cutover.sh --app-name=myapp --target=green

  # Gradual cutover to green environment over 5 minutes
  ./bgd-cutover.sh --app-name=myapp --target=green --gradual --step=20 --interval=60

=================================================================
EOL
}

# Perform immediate cutover
bgd_immediate_cutover() {
  local app_name="$1"
  local target_env="$2"
  
  bgd_log "Performing immediate cutover to $target_env environment" "info"
  
  # Create single-environment Nginx configuration
  if ! bgd_create_single_env_nginx_conf "$target_env"; then
    bgd_log "Failed to create Nginx configuration" "error"
    return 1
  fi
  
  # Apply new configuration by restarting Nginx
  local nginx_container="${app_name}-${target_env}-nginx"
  
  # Try several container name formats since there might be inconsistency
  if docker ps -q --filter "name=${nginx_container}$" | grep -q .; then
    docker restart "$nginx_container" || {
      bgd_log "Failed to restart Nginx container" "error"
      return 1
    }
  elif docker ps -q --filter "name=${app_name}-nginx" | grep -q .; then
    # Try alternative naming format
    docker restart "${app_name}-nginx" || {
      bgd_log "Failed to restart Nginx container" "error"
      return 1
    }
  else
    # Try with docker-compose
    local docker_compose=$(bgd_get_docker_compose_cmd)
    $docker_compose -p "${app_name}-${target_env}" restart nginx || {
      bgd_log "Failed to restart Nginx with docker-compose" "error"
      return 1
    }
  fi
  
  # Update environment markers
  echo "$target_env" > "${BGD_BASE_DIR}/.bgd-active-env"
  local other_env=$([ "$target_env" = "blue" ] && echo "green" || echo "blue")
  echo "$other_env" > "${BGD_BASE_DIR}/.bgd-inactive-env"
  
  bgd_log "Cutover to $target_env completed successfully" "success"
  return 0
}

# Perform gradual traffic shifting
bgd_gradual_cutover() {
  local app_name="$1"
  local target_env="$2"
  local initial_weight="${3:-10}"
  local step="${4:-10}"
  local interval="${5:-60}"
  
  bgd_log "Performing gradual cutover to $target_env environment" "info"
  bgd_log "Initial weight: $initial_weight%, Step: $step%, Interval: ${interval}s" "info"
  
  # Determine other environment
  local other_env=$([ "$target_env" = "blue" ] && echo "green" || echo "blue")
  
  # Calculate number of steps
  local target_weight="$initial_weight"
  local other_weight=$((100 - target_weight))
  local steps=$(( (100 - initial_weight) / step ))
  
  # Create initial weighted configuration
  bgd_log "Setting initial weights - $target_env: $target_weight%, $other_env: $other_weight%" "info"
  
  if ! bgd_create_dual_env_nginx_conf \
        $([ "$target_env" = "blue" ] && echo "$target_weight" || echo "$other_weight") \
        $([ "$target_env" = "blue" ] && echo "$other_weight" || echo "$target_weight"); then
    bgd_log "Failed to create initial Nginx configuration" "error"
    return 1
  fi
  
  # Apply initial configuration
  local nginx_container="${app_name}-nginx"
  local project_nginx_container=""
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Try to determine nginx container or restart method
  if docker ps -q --filter "name=$nginx_container" | grep -q .; then
    docker restart "$nginx_container" || {
      bgd_log "Failed to restart Nginx container" "error"
      return 1
    }
  else
    # Try with project-based container name
    read active_env inactive_env <<< $(bgd_get_environments)
    project_nginx_container="${app_name}-${active_env}-nginx"
    
    if docker ps -q --filter "name=$project_nginx_container" | grep -q .; then
      docker restart "$project_nginx_container" || {
        bgd_log "Failed to restart Nginx container" "error"
        return 1
      }
    else
      # Fall back to docker-compose
      $docker_compose -p "${app_name}-${active_env}" restart nginx || {
        bgd_log "Failed to restart Nginx with docker-compose" "error"
        return 1
      }
    fi
  fi
  
  # Gradually increase weight for target environment
  for (( i=1; i<=steps; i++ )); do
    # Sleep for the specified interval
    bgd_log "Waiting ${interval}s before next weight adjustment" "info"
    sleep "$interval"
    
    # Calculate new weights
    target_weight=$((initial_weight + (i * step)))
    other_weight=$((100 - target_weight))
    
    # Ensure weights don't exceed 100%
    if [ "$target_weight" -gt 100 ]; then target_weight=100; fi
    if [ "$other_weight" -lt 0 ]; then other_weight=0; fi
    
    bgd_log "Adjusting weights - $target_env: $target_weight%, $other_env: $other_weight%" "info"
    
    # Create updated configuration
    if ! bgd_create_dual_env_nginx_conf \
          $([ "$target_env" = "blue" ] && echo "$target_weight" || echo "$other_weight") \
          $([ "$target_env" = "blue" ] && echo "$other_weight" || echo "$target_weight"); then
      bgd_log "Failed to create updated Nginx configuration" "error"
      return 1
    fi
    
    # Apply updated configuration
    if [ -n "$project_nginx_container" ] && docker ps -q --filter "name=$project_nginx_container" | grep -q .; then
      docker exec "$project_nginx_container" nginx -s reload || {
        bgd_log "Failed to reload Nginx configuration, trying restart" "warning"
        docker restart "$project_nginx_container" || {
          bgd_log "Failed to restart Nginx container" "error"
          return 1
        }
      }
    elif docker ps -q --filter "name=$nginx_container" | grep -q .; then
      docker exec "$nginx_container" nginx -s reload || {
        bgd_log "Failed to reload Nginx configuration, trying restart" "warning"
        docker restart "$nginx_container" || {
          bgd_log "Failed to restart Nginx container" "error"
          return 1
        }
      }
    else
      # Fall back to docker-compose restart
      $docker_compose -p "${app_name}-${active_env}" restart nginx || {
        bgd_log "Failed to restart Nginx with docker-compose" "error"
        return 1
      }
    fi
  done
  
  # Final cutover - create single environment configuration for clean state
  bgd_log "Performing final cutover to 100% $target_env" "info"
  
  if ! bgd_create_single_env_nginx_conf "$target_env"; then
    bgd_log "Failed to create final Nginx configuration" "error"
    return 1
  fi
  
  # Apply final configuration
  if [ -n "$project_nginx_container" ] && docker ps -q --filter "name=$project_nginx_container" | grep -q .; then
    docker restart "$project_nginx_container" || {
      bgd_log "Failed to restart Nginx container" "error"
      return 1
    }
  elif docker ps -q --filter "name=$nginx_container" | grep -q .; then
    docker restart "$nginx_container" || {
      bgd_log "Failed to restart Nginx container" "error"
      return 1
    }
  else
    # Fall back to docker-compose restart
    $docker_compose -p "${app_name}-${active_env}" restart nginx || {
      bgd_log "Failed to restart Nginx with docker-compose" "error"
      return 1
    }
  fi
  
  # Update environment markers
  echo "$target_env" > .bgd-active-env
  echo "$other_env" > .bgd-inactive-env
  
  bgd_log "Gradual cutover to $target_env completed successfully" "success"
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
  
  if [ -z "${TARGET:-}" ]; then
    bgd_log "Missing required parameter: TARGET" "error"
    bgd_show_help
    exit 1
  fi
  
  # Validate target environment
  if [ "$TARGET" != "blue" ] && [ "$TARGET" != "green" ]; then
    bgd_log "Invalid target environment: $TARGET. Must be 'blue' or 'green'" "error"
    exit 1
  fi
  
  # Set defaults for optional parameters
  GRADUAL="${GRADUAL:-false}"
  INITIAL_WEIGHT="${INITIAL_WEIGHT:-10}"
  STEP="${STEP:-10}"
  INTERVAL="${INTERVAL:-60}"
  SKIP_HEALTH_CHECK="${SKIP_HEALTH_CHECK:-false}"
  FORCE="${FORCE:-false}"
  
  # Check if target environment is healthy
  if [ "$SKIP_HEALTH_CHECK" != "true" ]; then
    bgd_log "Performing health check on $TARGET environment" "info"
    
    if ! bgd_check_environment_health "$TARGET" "$APP_NAME"; then
      if [ "$FORCE" != "true" ]; then
        bgd_log "Target environment ($TARGET) is unhealthy. Use --force to cut over anyway." "error"
        exit 1
      else
        bgd_log "Target environment ($TARGET) is unhealthy, but proceeding with cutover due to --force flag" "warning"
      fi
    else
      bgd_log "Target environment ($TARGET) is healthy, proceeding with cutover" "success"
    fi
  else
    bgd_log "Skipping health check as requested" "warning"
  fi
  
  # Hook before cutover
  if declare -F bgd_hook_pre_cutover >/dev/null; then
    bgd_hook_pre_cutover "$TARGET" || {
      bgd_log "Pre-cutover hook failed" "warning"
    }
  fi
  
  # Load plugins
  bgd_load_plugins
  
  # Perform cutover
  if [ "$GRADUAL" = "true" ]; then
    if ! bgd_gradual_cutover "$APP_NAME" "$TARGET" "$INITIAL_WEIGHT" "$STEP" "$INTERVAL"; then
      bgd_log "Gradual cutover failed" "error"
      exit 1
    fi
  else
    if ! bgd_immediate_cutover "$APP_NAME" "$TARGET"; then
      bgd_log "Immediate cutover failed" "error"
      exit 1
    fi
  fi
  
  # Hook after cutover
  if declare -F bgd_hook_post_cutover >/dev/null; then
    bgd_hook_post_cutover "$TARGET" || {
      bgd_log "Post-cutover hook failed" "warning"
    }
  fi
  
  bgd_log "Cutover process completed successfully" "success"
  
  # Log deployment event
  bgd_log_deployment_event "${VERSION:-unknown}" "cutover" "Performed $([ "$GRADUAL" = "true" ] && echo "gradual" || echo "immediate") cutover to $TARGET environment"
  
  exit 0
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_main "$@"
fi