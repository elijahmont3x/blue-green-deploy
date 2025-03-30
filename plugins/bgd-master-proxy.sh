#!/bin/bash
#
# bgd-master-proxy.sh - Master reverse proxy plugin for Blue/Green Deployment
#
# This plugin integrates with the master proxy to register and unregister applications
# during deployment, cutover, and cleanup operations.

# Register plugin arguments
bgd_register_master_proxy_arguments() {
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_ENABLED" "true"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_DIR" "/app/master-proxy"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_REGISTRY" "${MASTER_PROXY_DIR}/app-registry.json"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_CONTAINER" "bgd-master-proxy"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_PORT" "80"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_SSL_PORT" "443"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_AUTO_SETUP" "true"
}

# Check if master proxy is initialized
bgd_check_master_proxy() {
  # Check if the container is running
  if docker ps -q --filter "name=${MASTER_PROXY_CONTAINER:-bgd-master-proxy}" | grep -q .; then
    return 0
  fi
  return 1
}

# Initialize the master proxy if not already set up
bgd_init_master_proxy() {
  # Skip if not enabled
  if [ "${MASTER_PROXY_ENABLED:-true}" != "true" ]; then
    return 0
  fi
  
  # Check if already running
  if bgd_check_master_proxy; then
    bgd_log "Master proxy already running" "debug"
    return 0
  fi
  
  # Skip auto-setup if disabled
  if [ "${MASTER_PROXY_AUTO_SETUP:-true}" != "true" ]; then
    bgd_log "Master proxy not initialized, but auto-setup is disabled" "warning"
    return 1
  fi
  
  bgd_log "Initializing master proxy automatically" "info"
  
  # Set up directory structure
  local proxy_dir="${MASTER_PROXY_DIR:-/app/master-proxy}"
  local registry_file="${proxy_dir}/app-registry.json"
  local container_name="${MASTER_PROXY_CONTAINER:-bgd-master-proxy}"
  local proxy_port="${MASTER_PROXY_PORT:-80}"
  local proxy_ssl_port="${MASTER_PROXY_SSL_PORT:-443}"
  
  # Ensure permissions for directory creation
  if ! bgd_ensure_directory "${proxy_dir}"; then
    bgd_log "Failed to create master proxy directory: ${proxy_dir}. Check permissions." "error"
    return 1
  fi
  
  # Check for port conflicts before starting
  if ! bgd_is_port_available "$proxy_port"; then
    bgd_log "Port $proxy_port is already in use. Cannot start master proxy." "error"
    return 1
  fi
  
  if ! bgd_is_port_available "$proxy_ssl_port"; then
    bgd_log "Port $proxy_ssl_port is already in use. Cannot start master proxy." "error"
    return 1
  fi
  
  # Ensure directories exist
  bgd_ensure_directory "${proxy_dir}/certs"
  bgd_ensure_directory "${proxy_dir}/logs"
  
  # Create initial registry if needed
  if [ ! -f "$registry_file" ]; then
    echo '{"applications":[]}' > "$registry_file"
  fi
  
  # Create initial configuration
  cat > "${proxy_dir}/nginx.conf" << EOL
# Master NGINX configuration
# Initially created $(date)

worker_processes auto;
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    sendfile        on;
    keepalive_timeout  65;
    
    access_log  /var/log/nginx/access.log;
    error_log   /var/log/nginx/error.log;
    
    # Default server
    server {
        listen ${proxy_port} default_server;
        listen [::]:${proxy_port} default_server;
        
        server_name _;
        
        location / {
            return 404 "No application configured for this domain.\\n";
        }
    }
}
EOL
  
  # Start the container
  bgd_log "Starting master proxy container" "info"
  docker stop "$container_name" 2>/dev/null || true
  docker rm "$container_name" 2>/dev/null || true
  
  docker run -d --name "$container_name" \
    --restart unless-stopped \
    -p ${proxy_port}:${proxy_port} -p ${proxy_ssl_port}:${proxy_ssl_port} \
    -v "${proxy_dir}/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "${proxy_dir}/certs:/etc/nginx/certs:ro" \
    -v "${proxy_dir}/logs:/var/log/nginx" \
    nginx:stable-alpine
  
  local status=$?
  if [ $status -ne 0 ]; then
    bgd_log "Failed to start master proxy container" "error"
    return 1
  fi
  
  bgd_log "Master proxy initialized successfully" "success"
  return 0
}

# Register the application with the master proxy
bgd_register_app_with_master_proxy() {
  local app_name="$1"
  local domain_name="$2"
  local port="$3"
  local ssl_port="$4"
  
  # Validate required parameters
  if [ -z "$app_name" ] || [ -z "$domain_name" ] || [ -z "$port" ]; then
    bgd_log "Missing required parameters for master proxy registration" "error"
    return 1
  fi
  
  if [ "${MASTER_PROXY_ENABLED:-true}" != "true" ]; then
    bgd_log "Master proxy is disabled, skipping registration" "info"
    return 0
  fi
  
  # Initialize master proxy if not already running
  bgd_init_master_proxy || {
    bgd_log "Failed to initialize master proxy" "error"
    return 1
  }
  
  bgd_log "Registering application with master proxy: $app_name -> $domain_name" "info"
  
  # Ensure master proxy directory exists
  if [ ! -d "${MASTER_PROXY_DIR}" ]; then
    mkdir -p "${MASTER_PROXY_DIR}/certs" || {
      bgd_log "Failed to create master proxy directories" "error"
      return 1
    }
    mkdir -p "${MASTER_PROXY_DIR}/logs" || {
      bgd_log "Failed to create master proxy log directory" "error" 
      return 1
    }
  fi
  
  # Initialize registry if needed
  if [ ! -f "${MASTER_PROXY_REGISTRY}" ]; then
    echo '{"applications":[]}' > "${MASTER_PROXY_REGISTRY}" || {
      bgd_log "Failed to create master proxy registry" "error"
      return 1
    }
  fi
  
  # Update registry
  if command -v jq &> /dev/null; then
    local tmp_file=$(mktemp)
    
    # Check if app already exists in registry
    local exists=$(jq --arg name "$app_name" '.applications | map(select(.name == $name)) | length' "${MASTER_PROXY_REGISTRY}")
    
    if [ "$exists" -gt 0 ]; then
      # Update existing entry
      jq --arg name "$app_name" \
         --arg domain "$domain_name" \
         --arg port "$port" \
         --arg ssl_port "$ssl_port" \
         '.applications = [.applications[] | if .name == $name then {"name": $name, "domain": $domain, "port": $port, "ssl_port": $ssl_port, "active": true} else . end]' \
         "${MASTER_PROXY_REGISTRY}" > "$tmp_file" || {
        bgd_log "Failed to update master proxy registry" "error"
        rm -f "$tmp_file"
        return 1
      }
    else
      # Add new entry
      jq --arg name "$app_name" \
         --arg domain "$domain_name" \
         --arg port "$port" \
         --arg ssl_port "$ssl_port" \
         '.applications += [{"name": $name, "domain": $domain, "port": $port, "ssl_port": $ssl_port, "active": true}]' \
         "${MASTER_PROXY_REGISTRY}" > "$tmp_file" || {
        bgd_log "Failed to update master proxy registry" "error"
        rm -f "$tmp_file"
        return 1
      }
    }
    
    # Update the registry file
    mv "$tmp_file" "${MASTER_PROXY_REGISTRY}" || {
      bgd_log "Failed to move temp registry to final location" "error"
      rm -f "$tmp_file"
      return 1
    }
  else
    bgd_log "jq not found, unable to update master proxy registry" "warning"
    return 1
  fi
  
  # Generate and update master proxy configuration
  bgd_update_master_proxy_config || {
    bgd_log "Failed to update master proxy configuration" "error"
    return 1
  }
  
  # Link SSL certificates if available
  if [ -d "certs" ]; then
    bgd_log "Linking SSL certificates for $app_name" "info"
    mkdir -p "${MASTER_PROXY_DIR}/certs/$app_name" || {
      bgd_log "Failed to create certificate directory" "warning"
    }
    cp -f certs/* "${MASTER_PROXY_DIR}/certs/$app_name/" 2>/dev/null || {
      bgd_log "Failed to copy certificates" "warning"
    }
  fi
  
  return 0
}

# Unregister an application from the master proxy
bgd_unregister_app_from_master_proxy() {
  local app_name="$1"
  local force="${2:-false}"
  
  if [ "${MASTER_PROXY_ENABLED:-true}" != "true" ]; then
    bgd_log "Master proxy is disabled, skipping unregistration" "info"
    return 0
  fi
  
  # Check for any running containers for this app
  if [ "$force" != "true" ]; then
    # Check if there are any running containers for this app
    local running_containers=$(docker ps --format "{{.Names}}" | grep "${app_name}" | wc -l)
    
    if [ "$running_containers" -gt 0 ]; then
      bgd_log "Found $running_containers running containers for $app_name, skipping unregistration" "warning"
      return 0
    }
  fi
  
  bgd_log "Unregistering application from master proxy: $app_name" "info"
  
  # Check if registry exists
  if [ ! -f "${MASTER_PROXY_REGISTRY}" ]; then
    bgd_log "Master proxy registry not found, nothing to unregister" "warning"
    return 0
  fi
  
  # Update registry
  if command -v jq &> /dev/null; then
    local tmp_file=$(mktemp)
    
    # Mark app as inactive
    jq --arg name "$app_name" \
       '.applications = [.applications[] | if .name == $name then .active = false else . end]' \
       "${MASTER_PROXY_REGISTRY}" > "$tmp_file" || {
      bgd_log "Failed to update master proxy registry" "error"
      rm -f "$tmp_file"
      return 1
    }
    
    # Update the registry file
    mv "$tmp_file" "${MASTER_PROXY_REGISTRY}" || {
      bgd_log "Failed to move temp registry to final location" "error"
      rm -f "$tmp_file"
      return 1
    }
  else
    bgd_log "jq not found, unable to update master proxy registry" "warning"
    return 1
  fi
  
  # Update master proxy configuration
  bgd_update_master_proxy_config || {
    bgd_log "Failed to update master proxy configuration" "warning"
  }
  
  return 0
}

# Generate and update the master proxy configuration
bgd_update_master_proxy_config() {
  local nginx_conf="${MASTER_PROXY_DIR}/nginx.conf"
  
  bgd_log "Updating master proxy configuration" "info"
  
  # Create basic NGINX configuration
  cat > "$nginx_conf" << EOL
# Master NGINX configuration for Blue/Green Deployment
# Automatically generated - DO NOT EDIT MANUALLY

worker_processes auto;
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    sendfile        on;
    keepalive_timeout  65;
    
    # Access log configuration
    log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                     '\$status \$body_bytes_sent "\$http_referer" '
                     '"\$http_user_agent" "\$http_x_forwarded_for"';
                     
    access_log  /var/log/nginx/access.log  main;
    error_log   /var/log/nginx/error.log  warn;
    
    # Gzip compression
    gzip  on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    
    # Default server for unmatched hosts
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        
        server_name _;
        
        location / {
            return 404 "No application configured for this domain.\\n";
        }
    }
EOL
  
  # Add server blocks for each active application
  if [ -f "${MASTER_PROXY_REGISTRY}" ] && command -v jq &> /dev/null; then
    # Get active applications
    local active_apps=$(jq -c '.applications[] | select(.active == true)' "${MASTER_PROXY_REGISTRY}")
    
    # Process each application
    echo "$active_apps" | while read -r app; do
      local name=$(echo "$app" | jq -r '.name')
      local domain=$(echo "$app" | jq -r '.domain')
      local port=$(echo "$app" | jq -r '.port')
      local ssl_port=$(echo "$app" | jq -r '.ssl_port')
      local has_ssl=false
      
      # Check if SSL certificates exist
      if [ -f "${MASTER_PROXY_DIR}/certs/$name/fullchain.pem" ] && [ -f "${MASTER_PROXY_DIR}/certs/$name/privkey.pem" ]; then
        has_ssl=true
      fi
      
      # Add HTTP server block
      cat >> "$nginx_conf" << EOL
    
    # HTTP server for $name ($domain)
    server {
        listen 80;
        listen [::]:80;
        server_name $domain;
EOL
      
      # Add SSL redirect if certificates are available
      if [ "$has_ssl" = true ]; then
        cat >> "$nginx_conf" << EOL
        
        # Redirect to HTTPS
        return 301 https://\$host\$request_uri;
    }
    
    # HTTPS server for $name ($domain)
    server {
        listen 443 ssl http2;
        listen [::]:443 ssl http2;
        server_name $domain;
        
        # SSL Configuration
        ssl_certificate /etc/nginx/certs/$name/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/$name/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        ssl_ciphers EECDH+AESGCM:EDH+AESGCM;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 1d;
        
        # Proxy settings
        location / {
            proxy_pass http://localhost:$ssl_port;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
EOL
      else
        # Just HTTP proxy
        cat >> "$nginx_conf" << EOL
        
        # Proxy settings
        location / {
            proxy_pass http://localhost:$port;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
EOL
      fi
      
      # Close the server block
      cat >> "$nginx_conf" << EOL
    }
EOL
    done
  fi
  
  # Close the http block
  cat >> "$nginx_conf" << EOL
}
EOL
  
  # Start or reload the master proxy
  bgd_start_or_reload_master_proxy
  
  return 0
}

# Start or reload the master proxy
bgd_start_or_reload_master_proxy() {
  local container_name="${MASTER_PROXY_CONTAINER:-bgd-master-proxy}"
  
  # Check if container is running
  if docker ps -q --filter "name=$container_name" | grep -q .; then
    bgd_log "Reloading master proxy configuration" "info"
    docker exec "$container_name" nginx -s reload || {
      bgd_log "Failed to reload, restarting master proxy container" "warning"
      docker restart "$container_name"
    }
  else
    bgd_log "Starting master proxy container" "info"
    
    # Remove container if it exists but is not running
    docker rm -f "$container_name" 2>/dev/null || true
    
    # Start container
    docker run -d --name "$container_name" \
      --restart unless-stopped \
      -p 80:80 -p 443:443 \
      -v "${MASTER_PROXY_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro" \
      -v "${MASTER_PROXY_DIR}/certs:/etc/nginx/certs:ro" \
      -v "${MASTER_PROXY_DIR}/logs:/var/log/nginx" \
      nginx:stable-alpine || {
      bgd_log "Failed to start master proxy container" "error"
      return 1
    }
  fi
  
  return 0
}

# Hook: Check and initialize master proxy at start of deployment
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  # Initialize master proxy early to avoid surprises later
  if [ "${MASTER_PROXY_ENABLED:-true}" = "true" ] && [ "${MASTER_PROXY_AUTO_SETUP:-true}" = "true" ]; then
    bgd_init_master_proxy || {
      bgd_log "Warning: Master proxy initialization failed during pre-deploy" "warning"
      # Continue deployment despite warning - will try again during post-deploy
    }
  fi
  
  return 0
}

# Hook: Register with master proxy after deployment is complete
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Only register if we have domain name and active environment
  if [ -n "${DOMAIN_NAME:-}" ] && [ "$env_name" = "$TARGET_ENV" ]; then
    bgd_register_app_with_master_proxy "$APP_NAME" "$DOMAIN_NAME" "$NGINX_PORT" "$NGINX_SSL_PORT"
  fi
  
  return 0
}

# Hook: Update registration after cutover
bgd_hook_post_cutover() {
  local target_env="$1"
  
  # Update registration after cutover
  if [ -n "${DOMAIN_NAME:-}" ]; then
    bgd_register_app_with_master_proxy "$APP_NAME" "$DOMAIN_NAME" "$NGINX_PORT" "$NGINX_SSL_PORT"
  fi
  
  return 0
}

# Hook: Update registration after rollback
bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  # Update registration after rollback
  if [ -n "${DOMAIN_NAME:-}" ]; then
    bgd_register_app_with_master_proxy "$APP_NAME" "$DOMAIN_NAME" "$NGINX_PORT" "$NGINX_SSL_PORT"
  fi
  
  return 0
}

# Hook: For cleanup - only unregister if there are no active deployments
bgd_hook_cleanup() {
  local app_name="$1"
  local force="${2:-false}"
  
  # Unregister app during cleanup, but check for active deployments first
  bgd_unregister_app_from_master_proxy "$app_name" "$force"
  
  return 0
}