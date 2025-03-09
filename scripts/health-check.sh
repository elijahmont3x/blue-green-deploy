#!/bin/bash
#
# health-check.sh - Checks if a service is healthy by polling its health endpoint
#
# Usage:
#   ./health-check.sh [endpoint] [retries] [delay] [timeout]
#
# Arguments:
#   endpoint    URL to check (default: http://localhost:3000/health)
#   retries     Maximum number of retry attempts (default: 5)
#   delay       Seconds to wait between retries (default: 10)
#   timeout     Seconds to wait for each request (default: 5)

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source utility functions
source "$SCRIPT_DIR/common.sh"

ENDPOINT=${1:-"http://localhost:3000/health"}
MAX_RETRIES=${2:-5}
DELAY=${3:-10}
TIMEOUT=${4:-5}

check_health "$ENDPOINT" "$MAX_RETRIES" "$DELAY" "$TIMEOUT"
exit $?