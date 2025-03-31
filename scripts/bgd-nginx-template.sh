#!/bin/bash
#
# bgd-nginx-template.sh - Template processing for Nginx configurations
#
# This script handles template processing for the BGD system's Nginx configurations

set -euo pipefail

# Get script directory and load core module if not already loaded
if [ -z "${BGD_SCRIPT_DIR:-}" ]; then
  BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$BGD_SCRIPT_DIR/bgd-core.sh"
fi

# Default template paths
BGD_NGINX_TEMPLATE_SINGLE="${BGD_TEMPLATES_DIR}/nginx-single-env.conf.template"
BGD_NGINX_TEMPLATE_DUAL="${BGD_TEMPLATES_DIR}/nginx-dual-env.conf.template"

# Check if running directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script should be sourced, not executed directly"
  exit 1
fi

# Process a template file with environment variables
bgd_process_template() {
  local template_file="$1"
  local output_file="$2"
  
  if [ ! -f "$template_file" ]; then
    bgd_log "Template file not found: $template_file" "error"
    return 1
  fi
  
  bgd_log "Processing template: $template_file -> $output_file" "debug"
  
  # Create a temporary file for processing
  local temp_file=$(mktemp)
  
  # Process template with environment variables
  eval "cat <<EOF
$(cat "$template_file")
EOF
" > "$temp_file" 2>/dev/null || {
    bgd_log "Failed to process template with environment variables" "error"
    rm -f "$temp_file"
    return 1
  }
  
  # Process conditional blocks (e.g., {{#VARIABLE}}content{{/VARIABLE}})
  bgd_process_conditional_blocks "$temp_file" "$output_file" || {
    bgd_log "Failed to process conditional blocks" "error" 
    rm -f "$temp_file"
    return 1
  }
  
  # Clean up
  rm -f "$temp_file"
  
  return 0
}

# Process conditional blocks in templates
bgd_process_conditional_blocks() {
  local input_file="$1"
  local output_file="$2"
  
  # Create a temporary file for processing
  local temp_file=$(mktemp)
  
  # Read the input file
  local content=$(cat "$input_file")
  
  # Process conditionals {{#VAR}}content{{/VAR}}
  while [[ "$content" =~ \{\{#([A-Za-z0-9_]+)\}\}(.*?)\{\{/\1\}\} ]]; do
    local var_name="${BASH_REMATCH[1]}"
    local var_content="${BASH_REMATCH[2]}"
    local full_match="${BASH_REMATCH[0]}"
    
    # Check if the variable is defined and non-empty
    if [ -n "${!var_name+x}" ] && [ -n "${!var_name}" ] && [ "${!var_name}" != "false" ] && [ "${!var_name}" != "0" ]; then
      # Variable is true, keep the content
      content=${content//$full_match/$var_content}
    else
      # Variable is false, remove the content
      content=${content//$full_match/}
    fi
  done
  
  # Process inverse conditionals {{^VAR}}content{{/VAR}}
  while [[ "$content" =~ \{\{\^([A-Za-z0-9_]+)\}\}(.*?)\{\{/\1\}\} ]]; do
    local var_name="${BASH_REMATCH[1]}"
    local var_content="${BASH_REMATCH[2]}"
    local full_match="${BASH_REMATCH[0]}"
    
    # Check if the variable is NOT defined or empty
    if [ -z "${!var_name+x}" ] || [ -z "${!var_name}" ] || [ "${!var_name}" = "false" ] || [ "${!var_name}" = "0" ]; then
      # Variable is false, keep the content
      content=${content//$full_match/$var_content}
    else
      # Variable is true, remove the content
      content=${content//$full_match/}
    fi
  done
  
  # Process include statements {{#include:filename}}
  while [[ "$content" =~ \{\{#include:([A-Za-z0-9_-]+)\}\} ]]; do
    local partial_name="${BASH_REMATCH[1]}"
    local full_match="${BASH_REMATCH[0]}"
    
    # Include the partial template
    local partial_content=""
    if partial_content=$(bgd_include_partial "$partial_name"); then
      content=${content//$full_match/$partial_content}
    else
      # If include fails, just remove the include statement
      content=${content//$full_match/}
      bgd_log "Failed to include partial: $partial_name" "warning"
    fi
  done
  
  # Replace simple variables {{VAR}} that remain
  while [[ "$content" =~ \{\{([A-Za-z0-9_]+)\}\} ]]; do
    local var_name="${BASH_REMATCH[1]}"
    local var_value="${!var_name:-}"
    
    content=${content//$BASH_REMATCH[0]/$var_value}
  done
  
  # Write to output file
  echo "$content" > "$output_file" || {
    bgd_log "Failed to write to output file: $output_file" "error"
    rm -f "$temp_file"
    return 1
  }
  
  # Clean up
  rm -f "$temp_file"
  
  return 0
}

# Generate Nginx configuration for single environment
bgd_generate_single_env_nginx_conf() {
  local app_name="$1"
  local env_name="$2"
  
  # Set environment variables for template
  export APP_NAME="$app_name"
  export ENV_NAME="$env_name"
  export TIMESTAMP="$(date)"
  
  # Determine port based on environment
  if [ "$env_name" = "blue" ]; then
    export ENV_PORT="${BLUE_PORT:-8081}"
  else
    export ENV_PORT="${GREEN_PORT:-8082}"
  fi

  # Check if health endpoint is defined
  if [ -n "${HEALTH_ENDPOINT:-}" ]; then
    export HEALTH_PATH="${HEALTH_ENDPOINT}"
  fi
  
  # Check if domain name is defined
  if [ -n "${DOMAIN_NAME:-}" ]; then
    export SERVER_NAME="${DOMAIN_NAME}"
    if [ -n "${DOMAIN_ALIASES:-}" ]; then
      export SERVER_NAME="${DOMAIN_NAME} ${DOMAIN_ALIASES}"
    fi
  fi
  
  # Check if template exists
  local template="${BGD_TEMPLATES_DIR}/nginx-single-env.conf.template"
  if [ ! -f "$template" ]; then
    bgd_log "Nginx single environment template not found: $template" "error"
    return 1
  fi
  
  # Process the template
  local temp_file=$(mktemp)
  if ! bgd_process_template "$template" "$temp_file"; then
    bgd_log "Failed to process Nginx template" "error"
    rm -f "$temp_file"
    return 1
  fi
  
  # Output the processed template
  cat "$temp_file"
  rm -f "$temp_file"
  
  return 0
}

# Generate Nginx configuration for dual environment (weighted routing)
bgd_generate_dual_env_nginx_conf() {
  local app_name="$1"
  local blue_weight="$2"
  local green_weight="$3"
  
  # Set environment variables for template
  export APP_NAME="$app_name"
  export BLUE_WEIGHT="$blue_weight"
  export GREEN_WEIGHT="$green_weight"
  export BLUE_PORT="${BLUE_PORT:-8081}"
  export GREEN_PORT="${GREEN_PORT:-8082}"
  export TIMESTAMP="$(date)"
  
  # Check if health endpoint is defined
  if [ -n "${HEALTH_ENDPOINT:-}" ]; then
    export HEALTH_PATH="${HEALTH_ENDPOINT}"
  fi
  
  # Check if domain name is defined
  if [ -n "${DOMAIN_NAME:-}" ]; then
    export SERVER_NAME="${DOMAIN_NAME}"
    if [ -n "${DOMAIN_ALIASES:-}" ]; then
      export SERVER_NAME="${DOMAIN_NAME} ${DOMAIN_ALIASES}"
    fi
  fi
  
  # Check if template exists
  local template="${BGD_TEMPLATES_DIR}/nginx-dual-env.conf.template"
  if [ ! -f "$template" ]; then
    bgd_log "Nginx dual environment template not found: $template" "error"
    return 1
  fi
  
  # Process the template
  local temp_file=$(mktemp)
  if ! bgd_process_template "$template" "$temp_file"; then
    bgd_log "Failed to process Nginx template" "error"
    rm -f "$temp_file"
    return 1
  fi
  
  # Output the processed template
  cat "$temp_file"
  rm -f "$temp_file"
  
  return 0
}

# Include a partial template
bgd_include_partial() {
  local partial_name="$1"
  local partial_file="${BGD_TEMPLATES_DIR}/partials/${partial_name}.template"
  
  if [ ! -f "$partial_file" ]; then
    bgd_log "Partial template not found: $partial_file" "warning"
    return 1
  fi
  
  # Process the partial template with current environment
  local temp_file=$(mktemp)
  if ! bgd_process_template "$partial_file" "$temp_file"; then
    bgd_log "Failed to process partial template: $partial_name" "warning"
    rm -f "$temp_file"
    return 1
  fi
  
  # Output the processed template
  cat "$temp_file"
  rm -f "$temp_file"
  
  return 0
}

# Validate Nginx configuration
bgd_validate_nginx_conf() {
  local config_file="$1"
  
  if [ ! -f "$config_file" ]; then
    bgd_log "Configuration file not found: $config_file" "error"
    return 1
  fi
  
  bgd_log "Validating Nginx configuration: $config_file" "info"
  
  # Check if docker is available for validation
  if command -v docker &> /dev/null; then
    docker run --rm -v "$(pwd)/$config_file:/etc/nginx/nginx.conf:ro" nginx:stable-alpine nginx -t || {
      bgd_log "Nginx configuration validation failed" "error"
      return 1
    }
  elif command -v nginx &> /dev/null; then
    # Use local nginx if available
    nginx -t -c "$(pwd)/$config_file" || {
      bgd_log "Nginx configuration validation failed" "error"
      return 1
    }
  else
    bgd_log "Neither Docker nor nginx available for validation, skipping" "warning"
    return 0
  fi
  
  bgd_log "Nginx configuration validation passed" "success"
  return 0
}

# Install templates from source directory
bgd_install_templates() {
  local source_dir="$1"
  local force="${2:-false}"
  
  if [ ! -d "$source_dir" ]; then
    bgd_log "Template source directory not found: $source_dir" "error"
    return 1
  fi
  
  bgd_log "Installing templates from $source_dir" "info"
  
  # Ensure destination directory exists
  bgd_ensure_directory "$BGD_TEMPLATES_DIR"
  bgd_ensure_directory "$BGD_TEMPLATES_DIR/partials"
  
  # Copy main templates
  for template in "$source_dir"/*.template; do
    if [ -f "$template" ]; then
      local filename=$(basename "$template")
      local dest_file="$BGD_TEMPLATES_DIR/$filename"
      
      if [ ! -f "$dest_file" ] || [ "$force" = "true" ]; then
        cp "$template" "$dest_file" || {
          bgd_log "Failed to copy template: $template" "error"
          return 1
        }
        bgd_log "Installed template: $filename" "info"
      else
        bgd_log "Template already exists, skipping: $filename" "debug"
      fi
    fi
  done
  
  # Copy partial templates
  for partial in "$source_dir/partials"/*.template; do
    if [ -f "$partial" ]; then
      local filename=$(basename "$partial")
      local dest_file="$BGD_TEMPLATES_DIR/partials/$filename"
      
      if [ ! -f "$dest_file" ] || [ "$force" = "true" ]; then
        cp "$partial" "$dest_file" || {
          bgd_log "Failed to copy partial template: $partial" "error"
          return 1
        }
        bgd_log "Installed partial template: $filename" "info"
      else
        bgd_log "Partial template already exists, skipping: $filename" "debug"
      fi
    fi
  done
  
  # Copy auxiliary configuration files
  for config in "$source_dir"/*.conf; do
    if [ -f "$config" ]; then
      local filename=$(basename "$config")
      local dest_file="$BGD_TEMPLATES_DIR/$filename"
      
      if [ ! -f "$dest_file" ] || [ "$force" = "true" ]; then
        cp "$config" "$dest_file" || {
          bgd_log "Failed to copy configuration: $config" "error"
          return 1
        }
        bgd_log "Installed configuration: $filename" "info"
      else
        bgd_log "Configuration already exists, skipping: $filename" "debug"
      fi
    fi
  done
  
  bgd_log "Templates installed successfully" "success"
  return 0
}

# Self-test function to verify template processor
bgd_test_template_processor() {
  local test_template=$(mktemp)
  
  # Create a test template
  cat > "$test_template" << EOL
# Test Template
App Name: {{APP_NAME}}
Environment: {{ENV_NAME}}
{{#SSL_ENABLED}}
SSL is enabled
{{/SSL_ENABLED}}
{{^SSL_ENABLED}}
SSL is disabled
{{/SSL_ENABLED}}
EOL
  
  # Set test variables
  export APP_NAME="TestApp"
  export ENV_NAME="blue"
  export SSL_ENABLED="true"
  
  # Process the template
  local result=$(bgd_process_template "$test_template")
  
  # Clean up
  rm -f "$test_template"
  
  # Verify result
  if [[ "$result" == *"App Name: TestApp"* ]] && [[ "$result" == *"Environment: blue"* ]] && [[ "$result" == *"SSL is enabled"* ]]; then
    bgd_log "Template processor test passed" "success"
    return 0
  else
    bgd_log "Template processor test failed" "error"
    return 1
  fi
}

# Main function for standalone usage
bgd_nginx_template_main() {
  local command="${1:-generate}"
  shift || true
  
  case "$command" in
    generate)
      local env_type="${1:-single}"
      local app_name="${2:-myapp}"
      
      if [ "$env_type" = "single" ]; then
        local env_name="${3:-blue}"
        bgd_generate_single_env_nginx_conf "$app_name" "$env_name"
      elif [ "$env_type" = "dual" ]; then
        local blue_weight="${3:-50}"
        local green_weight="${4:-50}"
        bgd_generate_dual_env_nginx_conf "$app_name" "$blue_weight" "$green_weight"
      else
        bgd_log "Invalid environment type: $env_type. Use 'single' or 'dual'" "error"
        return 1
      fi
      ;;
      
    install)
      local source_dir="${1:-$BGD_SCRIPT_DIR/../templates}"
      local force="${2:-false}"
      bgd_install_templates "$source_dir" "$force"
      ;;
      
    validate)
      local config_file="${1:-nginx.conf}"
      bgd_validate_nginx_conf "$config_file"
      ;;
      
    test)
      bgd_test_template_processor
      ;;
      
    *)
      bgd_log "Unknown command: $command" "error"
      bgd_log "Valid commands: generate, install, validate, test" "info"
      return 1
      ;;
  esac
  
  return $?
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_nginx_template_main "$@"
fi
