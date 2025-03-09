#!/bin/bash
#
# cleanup.sh - Comprehensive cleanup for blue/green deployment environments
#
# Usage:
#   ./cleanup.sh [OPTIONS]
#
# Options:
#   --all         : Clean up everything including current active environment
#   --failed-only : Clean up only failed deployments
#   --old-only    : Clean up only old, inactive environments
#   --dry-run     : Only show what would be cleaned up without actually removing anything
#   --config=X    : Use alternate config file (default: config.env)

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/common.sh"

# Parse arguments
CLEAN_ALL=false
CLEAN_FAILED=false
CLEAN_OLD=false
DRY_RUN=false
CONFIG_FILE="config.env"

for arg in "$@"; do
  case $arg in
    --all)
      CLEAN_ALL=true
      shift
      ;;
    --failed-only)
      CLEAN_FAILED=true
      shift
      ;;
    --old-only)
      CLEAN_OLD=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --config=*)
      CONFIG_FILE="${arg#*=}"
      shift
      ;;
    *)
      # Unknown option
      log_error "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# Default behavior if no option specified
if [ "$CLEAN_ALL" = false ] && [ "$CLEAN_FAILED" = false ] && [ "$CLEAN_OLD" = false ]; then
  CLEAN_FAILED=true
  CLEAN_OLD=true
fi

# Load configuration
load_config "$CONFIG_FILE"

# Set defaults if not provided
APP_NAME=${APP_NAME:-"app"}

log_info "Starting comprehensive environment cleanup"
if [ "$DRY_RUN" = true ]; then
  log_info "DRY RUN MODE: Only showing what would be cleaned up"
fi

# Function to run command conditionally in dry run mode
run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    log_info "Would run: $*"
  else
    log_info "Running: $*"
    "$@"
  fi
}

# Identify environments
list_environments() {
  docker ps -a --format "{{.Names}}" | grep -E "${APP_NAME}-(blue|green)" | \
    grep -o "${APP_NAME}-\(blue\|green\)" | sort -u || echo ""
}

# Determine which environment is active
get_active_environment() {
  if grep -q "${APP_NAME}-blue" nginx.conf 2>/dev/null; then
    echo "blue"
  elif grep -q "${APP_NAME}-green" nginx.conf 2>/dev/null; then
    echo "green"
  else
    echo ""  # No active environment found
  fi
}

# Clean a specific environment
clean_environment() {
  local env_name="$1"
  log_info "Cleaning environment $env_name"
  
  DOCKER_COMPOSE=$(get_docker_compose_cmd)
  
  if [ "$DRY_RUN" = false ]; then
    $DOCKER_COMPOSE -p "${APP_NAME}-$env_name" down --remove-orphans || log_warning "Failed to clean up environment $env_name"
    rm -f ".env.$env_name" || log_warning "Failed to remove .env.$env_name"
    rm -f "docker-compose.$env_name.yml" || log_warning "Failed to remove docker-compose.$env_name.yml"
  else
    log_info "Would clean up environment $env_name"
  fi
}

ACTIVE_ENV=$(get_active_environment)
if [ -z "$ACTIVE_ENV" ]; then
  log_warning "No active environment detected"
else
  log_info "Detected active environment: $ACTIVE_ENV"
fi

# Get a list of all blue/green environments
ALL_ENVS=$(list_environments | cut -d'-' -f2 || echo "")

# Clean up failed environments (containers in non-running state)
if [ "$CLEAN_FAILED" = true ]; then
  log_info "Cleaning up failed deployments..."
  
  # Find containers in exited or failed state
  FAILED_CONTAINERS=$(docker ps -a --filter "status=exited" --filter "status=dead" \
                      --filter "name=${APP_NAME}-blue|${APP_NAME}-green" --format "{{.Names}}" || echo "")
  
  if [ -n "$FAILED_CONTAINERS" ]; then
    log_info "Found failed containers: $FAILED_CONTAINERS"
    for container in $FAILED_CONTAINERS; do
      ENV_NAME=$(echo "$container" | grep -o "blue\|green")
      if [ "$ENV_NAME" = "$ACTIVE_ENV" ] && [ "$CLEAN_ALL" = false ]; then
        log_warning "Skipping container $container as it belongs to active environment $ACTIVE_ENV"
        continue
      fi
      run_cmd docker rm -f "$container"
    done
  else
    log_info "No failed containers found"
  fi
  
  # Find environments with containers in a mix of running and failed states (partial deployments)
  for env_name in $ALL_ENVS; do
    if [ "$env_name" = "$ACTIVE_ENV" ] && [ "$CLEAN_ALL" = false ]; then
      log_info "Skipping checks for active environment $env_name"
      continue
    fi
    
    TOTAL_CONTAINERS=$(docker ps -a --filter "name=${APP_NAME}-$env_name" | wc -l)
    RUNNING_CONTAINERS=$(docker ps --filter "name=${APP_NAME}-$env_name" | wc -l)
    
    # Account for header row
    TOTAL_CONTAINERS=$((TOTAL_CONTAINERS - 1))
    RUNNING_CONTAINERS=$((RUNNING_CONTAINERS - 1))
    
    if [ "$TOTAL_CONTAINERS" -gt 0 ] && [ "$RUNNING_CONTAINERS" -lt "$TOTAL_CONTAINERS" ]; then
      log_warning "Environment $env_name has partially failed deployment (Running: $RUNNING_CONTAINERS/$TOTAL_CONTAINERS)"
      clean_environment "$env_name"
    fi
  done
fi

# Clean up old inactive environments
if [ "$CLEAN_OLD" = true ]; then
  log_info "Cleaning up old environments..."
  
  for env_name in $ALL_ENVS; do
    if [ "$env_name" = "$ACTIVE_ENV" ] && [ "$CLEAN_ALL" = false ]; then
      log_info "Skipping active environment $env_name"
      continue
    fi
    
    # If environment is not active or we're cleaning everything
    if [ "$env_name" != "$ACTIVE_ENV" ] || [ "$CLEAN_ALL" = true ]; then
      clean_environment "$env_name"
    fi
  done
fi

# Clean up unused Docker resources if not in dry-run mode
if [ "$DRY_RUN" = false ]; then
  log_info "Cleaning up unused Docker resources..."
  
  # Prune images older than 24 hours
  run_cmd docker image prune -af --filter "until=24h"
  
  # Prune unused volumes
  run_cmd docker volume prune -f
  
  # Prune unused networks
  run_cmd docker network prune -f
else
  log_info "Would clean up unused Docker resources (images, volumes, networks)"
fi

# Report status
if [ "$DRY_RUN" = true ]; then
  log_success "Dry run completed. No changes were made."
else
  log_success "Cleanup completed successfully."
fi

# Show current state
log_info "Current environment state:"
docker ps --filter "name=${APP_NAME}"
