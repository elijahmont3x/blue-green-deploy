#!/bin/bash
#
# bgd-health-check.sh - Checks if a service is healthy by polling its health endpoint
#
# Usage:
#   ./bgd-health-check.sh [ENDPOINT] [OPTIONS]
#
# Arguments:
#   ENDPOINT                URL to check

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
  ./bgd-health-check.sh [ENDPOINT] [OPTIONS]

ARGUMENTS:
  ENDPOINT                  URL to check (e.g., http://localhost:8081/health)

HEALTH CHECK OPTIONS:
  --app-name=NAME           Application name
  --retries=N               Number of health check retries (default: 12)
  --delay=SEC               Delay between health checks (default: 5)
  --timeout=SEC             Timeout for each request (default: 5)
  --retry-backoff           Use exponential backoff for retries
  --collect-logs            Collect container logs on failure
  --max-log-lines=N         Maximum number of log lines to collect (default: 100)

EXAMPLES:
  # Basic health check
  ./bgd-health-check.sh http://localhost:8081/health

  # Advanced health check with backoff and logging
  ./bgd-health-check.sh http://localhost:8081/health --app-name=myapp --retries=10 --delay=5 --retry-backoff --collect-logs

=================================================================
EOL
}

# Main health check function
bgd_health_check_main() {
  # Check for help flag first
  if [[ "$1" == "--help" ]]; then
    bgd_show_help
    return 0
  fi

  # Default endpoint from first argument or default value
  ENDPOINT=${1:-"http://localhost:3000/health"}

  # If we have more arguments, assume they're parameters
  if [ $# -gt 1 ]; then
    shift
    # Parse command-line parameters
    bgd_parse_parameters "$@"
  fi

  # Use provided or default values
  HEALTH_RETRIES=${HEALTH_RETRIES:-12}
  HEALTH_DELAY=${HEALTH_DELAY:-5}
  TIMEOUT=${TIMEOUT:-5}
  COLLECT_LOGS=${COLLECT_LOGS:-true}
  MAX_LOG_LINES=${MAX_LOG_LINES:-100}
  RETRY_BACKOFF=${RETRY_BACKOFF:-false}

  # Check health using core function
  if bgd_check_health "$ENDPOINT" "$HEALTH_RETRIES" "$HEALTH_DELAY" "$TIMEOUT"; then
    bgd_log "Health check passed for $ENDPOINT" "success"
    return 0
  else
    # If app name is provided, collect logs
    if [ -n "${APP_NAME:-}" ] && [ "${COLLECT_LOGS}" = "true" ]; then
      bgd_log "Health check failed, collecting logs" "info"
      
      # Try different container name patterns
      local container_patterns=(
        "${APP_NAME}-${TARGET_ENV:-blue}-app"
        "${APP_NAME}-${TARGET_ENV:-blue}"
        "${APP_NAME}-app"
        "${APP_NAME}"
      )
      
      for pattern in "${container_patterns[@]}"; do
        local containers=$(docker ps -a --filter "name=$pattern" --format "{{.Names}}")
        
        if [ -n "$containers" ]; then
          for container in $containers; do
            bgd_log "Container logs for $container:" "info"
            docker logs --tail="$MAX_LOG_LINES" "$container" 2>&1 || true
          done
        fi
      done
    fi
    
    bgd_log "Health check failed for $ENDPOINT" "error"
    return 1
  fi
}

# If this script is being executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_health_check_main "$@"
  exit $?
fi