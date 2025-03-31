#!/bin/bash
#
# bgd-core.sh - Core utility functions for Blue/Green Deployment
#
# This script provides common functions used by other BGD scripts

# Set up base directories
BGD_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BGD_BASE_DIR="$(cd "$(dirname "$BGD_SCRIPT_DIR")" && pwd)"
BGD_CONFIG_DIR="$BGD_BASE_DIR/config"
BGD_TEMPLATES_DIR="$BGD_CONFIG_DIR/templates"
BGD_LOGS_DIR="$BGD_BASE_DIR/logs"

# Initialize system
bgd_init() {
  # Set base directories
  BGD_BASE_DIR=${BGD_BASE_DIR:-"$(cd "$(dirname "$BGD_SCRIPT_DIR")" && pwd)"}
  BGD_CONFIG_DIR=${BGD_CONFIG_DIR:-"$BGD_BASE_DIR/config"}
  BGD_TEMPLATES_DIR=${BGD_TEMPLATES_DIR:-"$BGD_CONFIG_DIR/templates"}
  BGD_LOGS_DIR=${BGD_LOGS_DIR:-"$BGD_BASE_DIR/logs"}
  BGD_PLUGINS_DIR=${BGD_PLUGINS_DIR:-"$BGD_BASE_DIR/plugins"}
  BGD_CREDENTIALS_DIR=${BGD_CREDENTIALS_DIR:-"$BGD_BASE_DIR/credentials"}
  
  # Check if system is initialized
  if [ ! -f "${BGD_CONFIG_DIR}/.initialized" ]; then
    bgd_log "System not initialized. Performing automatic initialization..." "info"
    bgd_auto_initialize
  fi
  
  # Create necessary directories
  bgd_ensure_directory "$BGD_LOGS_DIR"
  
  # Load plugins automatically
  bgd_load_plugins
  
  return 0
}

# Perform automatic initialization
bgd_auto_initialize() {
  # Create required directories
  bgd_ensure_directory "$BGD_CONFIG_DIR"
  bgd_ensure_directory "$BGD_TEMPLATES_DIR"
  bgd_ensure_directory "$BGD_TEMPLATES_DIR/partials"
  bgd_ensure_directory "$BGD_PLUGINS_DIR"
  bgd_ensure_directory "$BGD_LOGS_DIR"
  bgd_ensure_directory "$BGD_CREDENTIALS_DIR"
  bgd_ensure_directory "${BGD_BASE_DIR}/apps"
  
  # Initialize environment markers
  echo "blue" > "${BGD_BASE_DIR}/.bgd-active-env"
  echo "green" > "${BGD_BASE_DIR}/.bgd-inactive-env"
  
  # Create version file
  echo "1.0.0" > "${BGD_CONFIG_DIR}/version"
  
  # Create basic configuration file
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

  # Create basic templates
  if [ ! -d "$BGD_TEMPLATES_DIR" ]; then
    bgd_ensure_directory "$BGD_TEMPLATES_DIR"
    
    # Create nginx configuration templates
    if [ -f "${BGD_SCRIPT_DIR}/../templates/nginx-single-env.conf.template" ]; then
      cp -r "${BGD_SCRIPT_DIR}/../templates/"* "$BGD_TEMPLATES_DIR/"
    else
      # Create minimal templates for nginx configs
      cat > "${BGD_TEMPLATES_DIR}/nginx-single-env.conf.template" << 'EOL'
# Nginx configuration for single environment (${ENV_NAME})
# Generated: ${TIMESTAMP}

user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
                    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;
    
    # Optimizations
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    # SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    # Server configuration
    server {
        listen 80;
        server_name ${DOMAIN_NAME:-localhost};
        
        location / {
            proxy_pass http://app:${PORT:-3000};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
EOL
    
      cat > "${BGD_TEMPLATES_DIR}/nginx-dual-env.conf.template" << 'EOL'
# Nginx configuration for dual environment (blue/green)
# Generated: ${TIMESTAMP}

user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';
                    
    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log;
    
    # Optimizations
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    
    # SSL
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    
    # Upstream definitions for blue/green environments
    upstream blue {
        server app-blue:${BLUE_PORT:-8081};
    }
    
    upstream green {
        server app-green:${GREEN_PORT:-8082};
    }
    
    # Split traffic configuration
    split_clients "${remote_addr}${remote_port}${time_local}" $environment {
        ${BLUE_WEIGHT:-50}%    blue;
        ${GREEN_WEIGHT:-50}%   green;
    }
    
    # Server configuration
    server {
        listen 80;
        server_name ${DOMAIN_NAME:-localhost};
        
        location / {
            proxy_pass http://$environment;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
}
EOL
    fi
  fi
  
  # Create docker-compose template if it doesn't exist
  if [ ! -f "${BGD_BASE_DIR}/docker-compose.template.yml" ]; then
    cat > "${BGD_BASE_DIR}/docker-compose.template.yml" << 'EOL'
version: '3.8'

services:
  app:
    image: ${IMAGE}
    container_name: ${APP_NAME}-${ENV_NAME}-app
    restart: unless-stopped
    environment:
      - NODE_ENV=${NODE_ENV:-production}
      - PORT=${PORT:-3000}
      - VERSION=${VERSION:-latest}
      - ENV_NAME=${ENV_NAME}
    labels:
      com.bgd.app: "${APP_NAME}"
      com.bgd.env: "${ENV_NAME}"
      com.bgd.version: "${VERSION:-latest}"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${PORT:-3000}${HEALTH_ENDPOINT:-/health}"]
      interval: 10s
      timeout: 5s
      retries: ${HEALTH_RETRIES:-12}
      start_period: 15s
    volumes:
      - app-data:/app/data
    networks:
      - ${ENV_NAME}-network

  nginx:
    image: nginx:stable-alpine
    container_name: ${APP_NAME}-${ENV_NAME}-nginx
    restart: unless-stopped
    ports:
      - "${NGINX_PORT:-80}:80"
      - "${NGINX_SSL_PORT:-443}:443"
    depends_on:
      - app
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx:/etc/nginx:ro
      - ./certs:/etc/nginx/certs:ro
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3
    networks:
      - ${ENV_NAME}-network
      - ${MASTER_NETWORK:-bgd-network}

networks:
  ${ENV_NAME}-network:
    name: ${APP_NAME}-${ENV_NAME}-network
  ${MASTER_NETWORK:-bgd-network}:
    external: ${USE_EXTERNAL_NETWORK:-false}

volumes:
  app-data:
    name: ${APP_NAME}-${ENV_NAME}-data
EOL
  fi
  
  # Create initialization marker
  touch "${BGD_CONFIG_DIR}/.initialized"
  
  bgd_log "Automatic initialization completed successfully" "success"
  return 0
}

# Ensure required directories exist
bgd_ensure_directory() {
  local dir="$1"
  
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" || {
      echo "Error: Failed to create directory: $dir" >&2
      return 1
    }
  fi
  
  return 0
}

# Logging function with color output
bgd_log() {
  local message="$1"
  local level="${2:-info}"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  
  # Create logs directory if it doesn't exist
  bgd_ensure_directory "$BGD_LOGS_DIR"
  
  # Default log colors
  local color_reset="\033[0m"
  local color_level=""
  
  # Set color based on log level
  case "$level" in
    debug)
      color_level="\033[36m"  # Cyan
      ;;
    info)
      color_level="\033[32m"  # Green
      ;;
    warning)
      color_level="\033[33m"  # Yellow
      ;;
    error)
      color_level="\033[31m"  # Red
      ;;
    success)
      color_level="\033[32;1m"  # Bright Green
      ;;
    *)
      color_level="\033[0m"  # Default
      ;;
  esac
  
  # Log to console with color
  echo -e "${color_level}[${level^^}]${color_reset} $message"
  
  # Log to file without color codes
  echo "[$timestamp] [${level^^}] $message" >> "$BGD_LOGS_DIR/bgd.log"
  
  return 0
}

# Parse command line parameters
bgd_parse_parameters() {
  # Initialize variables
  local positional=()
  
  # Loop through all arguments
  while [[ $# -gt 0 ]]; do
    local key="$1"
    
    # Handle --param=value style arguments
    if [[ $key == --*=* ]]; then
      local param_name="${key%%=*}"
      local param_value="${key#*=}"
      param_name="${param_name#--}"
      param_name="${param_name//-/_}"
      param_name="${param_name^^}"
      
      # Export the parameter
      export "$param_name"="$param_value"
      shift
      continue
    fi
    
    # Handle --flag style arguments
    if [[ $key == --* ]]; then
      local param_name="${key#--}"
      param_name="${param_name//-/_}"
      param_name="${param_name^^}"
      
      # Export as true
      export "$param_name"="true"
      shift
      continue
    fi
    
    # Save positional args
    positional+=("$1")
    shift
  done
  
  # Restore positional parameters
  set -- "${positional[@]}"
  
  return 0
}

# Get active and inactive environments
bgd_get_environments() {
  local active_env="blue"
  local inactive_env="green"
  
  # Check if environment markers exist
  if [ -f "${BGD_BASE_DIR}/.bgd-active-env" ]; then
    active_env=$(cat "${BGD_BASE_DIR}/.bgd-active-env")
    inactive_env=$([ "$active_env" = "blue" ] && echo "green" || echo "blue")
  else
    # Create initial environment markers
    echo "$active_env" > "${BGD_BASE_DIR}/.bgd-active-env"
    echo "$inactive_env" > "${BGD_BASE_DIR}/.bgd-inactive-env"
  fi
  
  echo "$active_env $inactive_env"
}

# Check health of a specific environment
bgd_check_environment_health() {
  local env_name="$1"
  local app_name="$2"
  
  # Construct the health check URL
  local port=""
  if [ "$env_name" = "blue" ]; then
    port="${BLUE_PORT:-8081}"
  else
    port="${GREEN_PORT:-8082}"
  fi
  
  # Endpoint to check
  local endpoint="${HEALTH_ENDPOINT:-/health}"
  
  # Determine container name to check
  local container="${app_name}-${env_name}-app"
  
  # Check if container is running
  if ! docker ps -q -f "name=$container" | grep -q .; then
    bgd_log "Container $container is not running" "error"
    return 1
  fi
  
  # Perform health check with curl
  local retries="${HEALTH_RETRIES:-12}"
  local delay="${HEALTH_DELAY:-5}"
  
  bgd_log "Checking health for $container ($endpoint), retries: $retries, delay: $delay" "info"
  
  local attempt=1
  while [ $attempt -le $retries ]; do
    bgd_log "Health check attempt $attempt/$retries..." "debug"
    
    # Use docker exec to run curl inside the container
    if docker exec $container curl -s -f "http://localhost:${PORT:-3000}$endpoint" > /dev/null 2>&1; then
      bgd_log "Health check passed for $container" "success"
      return 0
    fi
    
    bgd_log "Health check failed, waiting $delay seconds..." "warning"
    sleep $delay
    attempt=$((attempt + 1))
  done
  
  bgd_log "Health check failed after $retries attempts" "error"
  return 1
}

# Get Docker Compose command (handles both docker-compose and docker compose)
bgd_get_docker_compose_cmd() {
  # Check for docker compose (new version)
  if docker compose version &> /dev/null; then
    echo "docker compose"
    return 0
  fi
  
  # Check for docker-compose (old version)
  if command -v docker-compose &> /dev/null; then
    echo "docker-compose"
    return 0
  fi
  
  # Neither found
  bgd_log "Neither docker compose nor docker-compose found" "error"
  return 1
}

# Create Nginx configuration for single environment
bgd_create_single_env_nginx_conf() {
  local env_name="$1"
  local nginx_conf_dir="${BGD_BASE_DIR}/nginx"
  
  bgd_log "Creating Nginx configuration for $env_name environment" "info"
  
  # Ensure nginx directory exists
  bgd_ensure_directory "$nginx_conf_dir"
  
  # Set environment variables for template
  export ENV_NAME="$env_name"
  
  # Process template
  local template_path="${BGD_TEMPLATES_DIR}/nginx-single-env.conf.template"
  
  if [ ! -f "$template_path" ]; then
    bgd_log "Template not found: $template_path" "error"
    return 1
  fi
  
  # Simple template processing
  eval "cat <<EOF
$(cat $template_path)
EOF" > "${nginx_conf_dir}/nginx.conf"
  
  bgd_log "Nginx configuration created in ${nginx_conf_dir}/nginx.conf" "success"
  return 0
}

# Create Nginx configuration for dual environment (weighted)
bgd_create_dual_env_nginx_conf() {
  local blue_weight="$1"
  local green_weight="$2"
  local nginx_conf_dir="${BGD_BASE_DIR}/nginx"
  
  bgd_log "Creating Nginx configuration with weights: blue=$blue_weight%, green=$green_weight%" "info"
  
  # Ensure nginx directory exists
  bgd_ensure_directory "$nginx_conf_dir"
  
  # Set environment variables for template
  export BLUE_WEIGHT="$blue_weight"
  export GREEN_WEIGHT="$green_weight"
  
  # Process template
  local template_path="${BGD_TEMPLATES_DIR}/nginx-dual-env.conf.template"
  
  if [ ! -f "$template_path" ]; then
    bgd_log "Template not found: $template_path" "error"
    return 1
  fi
  
  # Simple template processing
  eval "cat <<EOF
$(cat $template_path)
EOF" > "${nginx_conf_dir}/nginx.conf"
  
  bgd_log "Nginx configuration created in ${nginx_conf_dir}/nginx.conf" "success"
  return 0
}

# Log deployment event
bgd_log_deployment_event() {
  local version="$1"
  local event_type="$2"
  local details="$3"
  
  local log_file="${BGD_LOGS_DIR}/deployment-history.log"
  local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
  local user=$(whoami)
  
  # Ensure logs directory exists
  bgd_ensure_directory "$BGD_LOGS_DIR"
  
  # Log the event
  echo "[$timestamp] [${event_type}] version=$version, user=$user, details=\"$details\"" >> "$log_file"
  
  return 0
}

# Automatically detect and load plugins
bgd_load_plugins() {
  local plugin_dir="${BGD_PLUGINS_DIR:-$BGD_BASE_DIR/plugins}"
  
  # Skip if plugins directory doesn't exist
  if [ ! -d "$plugin_dir" ]; then
    bgd_log "Plugins directory not found: $plugin_dir" "warning"
    return 0
  fi
  
  bgd_log "Loading plugins from: $plugin_dir" "debug"
  
  # Find and source all plugin files that don't end with .disabled
  local count=0
  for plugin_file in "$plugin_dir"/bgd-*.sh; do
    # Skip if no files match or file doesn't exist
    if [ ! -f "$plugin_file" ] || [[ "$plugin_file" == *".disabled" ]]; then
      continue
    fi
    
    bgd_log "Loading plugin: $(basename "$plugin_file")" "debug"
    source "$plugin_file" || {
      bgd_log "Failed to load plugin: $(basename "$plugin_file")" "warning"
      continue
    }
    
    # Call plugin's registration function if it exists
    local plugin_name=$(basename "$plugin_file" .sh | sed 's/^bgd-//')
    local register_func="bgd_register_${plugin_name//-/_}_arguments"
    
    if declare -F "$register_func" >/dev/null; then
      $register_func
    fi
    
    count=$((count + 1))
  done
  
  bgd_log "Loaded $count plugins" "info"
  return 0
}

# Enable a plugin
bgd_enable_plugin() {
  local plugin_name="$1"
  local plugin_dir="${BGD_PLUGINS_DIR:-./plugins}"
  
  # Check for regular and disabled versions
  local plugin_file="$plugin_dir/bgd-$plugin_name.sh"
  local disabled_file="${plugin_file}.disabled"
  
  if [ -f "$plugin_file" ]; then
    bgd_log "Plugin is already enabled: $plugin_name" "info"
    return 0
  elif [ -f "$disabled_file" ]; then
    # Rename disabled file to enable it
    mv "$disabled_file" "$plugin_file" || {
      bgd_log "Failed to enable plugin" "error"
      return 1
    }
    
    # Ensure it's executable
    chmod +x "$plugin_file" || {
      bgd_log "Failed to make plugin executable" "warning"
    }
    
    bgd_log "Plugin enabled: $plugin_name" "success"
    return 0
  else
    bgd_log "Plugin not found: $plugin_name" "error"
    return 1
  fi
}

# Disable a plugin
bgd_disable_plugin() {
  local plugin_name="$1"
  local plugin_dir="${BGD_PLUGINS_DIR:-./plugins}"
  
  # Check if plugin exists
  local plugin_file="$plugin_dir/bgd-$plugin_name.sh"
  local disabled_file="${plugin_file}.disabled"
  
  if [ -f "$disabled_file" ]; then
    bgd_log "Plugin is already disabled: $plugin_name" "info"
    return 0
  elif [ -f "$plugin_file" ]; then
    # Rename file to disable it
    mv "$plugin_file" "$disabled_file" || {
      bgd_log "Failed to disable plugin" "error"
      return 1
    }
    
    bgd_log "Plugin disabled: $plugin_name" "success"
    return 0
  else
    bgd_log "Plugin not found: $plugin_name" "error"
    return 1
  fi
}

# Plugin argument registry
declare -A BGD_PLUGIN_ARGUMENTS

# Register a plugin argument
bgd_register_plugin_argument() {
  local plugin_name="$1"
  local arg_name="$2"
  local default_value="$3"
  
  # Store in the registry
  BGD_PLUGIN_ARGUMENTS["${plugin_name}.${arg_name}"]="$default_value"
  
  # Set the value if not already defined
  if [ -z "${!arg_name+x}" ]; then
    # Export with default value
    export "$arg_name"="$default_value"
  fi
}

# Get plugin argument default
bgd_get_plugin_argument_default() {
  local plugin_name="$1"
  local arg_name="$2"
  
  echo "${BGD_PLUGIN_ARGUMENTS["${plugin_name}.${arg_name}"]:-}"
}

# List registered plugin arguments
bgd_list_plugin_arguments() {
  local plugin_name="$1"
  
  for key in "${!BGD_PLUGIN_ARGUMENTS[@]}"; do
    if [[ "$key" == "${plugin_name}."* ]]; then
      local arg_name=${key#${plugin_name}.}
      local default_value="${BGD_PLUGIN_ARGUMENTS[$key]}"
      echo "$arg_name=$default_value"
    fi
  done
}

# Call initialization during source
bgd_init