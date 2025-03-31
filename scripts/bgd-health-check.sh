#!/bin/bash
#
# bgd-health-check.sh - Health check utility for Blue/Green Deployment
#
# This script performs health checks for applications deployed with the BGD system
# and can be used standalone or integrated with other BGD scripts.

set -euo pipefail

# Get script directory and load core module
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Display help information
bgd_show_help() {
  cat << EOL
=================================================================
Blue/Green Deployment System - Health Check Script
=================================================================

USAGE:
  ./bgd-health-check.sh [OPTIONS]

OPTIONS:
  --app-name=NAME          Application name
  --environment=ENV        Environment to check (blue|green|both)
  --endpoint=PATH          Health check endpoint (default: /health)
  --retries=NUM            Number of retry attempts (default: 12)
  --delay=SEC              Delay between retries in seconds (default: 5)
  --timeout=SEC            Request timeout in seconds (default: 3)
  --exit-code              Return non-zero exit code if health check fails
  --quiet                  Suppress detailed output
  --verbose                Show verbose output
  --help                   Show this help message

EXAMPLES:
  # Check health of blue environment
  ./bgd-health-check.sh --app-name=myapp --environment=blue

  # Check health with custom endpoint and parameters
  ./bgd-health-check.sh --app-name=myapp --environment=green --endpoint=/api/health --retries=20 --delay=10

=================================================================
EOL
}

# Perform health check for a specific app/environment
bgd_check_app_health() {
  local app_name="$1"
  local environment="$2"
  local endpoint="${3:-/health}"
  local retries="${4:-12}"
  local delay="${5:-5}"
  local timeout="${6:-3}"
  
  bgd_log "Checking health for $app_name in $environment environment (endpoint: $endpoint)" "info"
  
  # Determine how to access the app (direct container, nginx)
  local health_url=""
  local container_name="${app_name}-${environment}-app"
  
  # Try to find the container
  if docker ps --format "{{.Names}}" | grep -q "$container_name"; then
    bgd_log "Found container: $container_name" "debug"
    
    # Determine port from environment
    local port=""
    if [ "$environment" = "blue" ]; then
      port="${BLUE_PORT:-8081}"
    elif [ "$environment" = "green" ]; then
      port="${GREEN_PORT:-8082}"
    else
      port="3000"  # Default container port
    fi
    
    # Construct health check URL
    health_url="http://localhost:$port$endpoint"
  else
    bgd_log "Container not found: $container_name, using Nginx proxy" "debug"
    
    # Try to use Nginx proxy health check
    # Check if domain is set
    if [ -n "${DOMAIN_NAME:-}" ]; then
      health_url="https://$DOMAIN_NAME$endpoint"
    else
      health_url="http://localhost:${NGINX_PORT:-80}$endpoint"
    fi
  fi
  
  bgd_log "Using health check URL: $health_url" "debug"
  
  # Perform health check with retries
  local retry_count=0
  local success=false
  
  while [ $retry_count -lt $retries ]; do
    retry_count=$((retry_count + 1))
    
    bgd_log "Health check attempt $retry_count/$retries..." "debug"
    
    # Perform the health check with curl
    local status_code=$(curl -s -o /dev/null -w "%{http_code}" -m "$timeout" "$health_url" 2>/dev/null || echo "000")
    
    if [ "$status_code" = "200" ] || [ "$status_code" = "204" ]; then
      bgd_log "Health check passed! Status code: $status_code" "success"
      success=true
      break
    else
      if [ "$retry_count" -lt "$retries" ]; then
        bgd_log "Health check failed (status: $status_code), retrying in $delay seconds..." "warning"
        sleep "$delay"
      else
        bgd_log "Health check failed after $retries attempts (status: $status_code)" "error"
      fi
    fi
  done
  
  if [ "$success" = true ]; then
    return 0
  else
    return 1
  fi
}

# Main function to orchestrate health checks
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
  
  # Set environment if not specified
  if [ -z "${ENVIRONMENT:-}" ]; then
    ENVIRONMENT="both"
  fi
  
  # Validate environment parameter
  if [ "$ENVIRONMENT" != "blue" ] && [ "$ENVIRONMENT" != "green" ] && [ "$ENVIRONMENT" != "both" ]; then
    bgd_log "Invalid environment parameter. Use 'blue', 'green', or 'both'" "error"
    exit 1
  fi
  
  # Set defaults for optional parameters
  ENDPOINT="${ENDPOINT:-/health}"
  RETRIES="${RETRIES:-12}"
  DELAY="${DELAY:-5}"
  TIMEOUT="${TIMEOUT:-3}"
  EXIT_CODE="${EXIT_CODE:-false}"
  
  # Check both environments if requested
  if [ "$ENVIRONMENT" = "both" ]; then
    local blue_result=0
    local green_result=0
    
    bgd_log "Checking health for both blue and green environments" "info"
    
    # Check blue environment
    if ! bgd_check_app_health "$APP_NAME" "blue" "$ENDPOINT" "$RETRIES" "$DELAY" "$TIMEOUT"; then
      blue_result=1
    fi
    
    # Check green environment
    if ! bgd_check_app_health "$APP_NAME" "green" "$ENDPOINT" "$RETRIES" "$DELAY" "$TIMEOUT"; then
      green_result=1
    fi
    
    # Summarize results
    if [ $blue_result -eq 0 ] && [ $green_result -eq 0 ]; then
      bgd_log "Health checks passed for both environments" "success"
      exit 0
    elif [ $blue_result -eq 0 ]; then
      bgd_log "Health check passed for blue environment, failed for green" "warning"
      [ "$EXIT_CODE" = "true" ] && exit 1 || exit 0
    elif [ $green_result -eq 0 ]; then
      bgd_log "Health check passed for green environment, failed for blue" "warning"
      [ "$EXIT_CODE" = "true" ] && exit 1 || exit 0
    else
      bgd_log "Health checks failed for both environments" "error"
      exit 1
    fi
  else
    # Check single environment
    if bgd_check_app_health "$APP_NAME" "$ENVIRONMENT" "$ENDPOINT" "$RETRIES" "$DELAY" "$TIMEOUT"; then
      bgd_log "Health check passed for $ENVIRONMENT environment" "success"
      exit 0
    else
      bgd_log "Health check failed for $ENVIRONMENT environment" "error"
      [ "$EXIT_CODE" = "true" ] && exit 1 || exit 0
    fi
  fi
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_main "$@"
fi