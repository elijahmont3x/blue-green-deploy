#!/bin/bash
#
# bgd-core.sh - Core functions for Blue/Green Deployment toolkit
#
# This module defines essential functions used by all BGD toolkit scripts.
# It includes logging, configuration management, error handling, and utility functions.

set -euo pipefail

# ============================================================
# CONFIGURATION MANAGEMENT
# ============================================================

# Required parameters - empty value means it's a required parameter
declare -A BGD_REQUIRED_PARAMS=(
  ["APP_NAME"]=""
  ["VERSION"]=""
  ["IMAGE_REPO"]=""
)

# Parameter validation rules
declare -A BGD_VALIDATION_RULES=(
  ["NGINX_PORT"]="validate_port"
  ["NGINX_SSL_PORT"]="validate_port"
  ["BLUE_PORT"]="validate_port"
  ["GREEN_PORT"]="validate_port"
  ["HEALTH_RETRIES"]="validate_positive_integer"
  ["HEALTH_DELAY"]="validate_positive_integer"
  ["TIMEOUT"]="validate_positive_integer"
)

# Default values - only for non-critical parameters
declare -A BGD_DEFAULT_VALUES=(
  ["HEALTH_ENDPOINT"]="/health"
  ["HEALTH_RETRIES"]="12"
  ["HEALTH_DELAY"]="5"
  ["TIMEOUT"]="5"
  ["MAX_LOG_LINES"]="100"
  ["NGINX_PORT"]="80"
  ["NGINX_SSL_PORT"]="443"
  ["BLUE_PORT"]="8081"
  ["GREEN_PORT"]="8082"
  ["PATHS"]=""
  ["SUBDOMAINS"]=""
  ["DEFAULT_SERVICE"]="app"
  ["DEFAULT_PORT"]="3000"
  ["DOMAIN_ALIASES"]=""
)

# Plugin registered arguments
declare -A BGD_PLUGIN_ARGS=()

# ============================================================
# DIRECTORY AND FILE MANAGEMENT
# ============================================================

# Directory structure
BGD_BASE_DIR="$(pwd)"
BGD_LOGS_DIR="${BGD_BASE_DIR}/logs"
BGD_CONFIG_DIR="${BGD_BASE_DIR}/config"
BGD_TEMPLATES_DIR="${BGD_CONFIG_DIR}/templates"
BGD_CREDENTIALS_DIR="${BGD_BASE_DIR}/credentials"
BGD_PLUGINS_DIR="${BGD_BASE_DIR}/plugins"

# Log file for current operation
BGD_LOG_FILE="${BGD_LOGS_DIR}/bgd-$(date '+%Y%m%d-%H%M%S').log"

# Ensure directory exists
bgd_ensure_directory() {
  local dir_path="$1"
  
  if [ ! -d "$dir_path" ]; then
    mkdir -p "$dir_path"
    bgd_log "Created directory: $dir_path" "info"
  fi
}

# Create required directories
bgd_create_directories() {
  bgd_ensure_directory "$BGD_LOGS_DIR"
  bgd_ensure_directory "$BGD_CONFIG_DIR"
  bgd_ensure_directory "$BGD_CREDENTIALS_DIR"
  chmod 700 "$BGD_CREDENTIALS_DIR"  # Secure credentials directory
}

# ============================================================
# NGINX CONFIGURATION MANAGEMENT
# ============================================================

# Safely create or update nginx.conf file for dual-environment setup
bgd_create_dual_env_nginx_conf() {
  local blue_weight="$1"
  local green_weight="$2"
  
  bgd_log "Generating dual-environment Nginx configuration (blue: $blue_weight, green: $green_weight)" "info"
  
  # Source the template processor if not already loaded
  if ! declare -f bgd_generate_dual_env_nginx_conf > /dev/null; then
    local nginx_template_script="${BGD_SCRIPT_DIR}/bgd-nginx-template.sh"
    if [ -f "$nginx_template_script" ]; then
      source "$nginx_template_script"
    else
      bgd_handle_error "file_not_found" "Nginx template processor not found at $nginx_template_script"
      return 1
    fi
  fi
  
  # Generate the configuration
  local nginx_conf=$(bgd_generate_dual_env_nginx_conf "$APP_NAME" "$blue_weight" "$green_weight" "$PATHS" "$SUBDOMAINS")
  
  # Check if nginx.conf is a directory and remove it if so
  if [ -d "nginx.conf" ]; then
    bgd_log "Found nginx.conf as a directory, removing it" "warning"
    rm -rf "nginx.conf"
  fi
  
  # Write the configuration to a temporary file first
  echo "$nginx_conf" > "nginx.conf.tmp"
  
  # Verify temp file was created successfully
  if [ ! -f "nginx.conf.tmp" ] || [ ! -s "nginx.conf.tmp" ]; then
    bgd_handle_error "file_not_found" "Failed to create temporary nginx.conf file"
    return 1
  fi
  
  # Move temp file to actual nginx.conf (atomic operation)
  mv "nginx.conf.tmp" "nginx.conf"
  
  bgd_log "Nginx configuration created successfully" "success"
  return 0
}

# Safely create or update nginx.conf file for single-environment setup
bgd_create_single_env_nginx_conf() {
  local target_env="$1"
  
  bgd_log "Generating single-environment Nginx configuration for $target_env" "info"
  
  # Source the template processor if not already loaded
  if ! declare -f bgd_generate_single_env_nginx_conf > /dev/null; then
    local nginx_template_script="${BGD_SCRIPT_DIR}/bgd-nginx-template.sh"
    if [ -f "$nginx_template_script" ]; then
      source "$nginx_template_script"
    else
      bgd_handle_error "file_not_found" "Nginx template processor not found at $nginx_template_script"
      return 1
    fi
  fi
  
  # Generate the configuration
  local nginx_conf=$(bgd_generate_single_env_nginx_conf "$APP_NAME" "$target_env" "$PATHS" "$SUBDOMAINS")
  
  # Check if nginx.conf is a directory and remove it if so
  if [ -d "nginx.conf" ]; then
    bgd_log "Found nginx.conf as a directory, removing it" "warning"
    rm -rf "nginx.conf"
  fi
  
  # Write the configuration to a temporary file first
  echo "$nginx_conf" > "nginx.conf.tmp"
  
  # Verify temp file was created successfully
  if [ ! -f "nginx.conf.tmp" ] || [ ! -s "nginx.conf.tmp" ]; then
    bgd_handle_error "file_not_found" "Failed to create temporary nginx.conf file"
    return 1
  fi
  
  # Move temp file to actual nginx.conf (atomic operation)
  mv "nginx.conf.tmp" "nginx.conf"
  
  bgd_log "Nginx configuration created successfully" "success"
  return 0
}

# ============================================================
# LOGGING SYSTEM
# ============================================================

# Log severity levels
declare -A BGD_LOG_LEVEL_COLORS=(
  ["debug"]="\033[0;37m"    # Light gray
  ["info"]="\033[0;34m"     # Blue
  ["warning"]="\033[0;33m"  # Yellow
  ["error"]="\033[0;31m"    # Red
  ["critical"]="\033[1;31m" # Bold red
  ["success"]="\033[0;32m"  # Green
)

# Log a message with severity
bgd_log() {
  local message="$1"
  local level="${2:-info}"
  local context="${3:-}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local color="${BGD_LOG_LEVEL_COLORS[$level]:-${BGD_LOG_LEVEL_COLORS[info]}}"
  local color_reset="\033[0m"
  
  # Format log message
  local log_message="[$timestamp] ${color}[${level^^}]${color_reset} $message"
  
  # Add context if provided
  if [ -n "$context" ]; then
    log_message="$log_message (context: $context)"
  fi
  
  # Print to console
  echo -e "$log_message"
  
  # Create logs directory if it doesn't exist
  bgd_ensure_directory "$BGD_LOGS_DIR"
  
  # Write to log file (without color codes)
  echo "[$timestamp] [${level^^}] $message${context:+ (context: $context)}" >> "$BGD_LOG_FILE"
  
  # Special handling for critical errors
  if [ "$level" = "critical" ]; then
    # Send notification if enabled
    if [ "${NOTIFY_ENABLED:-false}" = "true" ]; then
      bgd_send_notification "CRITICAL: $message" "error"
    fi
    
    # Exit on critical errors unless specifically disabled
    if [ "${BGD_EXIT_ON_CRITICAL:-true}" = "true" ]; then
      exit 1
    fi
  fi
}

# Log deployment event to structured log
bgd_log_deployment_event() {
  local deployment_id="$1"
  local event_type="$2"
  local event_details="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local deployment_log="${BGD_LOGS_DIR}/deployment-${APP_NAME}-${deployment_id}.log"
  
  # Create JSON log entry
  local json_entry="{\"timestamp\":\"$timestamp\",\"deployment_id\":\"$deployment_id\",\"app\":\"$APP_NAME\",\"event\":\"$event_type\",\"details\":\"$event_details\"}"
  
  # Write to deployment log file
  echo "$json_entry" >> "$deployment_log"
  
  # Log to main log as well
  bgd_log "Deployment event: ${event_type} - ${event_details}" "info" "deployment_id=${deployment_id}"
}

# ============================================================
# ERROR HANDLING
# ============================================================

# Structured error handling with suggestions
bgd_handle_error() {
  local error_type="$1"
  local details="${2:-}"
  local suggestions=""
  local exit_code=1
  
  # Determine error message and suggestions based on error type
  case "$error_type" in
    missing_parameter)
      message="Missing required parameter: $details"
      suggestions="Ensure all required parameters are specified when running the script"
      ;;
    invalid_parameter)
      message="Invalid parameter value: $details"
      suggestions="Check parameter syntax and ensure values are in the correct format"
      ;;
    port_conflict)
      message="Port conflict detected: $details"
      suggestions="Specify different ports or use --auto-port-assignment to resolve conflicts automatically"
      ;;
    environment_start_failed)
      message="Failed to start environment: $details"
      suggestions="Check Docker Compose configuration and ensure all services can start properly"
      ;;
    health_check_failed)
      message="Health check failed: $details"
      suggestions="Verify your application is configured correctly and the health endpoint is responding"
      ;;
    docker_error)
      message="Docker operation failed: $details"
      suggestions="Ensure Docker is running and you have sufficient permissions"
      ;;
    network_error)
      message="Network operation failed: $details"
      suggestions="Check network configuration and ensure network names are valid"
      ;;
    file_not_found)
      message="Required file not found: $details"
      suggestions="Verify file paths and ensure all required files are present"
      ;;
    permission_denied)
      message="Permission denied: $details"
      suggestions="Check file/directory permissions and ensure you have sufficient access"
      ;;
    unknown)
      message="Unknown error: $details"
      suggestions="Check logs for more details"
      ;;
    *)
      message="Error: $error_type"
      suggestions="Check logs for more details"
      ;;
  esac
  
  # Log error with details
  bgd_log "$message" "error" "$details"
  
  # Log suggestion if available
  if [ -n "$suggestions" ]; then
    bgd_log "Suggestion: $suggestions" "info"
  fi
  
  # Log to deployment history
  if [ -n "${VERSION:-}" ] && [ -n "${APP_NAME:-}" ]; then
    bgd_log_deployment_event "$VERSION" "deployment_failed" "$error_type"
  fi
  
  # Send notification if enabled
  if [ "${NOTIFY_ENABLED:-false}" = "true" ]; then
    bgd_send_notification "Deployment error: $message" "error"
  fi
  
  # Handle auto-rollback if enabled
  if [ "${AUTO_ROLLBACK:-false}" = "true" ] && [ -n "${TARGET_ENV:-}" ] && [ -n "${APP_NAME:-}" ]; then
    bgd_log "Auto-rollback is enabled, attempting to roll back..." "warning"
    
    # Find the rollback script
    local rollback_script="${BGD_BASE_DIR}/scripts/bgd-rollback.sh"
    
    # Perform rollback if script exists
    if [ -f "$rollback_script" ] && [ -x "$rollback_script" ]; then
      if "$rollback_script" --app-name="$APP_NAME" --force; then
        bgd_log "Auto-rollback succeeded" "success"
        bgd_log_deployment_event "$VERSION" "auto_rollback" "success"
      else
        bgd_log "Auto-rollback failed" "critical"
        bgd_log_deployment_event "$VERSION" "auto_rollback" "failed"
      fi
    else
      bgd_log "Rollback script not found or not executable: $rollback_script" "critical"
    fi
  fi
  
  # Exit with appropriate code
  exit $exit_code
}

# Trap unexpected errors
bgd_trap_error() {
  local exit_code=$?
  local line_no=$1
  
  if [ $exit_code -ne 0 ]; then
    bgd_log "Unexpected error on line $line_no, exit code $exit_code" "critical"
    exit $exit_code
  fi
}

# Set up error trap
trap 'bgd_trap_error $LINENO' ERR

# ============================================================
# PARAMETER VALIDATION
# ============================================================

# Validate a port number
validate_port() {
  local port="$1"
  local param_name="$2"
  
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    bgd_handle_error "invalid_parameter" "${param_name}=${port} (must be a number between 1-65535)"
    return 1
  fi
  
  return 0
}

# Validate a positive integer
validate_positive_integer() {
  local value="$1"
  local param_name="$2"
  
  if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 1 ]; then
    bgd_handle_error "invalid_parameter" "${param_name}=${value} (must be a positive integer)"
    return 1
  fi
  
  return 0
}

# Validate parameters
bgd_validate_parameters() {
  local skip_validation="${1:-false}"
  
  if [ "$skip_validation" = "true" ]; then
    return 0
  fi
  
  # Check required parameters
  for param in "${!BGD_REQUIRED_PARAMS[@]}"; do
    if [ -z "${!param:-}" ]; then
      bgd_handle_error "missing_parameter" "$param"
      return 1
    fi
  done
  
  # Validate parameter values
  for param in "${!BGD_VALIDATION_RULES[@]}"; do
    if [ -n "${!param:-}" ]; then
      local validation_func="${BGD_VALIDATION_RULES[$param]}"
      "$validation_func" "${!param}" "$param" || return 1
    fi
  done
  
  # Check for port conflicts
  if [ "${NGINX_PORT:-}" = "${NGINX_SSL_PORT:-}" ]; then
    bgd_handle_error "port_conflict" "NGINX_PORT and NGINX_SSL_PORT cannot be the same (${NGINX_PORT})"
    return 1
  fi
  
  if [ "${BLUE_PORT:-}" = "${GREEN_PORT:-}" ]; then
    bgd_handle_error "port_conflict" "BLUE_PORT and GREEN_PORT cannot be the same (${BLUE_PORT})"
    return 1
  fi
  
  return 0
}

# ============================================================
# CONFIGURATION MANAGEMENT
# ============================================================

# Load plugins
bgd_load_plugins() {
  # Check if plugins directory exists
  if [ ! -d "$BGD_PLUGINS_DIR" ]; then
    bgd_log "Plugins directory not found: $BGD_PLUGINS_DIR" "warning"
    return 0
  fi
  
  # Check if there are any plugin files
  local plugin_count=$(find "$BGD_PLUGINS_DIR" -name "bgd-*.sh" -type f 2>/dev/null | wc -l)
  if [ "$plugin_count" -eq 0 ]; then
    bgd_log "No plugins found in $BGD_PLUGINS_DIR" "info"
    return 0
  fi
  
  bgd_log "Loading plugins..." "info"
  
  # Load all plugins
  for plugin in "$BGD_PLUGINS_DIR"/bgd-*.sh; do
    if [ -f "$plugin" ] && [ -x "$plugin" ]; then
      plugin_name=$(basename "$plugin" .sh)
      bgd_log "Loading plugin: $plugin_name" "info"
      source "$plugin"
      
      # Call registration function if it exists
      if type "bgd_register_${plugin_name#bgd-}_arguments" &>/dev/null; then
        "bgd_register_${plugin_name#bgd-}_arguments"
      fi
    fi
  done
  
  bgd_log "Plugin loading completed" "info"
  return 0
}

# Register a plugin argument
bgd_register_plugin_argument() {
  local plugin_name="$1"
  local arg_name="$2"
  local default_value="$3"
  
  BGD_PLUGIN_ARGS["$arg_name"]="$default_value"
  
  # Create a global variable with the default value if it doesn't exist
  if [ -z "${!arg_name:-}" ]; then
    eval "$arg_name=\"$default_value\""
  fi
}

# Parse command-line parameters
bgd_parse_parameters() {
  # First positional argument is the VERSION
  if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
    VERSION="$1"
    shift
  fi
  
  # Process remaining arguments
  while [ $# -gt 0 ]; do
    # Help command
    if [ "$1" = "--help" ]; then
      bgd_show_help
      exit 0
    fi
    
    # Parse a parameter
    if [[ "$1" == --* ]]; then
      local param="${1#--}"
      
      # Boolean flag (--flag)
      if [[ "$param" == *"="* ]]; then
        # Key-value parameter (--key=value)
        local key="${param%%=*}"
        local value="${param#*=}"
        
        # Convert to uppercase variable name
        local var_name=$(echo "$key" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        
        # Set the variable
        eval "$var_name=\"$value\""
      else
        # Boolean flag
        local var_name=$(echo "$param" | tr '-' '_' | tr '[:lower:]' '[:upper:]')
        eval "$var_name=true"
      fi
    fi
    
    shift
  done
  
  # Set default values for parameters not explicitly set
  for param in "${!BGD_DEFAULT_VALUES[@]}"; do
    if [ -z "${!param:-}" ]; then
      eval "$param=\"${BGD_DEFAULT_VALUES[$param]}\""
    fi
  done
  
  # Set default values for plugin parameters not explicitly set
  for param in "${!BGD_PLUGIN_ARGS[@]}"; do
    if [ -z "${!param:-}" ]; then
      eval "$param=\"${BGD_PLUGIN_ARGS[$param]}\""
    fi
  done
  
  # Validate parameters
  bgd_validate_parameters
  
  # Export all parameters
  for param in "${!BGD_REQUIRED_PARAMS[@]}" "${!BGD_DEFAULT_VALUES[@]}" "${!BGD_PLUGIN_ARGS[@]}"; do
    if [ -n "${!param:-}" ]; then
      export "$param"
    fi
  done
  
  return 0
}

# ============================================================
# DOCKER AND CONTAINER MANAGEMENT
# ============================================================

# Ensure Docker is running
bgd_ensure_docker_running() {
  if ! docker info > /dev/null 2>&1; then
    bgd_handle_error "docker_error" "Docker is not running or not accessible"
    return 1
  fi
  
  return 0
}

# Get the appropriate Docker Compose command
bgd_get_docker_compose_cmd() {
  if docker compose version &> /dev/null; then
    echo "docker compose"
  elif command -v docker-compose &> /dev/null; then
    echo "docker-compose"
  else
    bgd_handle_error "docker_error" "Docker Compose not found"
    return 1
  fi
  
  return 0
}

# Get current active and target environments
bgd_get_environments() {
  # Get Docker Compose command
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Check if blue environment is running
  local blue_running=false
  if $docker_compose -p "${APP_NAME}-blue" ps 2>/dev/null | grep -q "Up"; then
    blue_running=true
  fi
  
  # Check if green environment is running
  local green_running=false
  if $docker_compose -p "${APP_NAME}-green" ps 2>/dev/null | grep -q "Up"; then
    green_running=true
  fi
  
  # Check Nginx configuration if it exists
  if [ -f "nginx.conf" ]; then
    # Check which environment is in the Nginx config
    if grep -q "${APP_NAME}-blue" nginx.conf 2>/dev/null; then
      echo "blue green"  # blue active, green target
      return 0
    elif grep -q "${APP_NAME}-green" nginx.conf 2>/dev/null; then
      echo "green blue"  # green active, blue target
      return 0
    fi
  fi
  
  # If no clear active environment from Nginx config, use running status
  if [ "$blue_running" = true ] && [ "$green_running" = false ]; then
    echo "blue green"
  elif [ "$green_running" = true ] && [ "$blue_running" = false ]; then
    echo "green blue"
  else
    # Default if no clear active environment
    echo "blue green"
  fi
  
  return 0
}

# Check if a port is available
bgd_is_port_available() {
  local port="$1"
  
  # Validate port number first
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    bgd_log "Invalid port number: $port" "error"
    return 1
  fi
  
  # Primary approach: Try direct socket test
  # If we can connect, port is in use (return 1/false)
  # If connection fails, port is available (return 0/true)
  if (echo > /dev/tcp/localhost/$port) 2>/dev/null; then # Fixed typo: /dev/ttcp to /dev/tcp
    # Connection successful, port is in use
    return 1
  fi
  
  # Fallback 1: Use netstat if available
  if command -v netstat &> /dev/null; then
    if netstat -tuln | grep -q ":$port "; then
      # Port is in use
      return 1
    fi
  fi
  
  # Fallback 2: Use ss if available
  if command -v ss &> /dev/null; then
    if ss -tuln | grep -q ":$port "; then
      # Port is in use
      return 1
    fi
  fi
  
  # Fallback 3: Use lsof if available
  if command -v lsof &> /dev/null; then
    if lsof -i ":$port" &> /dev/null; then
      # Port is in use
      return 1
    fi
  fi
  
  # All tests indicate port is available
  return 0
}

# Find an available port starting from a specified port
bgd_find_available_port() {
  local start_port="$1"
  local max_attempts="${2:-100}"
  
  local port=$start_port
  local attempts=0
  
  while [ $attempts -lt $max_attempts ]; do
    if bgd_is_port_available "$port"; then
      echo "$port"
      return 0
    fi
    
    port=$((port + 1))
    attempts=$((attempts + 1))
  done
  
  # No available port found
  return 1
}

# Manage automatic port assignment
bgd_manage_ports() {
  if [ "${AUTO_PORT_ASSIGNMENT:-false}" = "true" ]; then
    bgd_log "Automatic port assignment enabled, checking port availability..." "info"
    
    # Check and adjust blue port if needed
    if ! bgd_is_port_available "$BLUE_PORT"; then
      local original_blue_port="$BLUE_PORT"
      BLUE_PORT=$(bgd_find_available_port $((BLUE_PORT + 1)))
      bgd_log "Original blue port $original_blue_port is in use, using $BLUE_PORT instead" "warning"
    fi
    
    # Check and adjust green port if needed
    if ! bgd_is_port_available "$GREEN_PORT"; then
      local original_green_port="$GREEN_PORT"
      GREEN_PORT=$(bgd_find_available_port $((GREEN_PORT + 1)))
      bgd_log "Original green port $original_green_port is in use, using $GREEN_PORT instead" "warning"
    fi
    
    # Ensure blue and green ports don't conflict
    if [ "$BLUE_PORT" = "$GREEN_PORT" ]; then
      GREEN_PORT=$(bgd_find_available_port $((GREEN_PORT + 1)))
      bgd_log "Port conflict detected, using $GREEN_PORT for green environment" "warning"
    fi
    
    # Check and adjust Nginx ports if needed
    if ! bgd_is_port_available "$NGINX_PORT"; then
      local original_nginx_port="$NGINX_PORT"
      NGINX_PORT=$(bgd_find_available_port $((NGINX_PORT + 1)))
      bgd_log "Original Nginx port $original_nginx_port is in use, using $NGINX_PORT instead" "warning"
    fi
    
    if ! bgd_is_port_available "$NGINX_SSL_PORT"; then
      local original_nginx_ssl_port="$NGINX_SSL_PORT"
      NGINX_SSL_PORT=$(bgd_find_available_port $((NGINX_SSL_PORT + 1)))
      bgd_log "Original Nginx SSL port $original_nginx_ssl_port is in use, using $NGINX_SSL_PORT instead" "warning"
    fi
    
    bgd_log "Port assignment completed: Nginx=$NGINX_PORT, SSL=$NGINX_SSL_PORT, Blue=$BLUE_PORT, Green=$GREEN_PORT" "success"
  fi
}

# ============================================================
# HEALTH CHECKING
# ============================================================

# Check health of an endpoint
bgd_check_health() {
  local endpoint="$1"
  local retries="${2:-$HEALTH_RETRIES}"
  local delay="${3:-$HEALTH_DELAY}"
  local timeout="${4:-$TIMEOUT}"
  
  local count=0
  local current_delay="$delay"
  local success=false
  
  bgd_log "Starting health check for $endpoint (retries: $retries, delay: ${delay}s)" "info"
  
  while [ $count -lt $retries ]; do
    # Attempt the health check with multiple success criteria
    response=$(curl -s -m "$timeout" "$endpoint" 2>/dev/null || echo "Connection failed")
    status_code=$(curl -s -o /dev/null -w "%{http_code}" -m "$timeout" "$endpoint" 2>/dev/null || echo "000")
    
    if echo "$response" | grep -qi "\"status\".*healthy" || 
       echo "$response" | grep -qi "healthy" || 
       [[ "$status_code" -ge 200 && "$status_code" -lt 300 ]]; then
      bgd_log "Health check passed! (Status code: $status_code)" "success"
      success=true
      break
    fi
    
    count=$((count + 1))
    if [ $count -lt $retries ]; then
      bgd_log "Health check failed (attempt $count/$retries, status: $status_code, response: ${response:0:50})" "warning"
      
      # Implement backoff if enabled
      if [ "${RETRY_BACKOFF:-false}" = "true" ]; then
        current_delay=$((current_delay * 2))
        bgd_log "Increasing retry delay to ${current_delay}s (backoff enabled)" "info"
      fi
      
      sleep $current_delay
    else
      bgd_log "Health check failed after $retries attempts (status: $status_code)" "error"
    fi
  done
  
  if [ "$success" = true ]; then
    return 0
  fi
  
  # Health check failed
  bgd_handle_error "health_check_failed" "Endpoint: $endpoint, Status: $status_code"
  return 1
}

# Verify all services in an environment
bgd_verify_environment_health() {
  local env_name="$1"
  local retries="${2:-$HEALTH_RETRIES}"
  local delay="${3:-$HEALTH_DELAY}"
  
  bgd_log "Verifying health of all services in ${env_name} environment..." "info"
  
  # Get services with health checks (excluding nginx)
  local services=$(docker ps --filter "name=${APP_NAME}-${env_name}" --format "{{.Names}}" | grep -v "nginx" || true)
  
  if [ -z "$services" ]; then
    bgd_log "No services found for environment ${env_name}" "warning"
    return 1
  fi
  
  local healthy_count=0
  local total_services=0
  
  for service in $services; do
    ((total_services++))
    bgd_log "Checking health of service: $service" "info"
    
    local count=0
    local service_healthy=false
    
    while [ $count -lt $retries ]; do
      # Check container health status
      local health_status=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$service" 2>/dev/null)
      
      if [ "$health_status" = "healthy" ]; then
        bgd_log "Service $service is healthy" "success"
        service_healthy=true
        ((healthy_count++))
        break
      elif [ "$health_status" = "none" ]; then
        # No health check defined, check if running
        if docker inspect --format='{{.State.Running}}' "$service" 2>/dev/null | grep -q "true"; then
          bgd_log "Service $service has no health check defined, but is running" "warning"
          service_healthy=true
          ((healthy_count++))
          break
        else
          bgd_log "Service $service is not running" "error"
          break
        fi
      else
        count=$((count + 1))
        if [ $count -lt $retries ]; then
          bgd_log "Service $service is not healthy yet (status: $health_status), retrying in ${delay}s... ($count/$retries)" "info"
          sleep $delay
        else
          bgd_log "Service $service failed to become healthy after $retries attempts" "error"
        fi
      fi
    done
    
    if [ "$service_healthy" != true ]; then
      bgd_log "Service $service failed health checks" "error"
      # Collect logs from unhealthy service
      bgd_log "Logs from unhealthy service $service:" "info"
      docker logs --tail="${MAX_LOG_LINES:-100}" "$service" || true
    fi
  done
  
  if [ $healthy_count -eq $total_services ]; then
    bgd_log "All services in ${env_name} environment are healthy ($healthy_count/$total_services)" "success"
    return 0
  else
    bgd_log "Not all services are healthy ($healthy_count/$total_services)" "error"
    return 1
  fi
}

# ============================================================
# SECURITY FUNCTIONS
# ============================================================

# Sanitize sensitive data from strings
bgd_sanitize_sensitive_data() {
  local input="$1"
  local sanitized="$input"
  
  # Define patterns to sanitize
  local patterns=(
    "password=[^&]*"
    "passwd=[^&]*"
    "token=[^&]*"
    "secret=[^&]*"
    "key=[^&]*"
    "apikey=[^&]*"
    "api_key=[^&]*"
    "access_token=[^&]*"
    "DATABASE_URL=.*"
    "TELEGRAM_BOT_TOKEN=.*"
    "SLACK_WEBHOOK=.*"
  )
  
  # Sanitize each pattern
  for pattern in "${patterns[@]}"; do
    sanitized=$(echo "$sanitized" | sed -E "s|($pattern)|\\1=******|g")
  done
  
  # Sanitize connection strings
  sanitized=$(echo "$sanitized" | sed -E "s|([a-zA-Z]+://[^:]+:)[^@]+(@)|\\1******\\2|g")
  
  echo "$sanitized"
}

# Store credential securely
bgd_store_credential() {
  local cred_name="$1"
  local cred_value="$2"
  
  # Create credentials directory if it doesn't exist
  if [ ! -d "$BGD_CREDENTIALS_DIR" ]; then
    mkdir -p "$BGD_CREDENTIALS_DIR"
    chmod 700 "$BGD_CREDENTIALS_DIR"
  fi
  
  # Store credential in file with secure permissions
  echo "$cred_value" > "$BGD_CREDENTIALS_DIR/$cred_name"
  chmod 600 "$BGD_CREDENTIALS_DIR/$cred_name"
  
  bgd_log "Stored credential: $cred_name" "debug"
  return 0
}

# Retrieve credential
bgd_get_credential() {
  local cred_name="$1"
  
  if [ ! -f "$BGD_CREDENTIALS_DIR/$cred_name" ]; then
    return 1
  fi
  
  cat "$BGD_CREDENTIALS_DIR/$cred_name"
  return 0
}

# Create secure environment file
bgd_create_secure_env_file() {
  local env_name="$1"
  local port="$2"
  local env_file=".env.${env_name}"

  bgd_log "Creating secure environment file for ${env_name} environment" "info"

  # Basic environment variables
  cat > "$env_file" << EOL
# Blue/Green Deployment - Environment File
# Environment: ${env_name}
# Generated: $(date)
# Application: ${APP_NAME}

APP_NAME=${APP_NAME}
IMAGE=${IMAGE_REPO}:${VERSION}
PORT=${port}
ENV_NAME=${env_name}
EOL

  # Add configuration parameters
  for param in "NGINX_PORT" "NGINX_SSL_PORT" "DOMAIN_NAME"; do
    if [ -n "${!param:-}" ]; then
      echo "${param}=${!param}" >> "$env_file"
    fi
  done

  # Add docker networking parameters
  echo "SHARED_NETWORK_EXISTS=true" >> "$env_file"
  echo "DB_DATA_EXISTS=true" >> "$env_file"
  echo "REDIS_DATA_EXISTS=true" >> "$env_file"

  # Add any environment variables with secure handling
  local sensitive_patterns="PASSWORD|SECRET|KEY|TOKEN|DATABASE_URL"
  
  # Export explicitly defined sensitive variables
  if [ -n "${DATABASE_URL:-}" ]; then
    bgd_log "Adding database connection string to environment file" "debug"
    echo "DATABASE_URL=${DATABASE_URL}" >> "$env_file"
  fi
  
  if [ -n "${REDIS_URL:-}" ]; then
    bgd_log "Adding Redis connection string to environment file" "debug"
    echo "REDIS_URL=${REDIS_URL}" >> "$env_file"
  fi
  
  # Add any DB_* or APP_* environment variables
  env | grep -E '^(DB_|APP_)' | while read -r line; do
    # Check if it's a sensitive variable based on name
    if [[ "$line" =~ $sensitive_patterns ]]; then
      bgd_log "Adding sensitive environment variable to file" "debug"
    fi
    echo "$line" >> "$env_file"
  done
  
  # Add plugin-registered variables
  for param in "${!BGD_PLUGIN_ARGS[@]}"; do
    if [[ "$param" =~ ^(DB_|APP_|SERVICE_|SSL_|METRICS_|AUTH_) ]]; then
      if [ -n "${!param:-}" ]; then
        echo "${param}=${!param}" >> "$env_file"
      fi
    fi
  done

  # Set secure permissions
  chmod 600 "$env_file"
  bgd_log "Created secure environment file: $env_file" "success"
}

# ============================================================
# NOTIFICATION SYSTEM
# ============================================================

# Send a notification
bgd_send_notification() {
  local message="$1"
  local level="${2:-info}"
  
  # Skip if notifications are disabled
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  # Add emoji based on level
  local emoji=""
  case "$level" in
    info) emoji="ℹ️" ;;
    warning) emoji="⚠️" ;;
    error) emoji="🚨" ;;
    success) emoji="✅" ;;
    *) emoji="ℹ️" ;;
  esac
  
  local formatted_message="$emoji *${APP_NAME}*: $message"
  
  # Send to Telegram if configured
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    bgd_log "Sending Telegram notification" "debug"
    
    # Securely send notification, avoiding token exposure in logs
    local telegram_token="${TELEGRAM_BOT_TOKEN}"
    local chat_id="${TELEGRAM_CHAT_ID}"
    
    curl -s -X POST "https://api.telegram.org/bot${telegram_token}/sendMessage" \
      -d chat_id="${chat_id}" \
      -d text="${formatted_message}" \
      -d parse_mode="Markdown" > /dev/null
    
    local status=$?
    if [ $status -ne 0 ]; then
      bgd_log "Failed to send Telegram notification" "warning"
    fi
  fi
  
  # Send to Slack if configured
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    bgd_log "Sending Slack notification" "debug"
    
    # Securely send notification
    local slack_webhook="${SLACK_WEBHOOK}"
    
    curl -s -X POST "${slack_webhook}" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"${formatted_message}\"}" > /dev/null
    
    local status=$?
    if [ $status -ne 0 ]; then
      bgd_log "Failed to send Slack notification" "warning"
    fi
  fi
  
  return 0
}

# ============================================================
# INITIALIZATION
# ============================================================

# Initialize BGD toolkit
bgd_initialize() {
  # Create required directories
  bgd_create_directories
  
  # Load plugins
  bgd_load_plugins
  
  # Ensure Docker is running
  bgd_ensure_docker_running
  
  # Log initialization status
  bgd_log "Blue/Green Deployment Toolkit initialized" "info"
}

# Call initialization when the script is sourced
bgd_initialize