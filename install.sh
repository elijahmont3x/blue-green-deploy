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
mkdir -p "certs"

# Define current script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define core scripts (namespaced implementation files)
CORE_SCRIPTS=(
  "bgd-core.sh"
  "bgd-deploy.sh"
  "bgd-cutover.sh"
  "bgd-rollback.sh"
  "bgd-cleanup.sh"
  "bgd-health-check.sh"
)

# Copy core scripts and ensure they're all executable
echo "Installing core implementation files..."
for script in "${CORE_SCRIPTS[@]}"; do
  script_path="$SCRIPT_DIR/scripts/$script"
  
  if [ -f "$script_path" ]; then
    cp "$script_path" "scripts/"
    chmod +x "scripts/$script"
    echo "  ✓ $script"
  else
    echo "  ✗ $script not found (skipping)"
  fi
done

# Essential templates
ESSENTIAL_TEMPLATES=(
  "nginx-single-env.conf.template"
  "nginx-dual-env.conf.template"
  "docker-compose.override.template"
  "nginx-multi-domain.conf.template"
)

# Copy templates
echo "Installing essential configuration templates..."
for template in "${ESSENTIAL_TEMPLATES[@]}"; do
  template_path="$SCRIPT_DIR/config/templates/$template"
  
  if [ -f "$template_path" ]; then
    cp "$template_path" "config/templates/"
    echo "  ✓ $template"
  else
    echo "  ✗ $template not found (skipping)"
  fi
done

# Install plugins
echo "Installing plugins..."

# Find only namespaced plugins (bgd-*.sh)
PLUGIN_DIR="$SCRIPT_DIR/plugins"
if [ -d "$PLUGIN_DIR" ]; then
  for plugin in "$PLUGIN_DIR"/bgd-*.sh; do
    if [ -f "$plugin" ]; then
      plugin_name=$(basename "$plugin")
      cp "$plugin" "plugins/"
      chmod +x "plugins/$plugin_name"
      echo "  ✓ $plugin_name (plugin)"
    fi
  done
else
  echo "No plugins directory found, skipping plugin installation."
  mkdir -p "plugins"
fi

echo
echo "✅ Installation completed successfully!"
echo "System is ready for deployment with:"
echo "  ./scripts/bgd-deploy.sh VERSION --app-name=$APP_NAME [OPTIONS]"
echo
echo "For multi-container deployment with shared services:"
echo "  ./scripts/bgd-deploy.sh VERSION --app-name=$APP_NAME --setup-shared --domain-name=yourdomain.com"
echo