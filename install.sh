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

# Get script's absolute directory path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine the target directory
if [[ "$APP_NAME" == /* ]]; then
  # If APP_NAME is an absolute path, use it as the target directory
  TARGET_DIR="$APP_NAME"
else
  # If APP_NAME is not an absolute path, create target in current directory
  TARGET_DIR="$(pwd)/$APP_NAME"
fi

# Create essential directory structure in the target directory
mkdir -p "$TARGET_DIR/scripts"
mkdir -p "$TARGET_DIR/config/templates"
mkdir -p "$TARGET_DIR/plugins"
mkdir -p "$TARGET_DIR/logs"
mkdir -p "$TARGET_DIR/certs"
mkdir -p "$TARGET_DIR/credentials"
mkdir -p "$TARGET_DIR/docs"

# Define core scripts (namespaced implementation files)
CORE_SCRIPTS=(
  "bgd-core.sh"
  "bgd-deploy.sh"
  "bgd-cutover.sh"
  "bgd-rollback.sh"
  "bgd-cleanup.sh"
  "bgd-health-check.sh"
  "bgd-nginx-template.sh"
)

# Copy core scripts and ensure they're all executable
echo "Installing core implementation files..."
for script in "${CORE_SCRIPTS[@]}"; do
  script_path="$SCRIPT_DIR/scripts/$script"
  target_path="$TARGET_DIR/scripts/$script"
  
  # Skip if source and target are the same file
  if [ -f "$script_path" ] && [ "$script_path" != "$target_path" ]; then
    cp "$script_path" "$target_path"
    chmod +x "$target_path"
    echo "  ✓ $script"
  elif [ "$script_path" = "$target_path" ]; then
    # If source and target are the same, just ensure it's executable
    chmod +x "$script_path"
    echo "  ✓ $script (already in place)"
  else
    echo "  ✗ $script not found (skipping)"
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
  target_path="$TARGET_DIR/config/templates/$template"
  
  # Skip if source and target are the same file
  if [ -f "$template_path" ] && [ "$template_path" != "$target_path" ]; then
    cp "$template_path" "$target_path"
    echo "  ✓ $template"
  elif [ "$template_path" = "$target_path" ]; then
    echo "  ✓ $template (already in place)"
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
      target_path="$TARGET_DIR/plugins/$plugin_name"
      
      # Skip if source and target are the same file
      if [ "$plugin" != "$target_path" ]; then
        cp "$plugin" "$target_path"
        chmod +x "$target_path"
        echo "  ✓ $plugin_name (plugin)"
      else
        # If source and target are the same, just ensure it's executable
        chmod +x "$plugin"
        echo "  ✓ $plugin_name (plugin, already in place)"
      fi
    fi
  done
else
  echo "No plugins directory found, skipping plugin installation."
  mkdir -p "$TARGET_DIR/plugins"
fi

# Create .gitignore file
echo "Creating .gitignore file..."
cat > "$TARGET_DIR/.gitignore" << EOL
# Blue/Green Deployment specific
logs/
certs/
credentials/
*.log
service-registry.json
.env.*
renew-ssl.sh

# Terraform
.terraform/
*.tfstate
*.tfstate.backup
*.tfvars

# Environment
.env
.venv
env/
venv/
ENV/

# Temporary files
*.swp
*.swo
.DS_Store
tmp/
EOL

echo
echo "✅ Installation completed successfully!"
echo "System is ready for deployment with:"
echo "  $TARGET_DIR/scripts/bgd-deploy.sh VERSION --app-name=$APP_NAME [OPTIONS]"
echo
echo "For multi-container deployment with shared services:"
echo "  $TARGET_DIR/scripts/bgd-deploy.sh VERSION --app-name=$APP_NAME --setup-shared --domain-name=yourdomain.com"
echo