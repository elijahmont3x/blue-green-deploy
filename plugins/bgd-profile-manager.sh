#!/bin/bash
#
# bgd-profile-manager.sh - Environment Profile Manager Plugin for Blue/Green Deployment
#
# This plugin manages deployment environment profiles:
# - Environment-specific configurations
# - Variable substitution in templates
# - Profile activation and switching

# Register plugin arguments
bgd_register_profile_manager_arguments() {
  bgd_register_plugin_argument "profile-manager" "PROFILE_ENABLED" "false"
  bgd_register_plugin_argument "profile-manager" "PROFILE_DIR" "./profiles"
  bgd_register_plugin_argument "profile-manager" "DEFAULT_PROFILE" "default"
  bgd_register_plugin_argument "profile-manager" "CURRENT_PROFILE" ""
  bgd_register_plugin_argument "profile-manager" "PROFILE_INHERITANCE" "true"
  bgd_register_plugin_argument "profile-manager" "ENVIRONMENT_SPECIFIC" "true"
}

# Create default profile structure if it doesn't exist
bgd_create_default_profile() {
  local profile_dir="${PROFILE_DIR:-./profiles}"
  local default_profile="${DEFAULT_PROFILE:-default}"
  local profile_path="$profile_dir/$default_profile"
  
  bgd_log "Creating default profile structure at $profile_path" "info"
  
  # Create directory structure
  bgd_ensure_directory "$profile_path"
  bgd_ensure_directory "$profile_path/templates"
  bgd_ensure_directory "$profile_path/env"
  
  # Create default environment file if it doesn't exist
  if [ ! -f "$profile_path/env/common.env" ]; then
    cat > "$profile_path/env/common.env" << 'EOL'
# Common environment variables for all environments
LOG_LEVEL=info
DEFAULT_PORT=3000
HEALTH_ENDPOINT=/health
HEALTH_RETRIES=12
HEALTH_DELAY=5
EOL
  fi
  
  # Create environment-specific files if they don't exist
  if [ ! -f "$profile_path/env/blue.env" ]; then
    cat > "$profile_path/env/blue.env" << 'EOL'
# Blue environment-specific variables
ENV_NAME=blue
PORT=8081
EOL
  fi
  
  if [ ! -f "$profile_path/env/green.env" ]; then
    cat > "$profile_path/env/green.env" << 'EOL'
# Green environment-specific variables
ENV_NAME=green
PORT=8082
EOL
  fi
  
  # Create a default README to explain the profile system
  if [ ! -f "$profile_path/README.md" ]; then
    cat > "$profile_path/README.md" << 'EOL'
# Deployment Profile

This directory contains environment configuration profiles for the Blue/Green Deployment system.

## Structure

- `env/` - Environment variable files
  - `common.env` - Variables shared by all environments
  - `blue.env` - Blue environment specific variables
  - `green.env` - Green environment specific variables
  - `production.env` - Production overrides
  - `development.env` - Development overrides

- `templates/` - Custom templates for this profile
  - Override any templates from the main template directory

## Usage

Activate a profile with:

```bash
./scripts/bgd-profile.sh --activate=profile_name
```

Create a new profile with:

```bash
./scripts/bgd-profile.sh --create=new_profile_name
```

List available profiles:

```bash
./scripts/bgd-profile.sh --list
```
EOL
  fi
  
  bgd_log "Default profile structure created at $profile_path" "success"
  return 0
}

# Initialize profile system
bgd_init_profiles() {
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  
  # Create directory if it doesn't exist
  bgd_ensure_directory "$profile_dir"
  
  # Check if default profile exists, create if not
  local default_profile="${DEFAULT_PROFILE:-default}"
  local default_profile_path="$profile_dir/$default_profile"
  
  if [ ! -d "$default_profile_path" ]; then
    bgd_log "Default profile does not exist, creating it" "info"
    bgd_create_default_profile
  fi
  
  # Set current profile if not set
  if [ -z "${CURRENT_PROFILE}" ]; then
    export CURRENT_PROFILE="$default_profile"
  fi
  
  bgd_log "Profile system initialized with profile: $CURRENT_PROFILE" "info"
  return 0
}

# Load a specific profile
bgd_load_profile() {
  local profile_name="${1:-${CURRENT_PROFILE:-${DEFAULT_PROFILE:-default}}}"
  local env_name="${2:-}"
  
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  local profile_path="$profile_dir/$profile_name"
  
  if [ ! -d "$profile_path" ]; then
    bgd_log "Profile not found: $profile_name" "error"
    return 1
  fi
  
  bgd_log "Loading profile: $profile_name" "info"
  
  # First load common variables
  local common_env="$profile_path/env/common.env"
  if [ -f "$common_env" ]; then
    bgd_log "Loading common environment variables from $common_env" "debug"
    set -a
    source "$common_env"
    set +a
  fi
  
  # Then load environment-specific variables if requested
  if [ -n "$env_name" ] && [ "${ENVIRONMENT_SPECIFIC:-true}" = "true" ]; then
    local env_file="$profile_path/env/$env_name.env"
    if [ -f "$env_file" ]; then
      bgd_log "Loading $env_name environment variables from $env_file" "debug"
      set -a
      source "$env_file"
      set +a
    else
      bgd_log "Environment file not found: $env_file" "warning"
    fi
  fi
  
  # Load parent profile if inheritance is enabled and parent is specified
  if [ "${PROFILE_INHERITANCE:-true}" = "true" ]; then
    local parent_profile=""
    
    # Check if PARENT_PROFILE is defined in the current profile's common.env
    if [ -n "${PARENT_PROFILE:-}" ]; then
      parent_profile="$PARENT_PROFILE"
      
      # Avoid circular references
      if [ "$parent_profile" = "$profile_name" ]; then
        bgd_log "Circular profile inheritance detected, skipping parent" "warning"
      else
        bgd_log "Loading parent profile: $parent_profile" "debug"
        bgd_load_profile "$parent_profile" "$env_name"
      fi
    fi
  fi
  
  # Set current profile
  export CURRENT_PROFILE="$profile_name"
  
  # Override templates if profile has custom templates
  local template_dir="$profile_path/templates"
  if [ -d "$template_dir" ] && [ -n "$(ls -A "$template_dir" 2>/dev/null)" ]; then
    bgd_log "Using custom templates from profile: $profile_name" "info"
    export BGD_TEMPLATES_DIR="$template_dir"
  fi
  
  bgd_log "Profile loaded: $profile_name" "success"
  return 0
}

# Create a new profile
bgd_create_profile() {
  local new_profile="$1"
  local base_profile="${2:-${DEFAULT_PROFILE:-default}}"
  
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    bgd_log "Profile system is disabled" "warning"
    return 1
  fi
  
  if [ -z "$new_profile" ]; then
    bgd_log "Profile name not specified" "error"
    return 1
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  local new_profile_path="$profile_dir/$new_profile"
  local base_profile_path="$profile_dir/$base_profile"
  
  # Check if new profile already exists
  if [ -d "$new_profile_path" ]; then
    bgd_log "Profile already exists: $new_profile" "error"
    return 1
  fi
  
  # Check if base profile exists
  if [ ! -d "$base_profile_path" ]; then
    bgd_log "Base profile not found: $base_profile" "error"
    return 1
  fi
  
  bgd_log "Creating new profile: $new_profile based on $base_profile" "info"
  
  # Create directory structure
  bgd_ensure_directory "$new_profile_path"
  bgd_ensure_directory "$new_profile_path/templates"
  bgd_ensure_directory "$new_profile_path/env"
  
  # Copy environment files from base profile
  cp -r "$base_profile_path/env/"* "$new_profile_path/env/"
  
  # Update common.env to reference parent profile
  local common_env="$new_profile_path/env/common.env"
  if [ -f "$common_env" ]; then
    echo "# Inherits from parent profile" >> "$common_env"
    echo "PARENT_PROFILE=$base_profile" >> "$common_env"
  fi
  
  bgd_log "New profile created: $new_profile" "success"
  return 0
}

# List all available profiles
bgd_list_profiles() {
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    bgd_log "Profile system is disabled" "warning"
    return 1
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  
  if [ ! -d "$profile_dir" ]; then
    bgd_log "Profile directory not found: $profile_dir" "error"
    return 1
  fi
  
  bgd_log "Available profiles:" "info"
  
  # List all subdirectories in the profiles directory
  local profiles=""
  for dir in "$profile_dir"/*; do
    if [ -d "$dir" ]; then
      local profile_name=$(basename "$dir")
      
      # Mark current profile with an asterisk
      if [ "$profile_name" = "${CURRENT_PROFILE:-}" ]; then
        profile_name="* $profile_name (active)"
      fi
      
      echo "  - $profile_name"
      profiles="1"
    fi
  done
  
  if [ -z "$profiles" ]; then
    bgd_log "No profiles found" "warning"
    return 1
  fi
  
  return 0
}

# Delete a profile
bgd_delete_profile() {
  local profile_name="$1"
  local force="${2:-false}"
  
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    bgd_log "Profile system is disabled" "warning"
    return 1
  fi
  
  if [ -z "$profile_name" ]; then
    bgd_log "Profile name not specified" "error"
    return 1
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  local profile_path="$profile_dir/$profile_name"
  
  # Check if profile exists
  if [ ! -d "$profile_path" ]; then
    bgd_log "Profile not found: $profile_name" "error"
    return 1
  fi
  
  # Check if it's the default profile
  if [ "$profile_name" = "${DEFAULT_PROFILE:-default}" ] && [ "$force" != "true" ]; then
    bgd_log "Cannot delete default profile without --force" "error"
    return 1
  fi
  
  # Check if it's the current profile
  if [ "$profile_name" = "${CURRENT_PROFILE:-}" ] && [ "$force" != "true" ]; then
    bgd_log "Cannot delete active profile without --force" "error"
    return 1
  fi
  
  bgd_log "Deleting profile: $profile_name" "info"
  
  rm -rf "$profile_path"
  
  bgd_log "Profile deleted: $profile_name" "success"
  return 0
}

# Export a profile to a file
bgd_export_profile() {
  local profile_name="${1:-${CURRENT_PROFILE:-${DEFAULT_PROFILE:-default}}}"
  local output_file="${2:-$profile_name-profile.tar.gz}"
  
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    bgd_log "Profile system is disabled" "warning"
    return 1
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  local profile_path="$profile_dir/$profile_name"
  
  # Check if profile exists
  if [ ! -d "$profile_path" ]; then
    bgd_log "Profile not found: $profile_name" "error"
    return 1
  fi
  
  bgd_log "Exporting profile: $profile_name to $output_file" "info"
  
  tar -czf "$output_file" -C "$profile_dir" "$profile_name"
  
  bgd_log "Profile exported to: $output_file" "success"
  return 0
}

# Import a profile from a file
bgd_import_profile() {
  local input_file="$1"
  local new_name="${2:-}"
  
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    bgd_log "Profile system is disabled" "warning"
    return 1
  fi
  
  if [ -z "$input_file" ] || [ ! -f "$input_file" ]; then
    bgd_log "Input file not found: $input_file" "error"
    return 1
  fi
  
  local profile_dir="${PROFILE_DIR:-./profiles}"
  
  bgd_log "Importing profile from: $input_file" "info"
  
  # Create temporary directory for extraction
  local temp_dir=$(mktemp -d)
  
  # Extract archive
  tar -xzf "$input_file" -C "$temp_dir"
  
  # Find extracted profile directory
  local extracted_profile=""
  for dir in "$temp_dir"/*; do
    if [ -d "$dir" ]; then
      extracted_profile=$(basename "$dir")
      break
    fi
  done
  
  if [ -z "$extracted_profile" ]; then
    bgd_log "No profile found in archive" "error"
    rm -rf "$temp_dir"
    return 1
  fi
  
  # Determine final profile name
  local target_profile="${new_name:-$extracted_profile}"
  local target_path="$profile_dir/$target_profile"
  
  # Check if target profile already exists
  if [ -d "$target_path" ]; then
    bgd_log "Profile already exists: $target_profile" "error"
    rm -rf "$temp_dir"
    return 1
  fi
  
  # Ensure profile directory exists
  bgd_ensure_directory "$profile_dir"
  
  # Move extracted profile to profiles directory
  if [ "$target_profile" = "$extracted_profile" ]; then
    mv "$temp_dir/$extracted_profile" "$profile_dir/"
  else
    mkdir -p "$target_path"
    cp -r "$temp_dir/$extracted_profile/"* "$target_path/"
  fi
  
  # Clean up temporary directory
  rm -rf "$temp_dir"
  
  bgd_log "Profile imported as: $target_profile" "success"
  return 0
}

# Integration with other plugins
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [ "${PROFILE_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  # Initialize profile system
  bgd_init_profiles
  
  # Load current profile
  bgd_load_profile "${CURRENT_PROFILE}" "${TARGET_ENV}"
  
  return $?
}