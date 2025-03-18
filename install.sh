#!/bin/bash
#
# install.sh - Initializes the blue/green deployment system
#
# Usage:
#   chmod +x ./install.sh  # Make this script executable first
#   ./install.sh [APP_NAME]
#
# Arguments:
#   APP_NAME     Name of your application (default: "app")

set -euo pipefail

# Make myself executable if needed
if [[ ! -x "$0" ]]; then
  echo "Making installer executable..."
  chmod +x "$0"
  exec "$0" "$@"  # Re-execute with proper permissions
  exit $?         # Should not reach here
fi

# Default values
APP_NAME=${1:-"app"}

echo "Initializing blue/green deployment system for $APP_NAME"

# Create essential directory structure
mkdir -p "scripts"
mkdir -p "config/templates"
mkdir -p "plugins"
mkdir -p "logs"

# Define current script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define only the essential files needed for production
ESSENTIAL_SCRIPTS=(
  "common.sh"
  "deploy.sh"
  "cutover.sh"
  "rollback.sh"
  "cleanup.sh"
  "health-check.sh"
)

# Copy scripts and ensure they're all executable
echo "Installing essential deployment scripts..."
for script in "${ESSENTIAL_SCRIPTS[@]}"; do
  script_path="$SCRIPT_DIR/scripts/$script"
  
  if [ -f "$script_path" ]; then
    cp "$script_path" "scripts/"
    chmod +x "scripts/$script"
    echo "  ✓ $script"
  else
    echo "  ✗ $script not found"
  fi
done

# Essential templates
ESSENTIAL_TEMPLATES=(
  "nginx-single-env.conf.template"
  "nginx-dual-env.conf.template"
  "docker-compose.override.template"
)

# Copy templates
echo "Installing essential configuration templates..."
for template in "${ESSENTIAL_TEMPLATES[@]}"; do
  template_path="$SCRIPT_DIR/config/templates/$template"
  
  if [ -f "$template_path" ]; then
    cp "$template_path" "config/templates/"
    echo "  ✓ $template"
  else
    echo "  ✗ $template not found"
  fi
done

echo
echo "✅ Installation completed successfully!"
echo "System is ready for deployment with:"
echo "  ./scripts/deploy.sh VERSION --app-name=$APP_NAME [OPTIONS]"
echo