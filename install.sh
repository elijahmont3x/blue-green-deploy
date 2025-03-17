#!/bin/bash
#
# install.sh - Initializes the blue/green deployment system
#
# Usage:
#   chmod +x ./install.sh  # Make this script executable first
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

# Detect installation type and provide appropriate guidance
if [[ "$INSTALL_DIR" == *"tools"* ]] || [[ "$INSTALL_DIR" == *"tools/blue-green-deploy"* ]]; then
  echo "⚠️  Installing in central tools directory."
  echo "   When using centralized deployment, you will need to specify the project directory:"
  echo "   ./scripts/deploy.sh VERSION --app-name=project --project-dir=/path/to/project [OPTIONS]"
  
  # For centralized deployment, recommend logs directory outside of tools
  echo "   For centralized logging, use: --logs-dir=/apps/your-org/logs"
else
  echo "✓ Installing in project-specific directory."
  echo "   Logs will be stored in $INSTALL_DIR/logs by default."
fi

# Create essential directory structure
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$INSTALL_DIR/config/templates"
mkdir -p "$INSTALL_DIR/plugins"
mkdir -p "$INSTALL_DIR/logs"  # Create logs directory instead of .deployment_logs

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
    cp "$script_path" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/$script"
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
    cp "$template_path" "$INSTALL_DIR/config/templates/"
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