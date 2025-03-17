#!/bin/bash
#
# install.sh - Initializes the blue/green deployment system
#
# Usage:
#   ./install.sh [APP_NAME] [INSTALL_DIR]
#
# Arguments:
#   APP_NAME     Name of your application (default: "app")
#   INSTALL_DIR  Directory to install to (default: current directory)

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
INSTALL_DIR=${2:-"."}

# Ensure INSTALL_DIR is absolute path
if [[ "$INSTALL_DIR" != /* ]]; then
  INSTALL_DIR="$(pwd)/$INSTALL_DIR"
fi

echo "Initializing blue/green deployment system for $APP_NAME in $INSTALL_DIR"

# Create essential directory structure
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$INSTALL_DIR/config/templates"
mkdir -p "$INSTALL_DIR/plugins"
mkdir -p "$INSTALL_DIR/.deployment_logs"

# Define current script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy scripts and ensure they're all executable
echo "Installing deployment scripts..."
for script in "$SCRIPT_DIR/scripts/"*.sh; do
  if [ -f "$script" ]; then
    cp "$script" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/$(basename "$script")"
    echo "  ✓ $(basename "$script")"
  fi
done

# Copy templates
echo "Installing configuration templates..."
for template in "$SCRIPT_DIR/config/templates/"*; do
  if [ -f "$template" ]; then
    cp "$template" "$INSTALL_DIR/config/templates/"
    echo "  ✓ $(basename "$template")"
  fi
done

echo
echo "✅ Installation completed successfully!"
echo "System is ready for deployment with:"
echo "  ./scripts/deploy.sh VERSION --app-name=$APP_NAME [OPTIONS]"
echo