#!/bin/bash
#
# install.sh - Initializes the blue/green deployment system
#
# Usage:
#   chmod +x ./install.sh  # Make this script executable first
#   ./install.sh [INSTALL_DIR] [OPTIONS]
#
# Arguments:
#   INSTALL_DIR           Directory where the system will be installed (default: current directory)
#
# Options:
#   --force-plugins       Force overwrite of existing plugins

set -euo pipefail

# Make myself executable if needed
if [[ ! -x "$0" ]]; then
  echo "Making installer executable..."
  chmod +x "$0"
  exec "$0" "$@"  # Re-execute with proper permissions
  exit $?         # Should not reach here
fi

# Initialize variables
INSTALL_DIR="$(pwd)"   # default installation directory
FORCE_PLUGINS=false

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --force-plugins=*)
      force_val="${1#*=}"
      if [[ "$force_val" =~ ^(true|1)$ ]]; then
        FORCE_PLUGINS=true
      else
        FORCE_PLUGINS=false
      fi
      shift
      ;;
    --*)
      echo "Unknown option: $1"
      exit 1
      ;;
    *)
      # The first non-option argument is the installation directory
      INSTALL_DIR="$1"
      shift
      ;;
  esac
done

echo "Initializing blue/green deployment system in directory: $INSTALL_DIR"

# Get script's absolute directory path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Determine the target directory using INSTALL_DIR (absolute or relative)
if [[ "$INSTALL_DIR" == /* ]]; then
  TARGET_DIR="$INSTALL_DIR"
else
  TARGET_DIR="$(pwd)/$INSTALL_DIR"
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

# Copy core scripts
echo "Installing core implementation files..."
for script in "${CORE_SCRIPTS[@]}"; do
  script_path="$SCRIPT_DIR/scripts/$script"
  target_path="$TARGET_DIR/scripts/$script"
  
  if [ -f "$script_path" ]; then
    if [ "$script_path" != "$target_path" ]; then
      cp "$script_path" "$target_path"
      echo "  ✓ $script"
    else
      echo "  ✓ $script (already in place)"
    fi
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
  
  if [ -f "$template_path" ]; then
    if [ "$template_path" != "$target_path" ]; then
      cp "$template_path" "$target_path"
      echo "  ✓ $template"
    else
      echo "  ✓ $template (already in place)"
    fi
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
      
      # Determine whether to install the plugin based on existence and force flag
      install_plugin=false
      if [ ! -f "$target_path" ]; then
        install_plugin=true
        status_message="✓ $plugin_name (plugin)"
      elif [ "$FORCE_PLUGINS" = true ]; then
        install_plugin=true
        status_message="✓ $plugin_name (plugin, overwritten)"
      else
        status_message="i $plugin_name (plugin, pre-existing - preserved)"
      fi
      
      # Install the plugin if needed
      if [ "$install_plugin" = true ]; then
        if [ "$plugin" != "$target_path" ]; then
          cp "$plugin" "$target_path"
          echo "  $status_message"
        else
          echo "  ✓ $plugin_name (plugin, already in place)"
        fi
      else
        echo "  $status_message"
      fi
    fi
  done
else
  echo "No plugins directory found, skipping plugin installation."
  mkdir -p "$TARGET_DIR/plugins"
fi

# Set executable permissions for all scripts and plugins with verification
echo "Setting executable permissions for scripts and plugins..."
set_and_verify_permissions() {
  local dir="$1"
  local type="$2"
  
  find "$dir" -name "*.sh" -type f | while read -r script; do
    chmod +x "$script"
    if [[ -x "$script" ]]; then
      echo "  ✓ Set executable permission for $(basename "$script") ($type)"
    else
      echo "  ⚠ WARNING: Failed to set executable permission for $(basename "$script") ($type)"
      echo "    You may need to manually run: chmod +x $script"
    fi
  done
}

set_and_verify_permissions "$TARGET_DIR/scripts" "script"
set_and_verify_permissions "$TARGET_DIR/plugins" "plugin"

echo
echo "✅ Installation completed successfully!"
echo "System is ready for deployment with either:"
echo "  $TARGET_DIR/deploy.sh VERSION --app-name=your-app-name [OPTIONS]"
echo "  or"
echo "  $TARGET_DIR/scripts/bgd-deploy.sh VERSION --app-name=your-app-name [OPTIONS]"
echo
echo "For multi-container deployment with shared services:"
echo "  $TARGET_DIR/deploy.sh VERSION --app-name=your-app-name --setup-shared --domain-name=yourdomain.com"
echo
echo "If you still encounter permission issues, please run:"
echo "  chmod -R +x $TARGET_DIR/scripts/*.sh $TARGET_DIR/plugins/*.sh"
echo