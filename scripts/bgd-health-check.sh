#!/bin/bash
#
# bgd-health-check.sh - Checks if a service is healthy by polling its health endpoint
#
# Usage:
#   ./health-check.sh [ENDPOINT] [OPTIONS]
#
# Arguments:
#   ENDPOINT              URL to check (default: http://localhost:3000/health)
#
# Options:
#   --app-name=NAME       Application name
#   --retries=N           Number of health check retries (default: 5)
#   --delay=SEC           Delay between health checks (default: 10)
#   --timeout=SEC         Timeout for each request (default: 5)

set -euo pipefail

# Get script directory
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Main health check function
bgd_health_check() {
  # Default endpoint from first argument or default value
  ENDPOINT=${1:-"http://localhost:3000/health"}

  # If we have more arguments, assume they're parameters
  if [ $# -gt 1 ]; then
    shift
    # Parse command-line parameters
    bgd_parse_parameters "$@" || {
      bgd_log_error "Invalid parameters"
      return 1
    }
  fi

  # Use provided or default values
  RETRIES=${HEALTH_RETRIES:-5}
  DELAY=${HEALTH_DELAY:-10}
  TIMEOUT=${TIMEOUT:-5}

  bgd_log_info "Checking health of $ENDPOINT (retries: $RETRIES, delay: ${DELAY}s, timeout: ${TIMEOUT}s)"

  local count=0
  while [ $count -lt $RETRIES ]; do
    response=$(curl -s -m "$TIMEOUT" "$ENDPOINT" 2>/dev/null || echo "Connection failed")
    
    # Try multiple success conditions:
    # 1. JSON with status field containing "healthy"
    # 2. Plain text containing "healthy"
    # 3. Status code 200 as a fallback
    if echo "$response" | grep -qi "\"status\".*healthy" || 
      echo "$response" | grep -qi "healthy" || 
      curl -s -o /dev/null -w "%{http_code}" -m "$TIMEOUT" "$ENDPOINT" 2>/dev/null | grep -q "200"; then
      bgd_log_success "Health check passed!"
      return 0
    fi
    
    count=$((count + 1))
    if [ $count -lt $RETRIES ]; then
      bgd_log_info "Health check failed, retrying in ${DELAY}s... ($count/$RETRIES)"
      bgd_log_info "Response: $response"
      sleep $DELAY
    fi
  done

  bgd_log_error "Service failed to become healthy after $RETRIES attempts"
  # Get logs for debugging if app name is provided
  if [ -n "${APP_NAME:-}" ]; then
    bgd_log_info "Container logs for ${APP_NAME}:"
    local docker_compose=$(bgd_get_docker_compose_cmd)
    $docker_compose -p "$APP_NAME" logs --tail=50 || true
  fi
  return 1
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_health_check "$@"
  exit $?
fi
