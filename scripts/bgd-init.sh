#!/bin/bash
#
# bgd-init.sh - Initialization script for Blue/Green Deployment
#
# This script initializes the Blue/Green Deployment system

set -euo pipefail

# Get script directory and load core module
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BGD_SCRIPT_DIR/bgd-core.sh"

# Display help information
bgd_show_help() {
  cat << EOL
=================================================================
Blue/Green Deployment System - Initialization Script
=================================================================

USAGE:
  ./bgd-init.sh [OPTIONS]

OPTIONS:
  --force                Force re-initialization of the system
  --ssl=DOMAIN          Configure SSL with specified domain
  --email=EMAIL         Email for SSL certificate registration
  --proxy               Initialize master proxy for multiple applications
  --profiles=DIR        Initialize deployment profiles in specified directory
  --templates=DIR       Use custom templates from specified directory
  --help                Show this help message

EXAMPLES:
  # Basic initialization
  ./bgd-init.sh

  # Initialize with SSL
  ./bgd-init.sh --ssl=example.com --email=admin@example.com

  # Initialize master proxy and deployment profiles
  ./bgd-init.sh --proxy --profiles=./profiles

=================================================================
EOL
}

# Initialize system directories
bgd_init_directories() {
  bgd_log "Creating system directories..." "info"
  
  # Create base directories
  bgd_ensure_directory "$BGD_CONFIG_DIR"
  bgd_ensure_directory "$BGD_LOGS_DIR"
  bgd_ensure_directory "$BGD_TEMPLATES_DIR"
  bgd_ensure_directory "$BGD_PLUGINS_DIR"
  bgd_ensure_directory "$BGD_CREDENTIALS_DIR"
  bgd_ensure_directory "${BGD_BASE_DIR}/apps"
  
  # Create subdirectories for templates
  bgd_ensure_directory "$BGD_TEMPLATES_DIR/partials"
  
  bgd_log "System directories created successfully" "success"
  return 0
}

# Install default templates
bgd_install_default_templates() {
  bgd_log "Installing default templates..." "info"
  
  # Check if we have template installation script
  local template_script="${BGD_SCRIPT_DIR}/bgd-install-templates.sh"
  local template_src="${1:-}"
  
  if [ -f "$template_script" ] && [ -x "$template_script" ]; then
    if [ -n "$template_src" ]; then
      # Use specified template source
      "$template_script" --custom-dir="$template_src" --force
    else
      # Use default templates
      "$template_script" --force
    fi
  else
    bgd_log "Template installation script not found: $template_script" "warning"
    return 1
  fi
  
  bgd_log "Templates installed successfully" "success"
  return 0
}

# Initialize environment markers
bgd_init_environment_markers() {
  bgd_log "Initializing environment markers..." "info"
  
  # Set blue as the initial active environment
  echo "blue" > "${BGD_BASE_DIR}/.bgd-active-env"
  echo "green" > "${BGD_BASE_DIR}/.bgd-inactive-env"
  
  bgd_log "Environment markers initialized (blue: active, green: inactive)" "success"
  return 0
}

# Initialize version file
bgd_init_version_file() {
  bgd_log "Creating version file..." "info"
  
  # Create version file in config directory
  echo "1.0.0" > "${BGD_CONFIG_DIR}/version"
  
  bgd_log "Version file created" "success"
  return 0
}

# Initialize configuration
bgd_init_config() {
  bgd_log "Creating configuration files..." "info"
  
  # Create main configuration file
  cat > "${BGD_CONFIG_DIR}/bgd.conf" << EOL
# Blue/Green Deployment Configuration
# Generated: $(date)

# System Configuration
BGD_BASE_DIR=${BGD_BASE_DIR}
BGD_CONFIG_DIR=${BGD_CONFIG_DIR}
BGD_LOGS_DIR=${BGD_LOGS_DIR}
BGD_TEMPLATES_DIR=${BGD_TEMPLATES_DIR}
BGD_PLUGINS_DIR=${BGD_PLUGINS_DIR}
BGD_CREDENTIALS_DIR=${BGD_CREDENTIALS_DIR}

# Default Application Settings
DEFAULT_APP_NAME=myapp
DEFAULT_BLUE_PORT=8081
DEFAULT_GREEN_PORT=8082
DEFAULT_HEALTH_ENDPOINT=/health
DEFAULT_HEALTH_RETRIES=12
DEFAULT_HEALTH_DELAY=5

# Environment Configuration
DEFAULT_NODE_ENV=production
DEFAULT_NGINX_PORT=80
DEFAULT_NGINX_SSL_PORT=443

# Plugin Configuration
PLUGINS_ENABLED=true
EOL
  
  # Create .gitignore file
  cat > "${BGD_BASE_DIR}/.gitignore" << EOL
# Blue/Green Deployment .gitignore

# SSL certificates
/certs/*
!/certs/.gitkeep

# Credentials
/credentials/*
!/credentials/.gitkeep

# Logs
/logs/*
!/logs/.gitkeep

# Application data
/apps/*
!/apps/.gitkeep

# Environment files
.env
apps/**/.env
EOL
  
  # Create empty placeholder files
  touch "${BGD_CREDENTIALS_DIR}/.gitkeep"
  touch "${BGD_LOGS_DIR}/.gitkeep"
  touch "${BGD_BASE_DIR}/apps/.gitkeep"
  
  # Create initialization marker
  touch "${BGD_CONFIG_DIR}/.initialized"
  
  bgd_log "Configuration files created successfully" "success"
  return 0
}

# Initialize SSL (if requested)
bgd_init_ssl() {
  local domain="$1"
  local email="$2"
  
  if [ -z "$domain" ] || [ -z "$email" ]; then
    bgd_log "Domain and email are required for SSL initialization" "error"
    return 1
  fi
  
  bgd_log "Initializing SSL for domain: $domain" "info"
  
  # Create certificates directory
  local cert_dir="${BGD_BASE_DIR}/certs"
  bgd_ensure_directory "$cert_dir"
  
  # Check if SSL plugin is available
  local ssl_plugin="${BGD_PLUGINS_DIR}/bgd-ssl.sh"
  if [ -f "$ssl_plugin" ]; then
    source "$ssl_plugin"
    
    # Store SSL configuration
    export SSL_ENABLED="true"
    export DOMAIN_NAME="$domain"
    export CERTBOT_EMAIL="$email"
    export CERT_PATH="$cert_dir"
    
    # Attempt to obtain certificate
    if declare -f bgd_obtain_ssl_certificates >/dev/null; then
      if bgd_obtain_ssl_certificates "$domain"; then
        bgd_log "SSL certificates obtained successfully" "success"
      else
        bgd_log "Failed to obtain SSL certificates" "warning"
        
        # Generate self-signed certificates as fallback
        if declare -f bgd_generate_self_signed_cert >/dev/null; then
          bgd_log "Generating self-signed certificates as fallback" "info"
          bgd_generate_self_signed_cert "$domain"
        fi
      fi
    else
      bgd_log "SSL plugin functions not available" "warning"
      return 1
    fi
  else
    bgd_log "SSL plugin not found: $ssl_plugin" "warning"
    
    # Generate self-signed certificates
    bgd_log "Generating self-signed certificates" "info"
    
    if command -v openssl &> /dev/null; then
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$cert_dir/privkey.pem" \
        -out "$cert_dir/fullchain.pem" \
        -subj "/CN=$domain/O=Blue Green Deploy/C=US" \
        -addext "subjectAltName = DNS:$domain" \
        2>/dev/null || {
        bgd_log "Failed to generate self-signed certificates" "error"
        return 1
      }
      
      chmod 600 "$cert_dir/privkey.pem" 2>/dev/null || true
      bgd_log "Self-signed certificates generated successfully" "success"
    else
      bgd_log "OpenSSL not found, cannot generate certificates" "error"
      return 1
    fi
  fi
  
  # Save SSL configuration
  cat > "${BGD_CONFIG_DIR}/ssl.conf" << EOL
# SSL Configuration
# Generated: $(date)

SSL_ENABLED=true
DOMAIN_NAME=$domain
CERTBOT_EMAIL=$email
CERT_PATH=$cert_dir
EOL
  
  bgd_log "SSL initialized successfully for domain: $domain" "success"
  return 0
}

# Initialize master proxy (if requested)
bgd_init_master_proxy() {
  bgd_log "Initializing master proxy..." "info"
  
  # Check if master proxy plugin is available
  local proxy_plugin="${BGD_PLUGINS_DIR}/bgd-master-proxy.sh"
  if [ -f "$proxy_plugin" ]; then
    source "$proxy_plugin"
    
    # Enable master proxy
    export MASTER_PROXY_ENABLED="true"
    
    # Initialize master proxy
    if declare -f bgd_init_master_proxy >/dev/null; then
      if bgd_init_master_proxy; then
        bgd_log "Master proxy initialized successfully" "success"
      else
        bgd_log "Failed to initialize master proxy" "error"
        return 1
      fi
    else
      bgd_log "Master proxy plugin functions not available" "warning"
      return 1
    fi
  else
    bgd_log "Master proxy plugin not found: $proxy_plugin" "warning"
    return 1
  fi
  
  # Save master proxy configuration
  cat > "${BGD_CONFIG_DIR}/master-proxy.conf" << EOL
# Master Proxy Configuration
# Generated: $(date)

MASTER_PROXY_ENABLED=true
MASTER_PROXY_NAME=bgd-master-proxy
MASTER_PROXY_PORT=80
MASTER_PROXY_SSL_PORT=443
MASTER_PROXY_DIR=${BGD_BASE_DIR}/master-proxy
EOL
  
  bgd_log "Master proxy initialized successfully" "success"
  return 0
}

# Initialize deployment profiles (if requested)
bgd_init_profiles() {
  local profiles_dir="$1"
  
  if [ -z "$profiles_dir" ]; then
    profiles_dir="${BGD_BASE_DIR}/profiles"
  fi
  
  bgd_log "Initializing deployment profiles in: $profiles_dir" "info"
  
  # Check if profile manager plugin is available
  local profile_plugin="${BGD_PLUGINS_DIR}/bgd-profile-manager.sh"
  if [ -f "$profile_plugin" ]; then
    source "$profile_plugin"
    
    # Enable profiles
    export PROFILE_ENABLED="true"
    export PROFILE_DIR="$profiles_dir"
    
    # Initialize profiles
    if declare -f bgd_init_profiles >/dev/null; then
      if bgd_init_profiles; then
        bgd_log "Deployment profiles initialized successfully" "success"
      else
        bgd_log "Failed to initialize deployment profiles" "error"
        return 1
      fi
    else
      bgd_log "Profile manager plugin functions not available" "warning"
      return 1
    fi
  else
    bgd_log "Profile manager plugin not found: $profile_plugin" "warning"
    
    # Create basic profile structure manually
    bgd_ensure_directory "$profiles_dir"
    bgd_ensure_directory "$profiles_dir/default"
    bgd_ensure_directory "$profiles_dir/default/env"
    
    # Create default environment files
    cat > "$profiles_dir/default/env/common.env" << EOL
# Common environment variables for all environments
LOG_LEVEL=info
DEFAULT_PORT=3000
HEALTH_ENDPOINT=/health
HEALTH_RETRIES=12
HEALTH_DELAY=5
EOL

    cat > "$profiles_dir/default/env/blue.env" << EOL
# Blue environment-specific variables
ENV_NAME=blue
PORT=8081
EOL

    cat > "$profiles_dir/default/env/green.env" << EOL
# Green environment-specific variables
ENV_NAME=green
PORT=8082
EOL

    bgd_log "Basic profile structure created manually" "success"
  fi
  
  # Save profiles configuration
  cat > "${BGD_CONFIG_DIR}/profiles.conf" << EOL
# Deployment Profiles Configuration
# Generated: $(date)

PROFILE_ENABLED=true
PROFILE_DIR=$profiles_dir
DEFAULT_PROFILE=default
EOL
  
  bgd_log "Deployment profiles initialized successfully" "success"
  return 0
}

# Download and install plugins
bgd_install_plugins() {
  bgd_log "Installing core plugins..." "info"
  
  # Check if plugin manager is available
  local plugin_script="${BGD_SCRIPT_DIR}/bgd-plugin-manager.sh"
  if [ -f "$plugin_script" ] && [ -x "$plugin_script" ]; then
    # Install core plugins
    local core_plugins=("ssl" "notifications" "db-migrations" "audit-logging" "master-proxy" "profile-manager" "service-discovery")
    
    for plugin in "${core_plugins[@]}"; do
      bgd_log "Installing plugin: $plugin" "info"
      "$plugin_script" install "$plugin" || {
        bgd_log "Failed to install plugin: $plugin" "warning"
      }
    done
  else
    bgd_log "Plugin manager script not found: $plugin_script" "warning"
    return 1
  fi
  
  bgd_log "Core plugins installed successfully" "success"
  return 0
}

# Main initialization function
bgd_initialize_system() {
  local force="$1"
  local ssl_domain="$2"
  local ssl_email="$3"
  local init_proxy="$4"
  local profiles_dir="$5"
  local templates_dir="$6"
  
  # Check if system is already initialized
  if [ -f "${BGD_CONFIG_DIR}/.initialized" ] && [ "$force" != "true" ]; then
    bgd_log "System is already initialized. Use --force to reinitialize." "warning"
    return 0
  fi
  
  bgd_log "Initializing Blue/Green Deployment system..." "info"
  
  # Create directory structure
  bgd_init_directories
  
  # Install default templates
  bgd_install_default_templates "$templates_dir"
  
  # Initialize environment markers
  bgd_init_environment_markers
  
  # Create version file
  bgd_init_version_file
  
  # Create configuration files
  bgd_init_config
  
  # Load plugins
  bgd_load_plugins
  
  # Install core plugins
  bgd_install_plugins
  
  # Initialize SSL if requested
  if [ -n "$ssl_domain" ] && [ -n "$ssl_email" ]; then
    bgd_init_ssl "$ssl_domain" "$ssl_email"
  fi
  
  # Initialize master proxy if requested
  if [ "$init_proxy" = "true" ]; then
    bgd_init_master_proxy
  fi
  
  # Initialize deployment profiles if requested
  if [ -n "$profiles_dir" ]; then
    bgd_init_profiles "$profiles_dir"
  fi
  
  bgd_log "Blue/Green Deployment system initialized successfully" "success"
  return 0
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
  
  # Extract parameters
  local force="${FORCE:-false}"
  local ssl_domain="${SSL:-}"
  local ssl_email="${EMAIL:-}"
  local init_proxy="${PROXY:-false}"
  local profiles_dir="${PROFILES:-}"
  local templates_dir="${TEMPLATES:-}"
  
  # Initialize the system
  if bgd_initialize_system "$force" "$ssl_domain" "$ssl_email" "$init_proxy" "$profiles_dir" "$templates_dir"; then
    bgd_log "System initialization completed successfully" "success"
    exit 0
  else
    bgd_log "System initialization failed" "error"
    exit 1
  fi
}

# Execute main function if script is being run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bgd_main "$@"
fi
