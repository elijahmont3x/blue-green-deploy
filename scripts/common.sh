#!/bin/bash
set -euo pipefail

# Description: Utility functions for deployment scripts
# 
# This file contains common functions used across the blue/green deployment system.
# It handles parameter parsing, logging, environment management, and other utilities.

# Define logs directory
LOGS_DIR="./logs"

# Logging functions
log_info() {
  echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_warning() {
  echo -e "\033[0;33m[WARN]\033[0m $1"
}

log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $1"
}

log_success() {
  echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

# Parse command-line parameters
# 
# Example usage:
#   parse_parameters "$@"
#   echo "App name: $APP_NAME"
#
# Returns:
#   0 if successful, 1 if invalid parameters
parse_parameters() {
  while [[ "$#" -gt 0 ]]; do
    case $1 in
      --app-name=*) APP_NAME="${1#*=}" ;;
      --image-repo=*) IMAGE_REPO="${1#*=}" ;;
      --frontend-image-repo=*) FRONTEND_IMAGE_REPO="${1#*=}" ;;
      --frontend-version=*) FRONTEND_VERSION="${1#*=}" ;;
      --domain-name=*) DOMAIN_NAME="${1#*=}" ;;
      --nginx-port=*) NGINX_PORT="${1#*=}" ;;
      --nginx-ssl-port=*) NGINX_SSL_PORT="${1#*=}" ;;
      --blue-port=*) BLUE_PORT="${1#*=}" ;;
      --green-port=*) GREEN_PORT="${1#*=}" ;;
      --health-endpoint=*) HEALTH_ENDPOINT="${1#*=}" ;;
      --health-retries=*) HEALTH_RETRIES="${1#*=}" ;;
      --health-delay=*) HEALTH_DELAY="${1#*=}" ;;
      --timeout=*) TIMEOUT="${1#*=}" ;;
      --database-url=*) DATABASE_URL="${1#*=}" ;;
      --api-key=*) API_KEY="${1#*=}" ;;
      --redis-url=*) REDIS_URL="${1#*=}" ;;
      --setup-shared) SETUP_SHARED=true ;;
      --skip-migrations) SKIP_MIGRATIONS=true ;;
      --migrations-cmd=*) MIGRATIONS_CMD="${1#*=}" ;;
      --force) FORCE_FLAG=true ;;
      --no-shift) NO_SHIFT=true ;;
      --all) CLEAN_ALL=true ;;
      --failed-only) CLEAN_FAILED=true ;;
      --old-only) CLEAN_OLD=true ;;
      --dry-run) DRY_RUN=true ;;
      --keep-old) KEEP_OLD=true ;;
      --logs-dir=*) LOGS_DIR="${1#*=}" ;;
      *)
        if [[ "$1" == "--"* ]]; then
          log_error "Unknown parameter: $1"
          return 1
        fi
        ;;
    esac
    shift
  done
  
  # Set defaults if not provided
  APP_NAME=${APP_NAME:-"app"}
  NGINX_PORT=${NGINX_PORT:-80}
  NGINX_SSL_PORT=${NGINX_SSL_PORT:-443}
  BLUE_PORT=${BLUE_PORT:-8081}
  GREEN_PORT=${GREEN_PORT:-8082}
  HEALTH_ENDPOINT=${HEALTH_ENDPOINT:-"/health"}
  HEALTH_RETRIES=${HEALTH_RETRIES:-12}
  HEALTH_DELAY=${HEALTH_DELAY:-5}
  TIMEOUT=${TIMEOUT:-5}
  IMAGE_REPO=${IMAGE_REPO:-""}
  FRONTEND_IMAGE_REPO=${FRONTEND_IMAGE_REPO:-""}
  FRONTEND_VERSION=${FRONTEND_VERSION:-""}
  DOMAIN_NAME=${DOMAIN_NAME:-"example.com"}
  
  # Flag defaults
  FORCE_FLAG=${FORCE_FLAG:-false}
  NO_SHIFT=${NO_SHIFT:-false}
  CLEAN_ALL=${CLEAN_ALL:-false}
  CLEAN_FAILED=${CLEAN_FAILED:-false}
  CLEAN_OLD=${CLEAN_OLD:-false}
  DRY_RUN=${DRY_RUN:-false}
  KEEP_OLD=${KEEP_OLD:-false}
  SETUP_SHARED=${SETUP_SHARED:-false}
  SKIP_MIGRATIONS=${SKIP_MIGRATIONS:-false}
  MIGRATIONS_CMD=${MIGRATIONS_CMD:-"npm run migrate"}
  
  return 0
}

# Ensure Docker is running
# 
# Returns:
#   0 if Docker is running, 1 otherwise
ensure_docker_running() {
  if ! docker info > /dev/null 2>&1; then
    log_error "Docker is not running or not accessible"
    return 1
  fi
  return 0
}

# Get the appropriate Docker Compose command
# 
# Returns:
#   Docker Compose command string or error code 1
get_docker_compose_cmd() {
  if command -v docker-compose &> /dev/null; then
    echo "docker-compose"
  elif docker compose version &> /dev/null; then
    echo "docker compose"
  else
    log_error "Docker Compose not found"
    return 1
  fi
}

# Creates a directory if it doesn't exist
# 
# Arguments:
#   $1 - Directory path to create
ensure_directory() {
  local dir_path=$1
  if [ ! -d "$dir_path" ]; then
    mkdir -p "$dir_path"
    log_info "Created directory: $dir_path"
  fi
}

# Determine which environment is active and which is target
# 
# Returns:
#   String in the format "active_env target_env"
get_environments() {
  # Check if blue is running and part of nginx config
  if docker-compose -p ${APP_NAME}-blue ps 2>/dev/null | grep -q "Up"; then
    if grep -q "${APP_NAME}-blue" nginx.conf 2>/dev/null; then
      echo "blue green"  # blue active, green target
      return 0
    fi
  fi
  
  # Check if green is running and part of nginx config
  if docker-compose -p ${APP_NAME}-green ps 2>/dev/null | grep -q "Up"; then
    if grep -q "${APP_NAME}-green" nginx.conf 2>/dev/null; then
      echo "green blue"  # green active, blue target
      return 0
    fi
  fi
  
  # Default if no clear active environment
  echo "green blue"
  return 0
}

# Create environment file for deployment
# 
# Arguments:
#   $1 - Environment name (blue or green)
#   $2 - Port number for this environment
#
# Description:
#   Creates .env file for Docker Compose with environment-specific settings
create_env_file() {
  local env_name=$1
  local port=$2

  cat > ".env.${env_name}" << EOL
# Auto-generated environment file for ${env_name} environment
# This file is used by Docker Compose to configure the ${env_name} environment
APP_NAME=${APP_NAME}
IMAGE=${IMAGE_REPO}:${VERSION}
PORT=${port}
ENV_NAME=${env_name}
EOL

  # Add any environment variables exported from CI/CD
  # This captures variables like DATABASE_URL, API_KEY, etc.
  # Only include variables that actually exist
  local env_vars=(
    "DATABASE_URL" 
    "REDIS_URL" 
    "API_KEY"
  )
  
  for var in "${env_vars[@]}"; do
    if [ -n "${!var:-}" ]; then
      echo "${var}=${!var}" >> ".env.${env_name}"
    fi
  done
  
  # Add any DB_* or APP_* environment variables
  env | grep -E '^(DB_|APP_)' | sort >> ".env.${env_name}" 2>/dev/null || true
  
  # Set secure permissions
  chmod 600 ".env.${env_name}"
  log_info "Created .env.${env_name} file with deployment variables"
}

# Check if a container is healthy
# 
# Arguments:
#   $1 - Container name or ID
#
# Returns:
#   0 if container is healthy, 1 otherwise
is_container_healthy() {
  local container=$1
  local health_status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not found")
  
  if [ "$health_status" = "healthy" ]; then
    return 0
  else
    return 1
  fi
}

# Update traffic distribution between environments
# 
# Arguments:
#   $1 - Blue weight
#   $2 - Green weight
#   $3 - Nginx template path
#   $4 - Output file path
#
# Example:
#   update_traffic_distribution 8 2 "./config/templates/nginx-multi-domain.conf.template" "./nginx.conf"
update_traffic_distribution() {
  local blue_weight="$1"
  local green_weight="$2"
  local nginx_template="$3"
  local nginx_conf="$4"
  
  log_info "Updating traffic distribution: blue=$blue_weight, green=$green_weight"
  
  cat "$nginx_template" | \
    sed -e "s/BLUE_WEIGHT/$blue_weight/g" | \
    sed -e "s/GREEN_WEIGHT/$green_weight/g" | \
    sed -e "s/APP_NAME/$APP_NAME/g" | \
    sed -e "s/DOMAIN_NAME/${DOMAIN_NAME:-example.com}/g" | \
    sed -e "s/NGINX_PORT/${NGINX_PORT}/g" | \
    sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT:-443}/g" > "$nginx_conf"
  
  local docker_compose=$(get_docker_compose_cmd)
  $docker_compose restart nginx || log_warning "Failed to restart nginx"
}

# Check health of an endpoint
# 
# Arguments:
#   $1 - Endpoint URL
#   $2 - Number of retries (optional)
#   $3 - Delay between retries in seconds (optional)
#   $4 - Timeout for each request in seconds (optional)
#
# Returns:
#   0 if endpoint is healthy, 1 otherwise
#
# Example:
#   check_health "http://localhost:8080/health" 5 10 3
check_health() {
  local endpoint="$1"
  local retries="${2:-$HEALTH_RETRIES}"
  local delay="${3:-$HEALTH_DELAY}"
  local timeout="${4:-$TIMEOUT}"
  
  log_info "Checking health of $endpoint (retries: $retries, delay: ${delay}s)"
  
  local count=0
  while [ $count -lt $retries ]; do
    if curl -s -f -m "$timeout" "$endpoint" > /dev/null 2>&1; then
      log_success "Health check passed for $endpoint"
      return 0
    else
      count=$((count + 1))
      if [ $count -lt $retries ]; then
        log_info "Health check failed, retrying in ${delay}s... ($(($count))/$retries)"
        sleep $delay
      fi
    fi
  done
  
  log_error "Health check failed for $endpoint after $retries attempts"
  return 1
}

# Check health of multiple endpoints
# 
# Arguments:
#   $1 - List of endpoints separated by spaces
#   $2 - Number of retries (optional)
#   $3 - Delay between retries in seconds (optional)
#   $4 - Timeout for each request in seconds (optional)
#
# Returns:
#   0 if all endpoints are healthy, 1 if any fails
#
# Example:
#   check_multiple_health "http://localhost:8080/health http://localhost:8081/health" 5 10 3
check_multiple_health() {
  local endpoints=($1)
  local retries="${2:-$HEALTH_RETRIES}"
  local delay="${3:-$HEALTH_DELAY}"
  local timeout="${4:-$TIMEOUT}"
  
  log_info "Checking health of multiple endpoints (${#endpoints[@]} total)"
  
  for endpoint in "${endpoints[@]}"; do
    if ! check_health "$endpoint" "$retries" "$delay" "$timeout"; then
      log_error "Health check failed for $endpoint"
      return 1
    fi
  done
  
  log_success "All endpoints are healthy"
  return 0
}

# Log deployment step for recovery and auditing
# 
# Arguments:
#   $1 - Deployment ID (usually version)
#   $2 - Step description
#   $3 - Status
#
# Example:
#   log_deployment_step "v1.0" "deployment_started" "started"
log_deployment_step() {
  local deployment_id="$1"
  local step="$2"
  local status="$3"
  
  # Ensure logs directory exists
  ensure_directory "$LOGS_DIR"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$status] $step" >> "$LOGS_DIR/${APP_NAME}-${deployment_id}.log"
}

# Run command conditionally in dry run mode
# 
# Arguments:
#   Command to run with arguments
#
# Returns:
#   Command exit code or 0 in dry run mode
run_cmd() {
  if [ "${DRY_RUN:-false}" = true ]; then
    log_info "Would run: $*"
    return 0
  else
    log_info "Running: $*"
    "$@"
    return $?
  fi
}

# Execute hook if defined in plugins
# 
# Arguments:
#   $1 - Hook name
#   $* - Additional arguments to pass to the hook
#
# Returns:
#   Hook exit code or 0 if hook not found
#
# Example:
#   run_hook "pre_deploy" "v1.0" "blue"
run_hook() {
  local hook_name="$1"
  shift
  
  # Check if plugins directory exists
  if [ ! -d "plugins" ]; then
    return 0
  fi
  
  # Check if there are any plugin files
  local plugin_count=$(find plugins -name "*.sh" -type f 2>/dev/null | wc -l)
  if [ "$plugin_count" -eq 0 ]; then
    return 0
  fi
  
  # Load all plugins
  for plugin in plugins/*.sh; do
    if [ -f "$plugin" ]; then
      source "$plugin"
    fi
  done
  
  if type "hook_${hook_name}" &>/dev/null; then
    log_info "Running hook: $hook_name"
    "hook_${hook_name}" "$@"
    return $?
  fi
  
  return 0
}