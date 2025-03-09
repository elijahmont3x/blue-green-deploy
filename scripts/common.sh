#!/bin/bash
set -euo pipefail

# Description: Core utility functions for the blue/green deployment system

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

# Determine active and target environments
get_environments() {
  if docker-compose -p backend-blue ps 2>/dev/null | grep -q "Up"; then
    if grep -q "backend-blue" nginx.conf 2>/dev/null; then
      echo "blue green"  # Format: "active_env target_env"
    else
      # Blue is running but not active, green is active
      echo "green blue"
    fi
  else
    echo "green blue"
  fi
}

# Get docker-compose command (handles both v1 and v2)
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

# Error handling
handle_error() {
  local exit_code=$?
  local error_msg="$1"
  local fatal="${2:-true}"
  
  if [ $exit_code -ne 0 ]; then
    log_error "$error_msg (Exit code: $exit_code)"
    if [ "$fatal" = true ]; then
      exit $exit_code
    fi
  fi
}

# Load configuration from file
load_config() {
  local config_file="${1:-config.env}"
  
  if [ -f "$config_file" ]; then
    log_info "Loading configuration from $config_file"
    export $(grep -v '^#' "$config_file" | xargs)
  else
    log_warning "Config file $config_file not found, using defaults"
  fi
}

# Secure environment file
secure_env_file() {
  local env_file="$1"
  
  # Ensure file exists
  touch "$env_file"
  
  # Set appropriate permissions
  chmod 600 "$env_file"
  
  # Check if file is secure
  local perms=$(stat -c "%a" "$env_file" 2>/dev/null || stat -f "%p" "$env_file" 2>/dev/null | tail -c 4)
  if [ "$perms" != "600" ]; then
    log_warning "Failed to set secure permissions on $env_file"
    return 1
  fi
  
  return 0
}

# Validate required environment variables
validate_required_vars() {
  local missing=0
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      log_error "Required variable $var is not set"
      missing=1
    fi
  done
  return $missing
}

# Creates a directory if it doesn't exist
ensure_directory() {
  local dir_path=$1
  if [ ! -d "$dir_path" ]; then
    mkdir -p "$dir_path"
    log_info "Created directory: $dir_path"
  fi
}

# Apply template with substitutions
apply_template() {
  local template="$1"
  local output="$2"
  shift 2
  
  if [ ! -f "$template" ]; then
    log_error "Template file not found: $template"
    return 1
  fi
  
  # Create a copy of the template
  cp "$template" "$output.tmp"
  
  # Apply all variable replacements
  while [[ "$#" -gt 0 ]]; do
    local key="$1"
    local value="$2"
    sed -i.bak "s|{{$key}}|$value|g" "$output.tmp" && rm -f "$output.tmp.bak"
    shift 2
  done
  
  # Move temp file to final destination
  mv "$output.tmp" "$output"
  
  log_info "Generated $output from template $template"
  return 0
}

# Check if a container is healthy
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
update_traffic_distribution() {
  local blue_weight="$1"
  local green_weight="$2"
  local nginx_template="$3"
  local nginx_conf="$4"
  
  log_info "Updating traffic distribution: blue=$blue_weight, green=$green_weight"
  
  apply_template "$nginx_template" "$nginx_conf" \
    "BLUE_WEIGHT" "$blue_weight" \
    "GREEN_WEIGHT" "$green_weight"
  
  local docker_compose=$(get_docker_compose_cmd)
  $docker_compose restart nginx || log_warning "Failed to restart nginx"
}

# Check health of an endpoint
check_health() {
  local endpoint="$1"
  local retries="${2:-5}"
  local delay="${3:-2}"
  local timeout="${4:-5}"
  
  log_info "Checking health of $endpoint (retries: $retries, delay: ${delay}s)"
  
  local count=0
  while [ $count -lt $retries ]; do
    local response=$(curl -s -m "$timeout" "$endpoint" 2>/dev/null || echo "Connection failed")
    
    if echo "$response" | grep -qi "\"status\".*healthy" || 
       echo "$response" | grep -qi "healthy" || 
       curl -s -o /dev/null -w "%{http_code}" -m "$timeout" "$endpoint" 2>/dev/null | grep -q "200"; then
      log_success "Health check passed for $endpoint"
      return 0
    fi
    
    count=$((count + 1))
    if [ $count -lt $retries ]; then
      log_info "Health check failed, retrying in ${delay}s... ($(($count))/$retries)"
      sleep $delay
    fi
  done
  
  log_error "Health check failed for $endpoint after $retries attempts"
  return 1
}

# Log deployment step for recovery
log_deployment_step() {
  local deployment_id="$1"
  local step="$2"
  local status="$3"
  
  ensure_directory ".deployment_logs"
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$status] $step" >> ".deployment_logs/${deployment_id}.log"
}

# Execute hook if defined
run_hook() {
  local hook_name="$1"
  shift
  
  if type "hook_${hook_name}" &>/dev/null; then
    log_info "Running hook: $hook_name"
    "hook_${hook_name}" "$@"
  fi
}
