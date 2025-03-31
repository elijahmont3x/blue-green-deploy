#!/bin/bash
#
# bgd-install-templates.sh - Template installation utility for Blue/Green Deployment
#
# This script installs and manages templates for the BGD system

set -euo pipefail

# Get script directory and load core module
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Display help information
bgd_show_help() {
  cat << EOL
=================================================================
Blue/Green Deployment System - Template Installation Utility
=================================================================

USAGE:
  ./bgd-install-templates.sh [OPTIONS]

OPTIONS:
  --custom-dir=PATH    Install templates from a custom directory
  --builtin            Install built-in templates (default)
  --overwrite          Overwrite existing templates
  --force              Force installation, ignore errors
  --list               List available templates
  --help               Show this help message

EXAMPLES:
  # Install built-in templates
  ./bgd-install-templates.sh

  # Install templates from a custom directory
  ./bgd-install-templates.sh --custom-dir=/path/to/templates

  # List available templates
  ./bgd-install-templates.sh --list

=================================================================
EOL
}

# List available templates
bgd_list_templates() {
  bgd_log "Available templates:" "info"
  
  echo "Built-in templates:"
  echo "  - nginx-single-env.conf.template"
  echo "  - nginx-dual-env.conf.template"
  echo "  - docker-compose.override.template"
  echo "  - caching.conf"
  echo "  - rate-limiting.conf"
  echo "  - app-locations.conf.template"
  echo ""
  echo "Partial templates:"
  echo "  - ssl-server-block.template"
  echo "  - subdomain-block.template"
  
  # Check if custom templates directory is provided
  if [ -n "${CUSTOM_DIR:-}" ] && [ -d "$CUSTOM_DIR" ]; then
    echo ""
    echo "Custom templates in $CUSTOM_DIR:"
    find "$CUSTOM_DIR" -name "*.template" -o -name "*.conf" | sort | sed 's/^/  - /'
  fi
  
  return 0
}

# Install a template file
bgd_install_template() {
  local source_file="$1"
  local target_dir="$2"
  local target_file="$3"
  local overwrite="${4:-false}"
  
  # Check if source file exists
  if [ ! -f "$source_file" ]; then
    bgd_log "Source template not found: $source_file" "error"
    return 1
  fi
  
  # Create target directory if it doesn't exist
  bgd_ensure_directory "$target_dir"
  
  # Full path to target file
  local full_target="$target_dir/$target_file"
  
  # Check if target already exists and overwrite is not enabled
  if [ -f "$full_target" ] && [ "$overwrite" != "true" ]; then
    bgd_log "Target already exists, skipping: $full_target" "info"
    return 0
  fi
  
  # Copy the template
  cp "$source_file" "$full_target" || {
    bgd_log "Failed to copy template: $source_file -> $full_target" "error"
    return 1
  }
  
  bgd_log "Installed template: $target_file" "success"
  return 0
}

# Install built-in templates
bgd_install_builtin_templates() {
  local target_dir="$1"
  local overwrite="${2:-false}"
  local force="${3:-false}"
  
  bgd_log "Installing built-in templates to $target_dir" "info"
  
  # Create target directories
  bgd_ensure_directory "$target_dir"
  bgd_ensure_directory "$target_dir/partials"
  
  # Install main templates
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local templates_dir="$script_dir/../config/templates"
  
  # Check if built-in templates directory exists
  if [ ! -d "$templates_dir" ]; then
    bgd_log "Built-in templates directory not found: $templates_dir" "error"
    return 1
  fi
  
  # Main templates
  local main_templates=(
    "nginx-single-env.conf.template"
    "nginx-dual-env.conf.template"
    "docker-compose.override.template"
    "caching.conf"
    "rate-limiting.conf"
    "app-locations.conf.template"
  )
  
  # Partial templates
  local partial_templates=(
    "ssl-server-block.template"
    "subdomain-block.template"
  )
  
  # Install main templates
  local success=true
  for template in "${main_templates[@]}"; do
    if ! bgd_install_template "$templates_dir/$template" "$target_dir" "$template" "$overwrite"; then
      if [ "$force" != "true" ]; then
        success=false
        bgd_log "Failed to install template: $template" "error"
      else
        bgd_log "Failed to install template $template, but continuing due to --force" "warning"
      fi
    fi
  done
  
  # Install partial templates
  for template in "${partial_templates[@]}"; do
    if ! bgd_install_template "$templates_dir/partials/$template" "$target_dir/partials" "$template" "$overwrite"; then
      if [ "$force" != "true" ]; then
        success=false
        bgd_log "Failed to install partial template: $template" "error"
      else
        bgd_log "Failed to install partial template $template, but continuing due to --force" "warning"
      fi
    fi
  done
  
  if [ "$success" = true ]; then
    bgd_log "All built-in templates installed successfully" "success"
    return 0
  else
    bgd_log "Some templates failed to install" "warning"
    return 1
  fi
}

# Install templates from a custom directory
bgd_install_custom_templates() {
  local source_dir="$1"
  local target_dir="$2"
  local overwrite="${3:-false}"
  local force="${4:-false}"
  
  bgd_log "Installing custom templates from $source_dir to $target_dir" "info"
  
  # Check if source directory exists
  if [ ! -d "$source_dir" ]; then
    bgd_log "Custom templates directory not found: $source_dir" "error"
    return 1
  fi
  
  # Create target directory if it doesn't exist
  bgd_ensure_directory "$target_dir"
  
  # Find all template files in the source directory (non-recursively)
  local templates=$(find "$source_dir" -maxdepth 1 -name "*.template" -o -name "*.conf")
  
  # Install each template
  local success=true
  for template in $templates; do
    local template_name=$(basename "$template")
    if ! bgd_install_template "$template" "$target_dir" "$template_name" "$overwrite"; then
      if [ "$force" != "true" ]; then
        success=false
        bgd_log "Failed to install custom template: $template_name" "error"
      else
        bgd_log "Failed to install custom template $template_name, but continuing due to --force" "warning"
      fi
    fi
  done
  
  # Check for a partials directory in the source
  if [ -d "$source_dir/partials" ]; then
    bgd_ensure_directory "$target_dir/partials"
    
    # Find all partial templates
    local partials=$(find "$source_dir/partials" -maxdepth 1 -name "*.template" -o -name "*.conf")
    
    # Install each partial template
    for partial in $partials; do
      local partial_name=$(basename "$partial")
      if ! bgd_install_template "$partial" "$target_dir/partials" "$partial_name" "$overwrite"; then
        if [ "$force" != "true" ]; then
          success=false
          bgd_log "Failed to install custom partial template: $partial_name" "error"
        else
          bgd_log "Failed to install custom partial template $partial_name, but continuing due to --force" "warning"
        fi
      fi
    done
  fi
  
  if [ "$success" = true ]; then
    bgd_log "All custom templates installed successfully" "success"
    return 0
  else
    bgd_log "Some custom templates failed to install" "warning"
    return 1
  fi
}

# Main function
bgd_main() {
  # Parse command line arguments
  bgd_parse_parameters "$@"
  
  # Show help if requested
  if [ "${HELP:-false}" = "true" ]; then
    bgd_show_help
    exit 0
  fi
  
  # List templates if requested
  if [ "${LIST:-false}" = "true" ]; then
    bgd_list_templates
    exit 0
  fi
  
  # Set defaults for optional parameters
  BUILTIN="${BUILTIN:-true}"
  OVERWRITE="${OVERWRITE:-false}"
  FORCE="${FORCE:-false}"
  
  # Get target directory
  local target_dir="${BGD_TEMPLATES_DIR}"
  
  # Install templates
  if [ -n "${CUSTOM_DIR:-}" ]; then
    # Install custom templates
    if bgd_install_custom_templates "$CUSTOM_DIR" "$target_dir" "$OVERWRITE" "$FORCE"; then
      exit 0
    else
      exit 1
    fi
  elif [ "$BUILTIN" = "true" ]; then
    # Install built-in templates
    if bgd_install_builtin_templates "$target_dir" "$OVERWRITE" "$FORCE"; then
      exit 0
    else
      exit 1
    fi
  else
    bgd_log "No templates to install" "error"
    exit 1
  fi
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_main "$@"
fi
