#!/bin/bash
#
# bgd-nginx-template.sh - Dynamic Nginx configuration generator for Blue/Green Deployment
#
# This script generates Nginx configuration based on path and subdomain mappings
# It supports both blue/green traffic splitting and single environment deployments

set -euo pipefail

# ============================================================
# NGINX TEMPLATE PROCESSING
# ============================================================

# Generate upstream blocks for dual-env configuration
bgd_generate_dual_upstreams() {
  local app_name="$1"
  local services="$2"
  local blue_weight="$3"
  local green_weight="$4"
  
  bgd_log "Generating upstream blocks for blue/green traffic splitting" "info"
  
  local upstreams=""
  
  # Special case for default upstream
  upstreams+="upstream default_upstream {\n"
  upstreams+="    server ${app_name}-blue-${DEFAULT_SERVICE:-app}:${DEFAULT_PORT:-3000} weight=${blue_weight};\n"
  upstreams+="    server ${app_name}-green-${DEFAULT_SERVICE:-app}:${DEFAULT_PORT:-3000} weight=${green_weight};\n"
  upstreams+="}\n\n"
  
  # Process each service
  IFS=',' read -ra SERVICE_MAPPINGS <<< "$services"
  for mapping in "${SERVICE_MAPPINGS[@]}"; do
    # Skip empty mappings
    if [ -z "$mapping" ]; then
      continue
    fi
    
    # Parse the mapping (name:service:port)
    IFS=':' read -ra PARTS <<< "$mapping"
    if [ ${#PARTS[@]} -ge 3 ]; then
      local name="${PARTS[0]}"
      local service="${PARTS[1]}"
      local port="${PARTS[2]}"
      
      upstreams+="upstream ${name}_upstream {\n"
      upstreams+="    server ${app_name}-blue-${service}:${port} weight=${blue_weight};\n"
      upstreams+="    server ${app_name}-green-${service}:${port} weight=${green_weight};\n"
      upstreams+="}\n\n"
    fi
  done
  
  echo -e "$upstreams"
}

# Generate upstream blocks for single-env configuration
bgd_generate_single_upstreams() {
  local app_name="$1"
  local env_name="$2"
  local services="$3"
  
  bgd_log "Generating upstream blocks for single environment ($env_name)" "info"
  
  local upstreams=""
  
  # Special case for default upstream
  upstreams+="upstream ${env_name}_default {\n"
  upstreams+="    server ${app_name}-${env_name}-${DEFAULT_SERVICE:-app}:${DEFAULT_PORT:-3000};\n"
  upstreams+="}\n\n"
  
  # Process each service
  IFS=',' read -ra SERVICE_MAPPINGS <<< "$services"
  for mapping in "${SERVICE_MAPPINGS[@]}"; do
    # Skip empty mappings
    if [ -z "$mapping" ]; then
      continue
    fi
    
    # Parse the mapping (name:service:port)
    IFS=':' read -ra PARTS <<< "$mapping"
    if [ ${#PARTS[@]} -ge 3 ]; then
      local name="${PARTS[0]}"
      local service="${PARTS[1]}"
      local port="${PARTS[2]}"
      
      upstreams+="upstream ${env_name}_${name} {\n"
      upstreams+="    server ${app_name}-${env_name}-${service}:${port};\n"
      upstreams+="}\n\n"
    fi
  done
  
  echo -e "$upstreams"
}

# Generate location blocks for path-based routing
bgd_generate_path_locations() {
  local paths="$1"
  local is_dual_env="${2:-true}"
  local env_name="${3:-}"
  
  bgd_log "Generating location blocks for path-based routing" "info"
  
  local locations=""
  
  # Process each path mapping
  IFS=',' read -ra PATH_MAPPINGS <<< "$paths"
  for mapping in "${PATH_MAPPINGS[@]}"; do
    # Skip empty mappings
    if [ -z "$mapping" ]; then
      continue
    fi
    
    # Parse the mapping (path:service:port)
    IFS=':' read -ra PARTS <<< "$mapping"
    if [ ${#PARTS[@]} -ge 3 ]; then
      local path="${PARTS[0]}"
      local name="${PARTS[0]#/}"  # Remove leading slash for the name
      
      # Ensure path starts with /
      if [[ "$path" != /* ]]; then
        path="/$path"
      fi
      
      locations+="    location ${path} {\n"
      
      # Different upstream reference depending on environment mode
      if [ "$is_dual_env" = "true" ]; then
        locations+="        proxy_pass http://${name}_upstream;\n"
      else
        locations+="        proxy_pass http://${env_name}_${name};\n"
      fi
      
      # Common proxy settings
      locations+="        proxy_set_header Host \$host;\n"
      locations+="        proxy_set_header X-Real-IP \$remote_addr;\n"
      locations+="        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
      locations+="        proxy_set_header X-Forwarded-Proto \$scheme;\n"
      locations+="    }\n\n"
    fi
  done
  
  echo -e "$locations"
}

# Generate server blocks for subdomain-based routing
bgd_generate_subdomain_servers() {
  local app_name="$1"
  local subdomains="$2"
  local is_dual_env="${3:-true}"
  local env_name="${4:-}"
  local blue_weight="${5:-10}"
  local green_weight="${6:-0}"
  
  bgd_log "Generating server blocks for subdomain-based routing" "info"
  
  local servers=""
  
  # Process each subdomain mapping
  IFS=',' read -ra SUBDOMAIN_MAPPINGS <<< "$subdomains"
  for mapping in "${SUBDOMAIN_MAPPINGS[@]}"; do
    # Skip empty mappings
    if [ -z "$mapping" ]; then
      continue
    fi
    
    # Parse the mapping (subdomain:service:port)
    IFS=':' read -ra PARTS <<< "$mapping"
    if [ ${#PARTS[@]} -ge 3 ]; then
      local subdomain="${PARTS[0]}"
      local service="${PARTS[1]}"
      local port="${PARTS[2]}"
      
      # Generate server block
      servers+="server {\n"
      servers+="    listen NGINX_PORT;\n"
      servers+="    server_name ${subdomain}.DOMAIN_NAME;\n"
      servers+="    return 301 https://\$host\$request_uri;\n"
      servers+="}\n\n"
      
      servers+="server {\n"
      servers+="    listen NGINX_SSL_PORT ssl http2;\n"
      servers+="    server_name ${subdomain}.DOMAIN_NAME;\n"
      servers+="    \n"
      servers+="    # SSL Configuration\n"
      servers+="    ssl_certificate /etc/nginx/certs/fullchain.pem;\n"
      servers+="    ssl_certificate_key /etc/nginx/certs/privkey.pem;\n"
      servers+="    ssl_protocols TLSv1.2 TLSv1.3;\n"
      servers+="    ssl_prefer_server_ciphers on;\n"
      servers+="    ssl_ciphers EECDH+AESGCM:EDH+AESGCM;\n"
      servers+="    ssl_session_cache shared:SSL:10m;\n"
      servers+="    ssl_session_timeout 1d;\n"
      servers+="    ssl_stapling on;\n"
      servers+="    ssl_stapling_verify on;\n"
      servers+="    \n"
      servers+="    # Security headers\n"
      servers+="    add_header Strict-Transport-Security \"max-age=15768000; includeSubDomains\" always;\n"
      servers+="    add_header X-Content-Type-Options nosniff;\n"
      servers+="    add_header X-Frame-Options SAMEORIGIN;\n"
      servers+="    add_header X-XSS-Protection \"1; mode=block\";\n"
      servers+="    \n"
      servers+="    location / {\n"
      
      # Different upstream reference depending on environment mode
      if [ "$is_dual_env" = "true" ]; then
        # Create a subdomain-specific upstream
        servers+="        proxy_pass http://${subdomain}_upstream;\n"
      else
        servers+="        proxy_pass http://${app_name}-${env_name}-${service}:${port};\n"
      fi
      
      # Common proxy settings
      servers+="        proxy_set_header Host \$host;\n"
      servers+="        proxy_set_header X-Real-IP \$remote_addr;\n"
      servers+="        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;\n"
      servers+="        proxy_set_header X-Forwarded-Proto \$scheme;\n"
      servers+="    }\n"
      servers+="}\n\n"
    fi
  done
  
  echo -e "$servers"
}

# Generate the complete Nginx configuration for dual environments
bgd_generate_dual_env_nginx_conf() {
  local app_name="$1"
  local blue_weight="$2"
  local green_weight="$3"
  local paths="${4:-}"
  local subdomains="${5:-}"
  
  bgd_log "Generating dual-environment Nginx configuration" "info"
  
  # Get the template
  local template="${BGD_TEMPLATES_DIR}/nginx-dual-env.conf.template"
  if [ ! -f "$template" ]; then
    bgd_handle_error "file_not_found" "Nginx dual-env template not found at $template"
    return 1
  fi
  
  # Read the template
  local nginx_conf=$(<"$template")
  
  # Generate upstreams
  local all_services="${paths},${subdomains}"
  local upstreams=$(bgd_generate_dual_upstreams "$app_name" "$all_services" "$blue_weight" "$green_weight")
  
  # Replace DYNAMIC_UPSTREAMS placeholder
  nginx_conf="${nginx_conf//DYNAMIC_UPSTREAMS/$upstreams}"
  
  # Generate path locations if provided
  if [ -n "$paths" ]; then
    local path_locations=$(bgd_generate_path_locations "$paths" "true")
    nginx_conf="${nginx_conf//DYNAMIC_PATH_ROUTES/$path_locations}"
  else
    nginx_conf="${nginx_conf//DYNAMIC_PATH_ROUTES/}"
  fi
  
  # Generate subdomain servers if provided
  if [ -n "$subdomains" ]; then
    local subdomain_servers=$(bgd_generate_subdomain_servers "$app_name" "$subdomains" "true" "" "$blue_weight" "$green_weight")
    nginx_conf="${nginx_conf//DYNAMIC_SUBDOMAIN_SERVERS/$subdomain_servers}"
  else
    nginx_conf="${nginx_conf//DYNAMIC_SUBDOMAIN_SERVERS/}"
  fi
  
  # Handle domain name and ports
  nginx_conf="${nginx_conf//DOMAIN_NAME/${DOMAIN_NAME:-localhost}}"
  nginx_conf="${nginx_conf//DOMAIN_ALIASES/${DOMAIN_ALIASES:-}}"
  nginx_conf="${nginx_conf//NGINX_PORT/${NGINX_PORT:-80}}"
  nginx_conf="${nginx_conf//NGINX_SSL_PORT/${NGINX_SSL_PORT:-443}}"
  
  # Handle default upstream (already included in upstreams section)
  nginx_conf="${nginx_conf//DEFAULT_UPSTREAM/default_upstream}"
  
  # Return the configuration
  echo "$nginx_conf"
}

# Generate the complete Nginx configuration for a single environment
bgd_generate_single_env_nginx_conf() {
  local app_name="$1"
  local env_name="$2"
  local paths="${3:-}"
  local subdomains="${4:-}"
  
  bgd_log "Generating single-environment Nginx configuration for $env_name" "info"
  
  # Get the template
  local template="${BGD_TEMPLATES_DIR}/nginx-single-env.conf.template"
  if [ ! -f "$template" ]; then
    bgd_handle_error "file_not_found" "Nginx single-env template not found at $template"
    return 1
  fi
  
  # Read the template
  local nginx_conf=$(<"$template")
  
  # Generate upstreams
  local all_services="${paths},${subdomains}"
  local upstreams=$(bgd_generate_single_upstreams "$app_name" "$env_name" "$all_services")
  
  # Replace DYNAMIC_UPSTREAMS placeholder
  nginx_conf="${nginx_conf//DYNAMIC_UPSTREAMS/$upstreams}"
  
  # Generate path locations if provided
  if [ -n "$paths" ]; then
    local path_locations=$(bgd_generate_path_locations "$paths" "false" "$env_name")
    nginx_conf="${nginx_conf//DYNAMIC_PATH_ROUTES/$path_locations}"
  else
    nginx_conf="${nginx_conf//DYNAMIC_PATH_ROUTES/}"
  fi
  
  # Generate subdomain servers if provided
  if [ -n "$subdomains" ]; then
    local subdomain_servers=$(bgd_generate_subdomain_servers "$app_name" "$subdomains" "false" "$env_name")
    nginx_conf="${nginx_conf//DYNAMIC_SUBDOMAIN_SERVERS/$subdomain_servers}"
  else
    nginx_conf="${nginx_conf//DYNAMIC_SUBDOMAIN_SERVERS/}"
  fi
  
  # Handle domain name, environment name, and ports
  nginx_conf="${nginx_conf//DOMAIN_NAME/${DOMAIN_NAME:-localhost}}"
  nginx_conf="${nginx_conf//DOMAIN_ALIASES/${DOMAIN_ALIASES:-}}"
  nginx_conf="${nginx_conf//NGINX_PORT/${NGINX_PORT:-80}}"
  nginx_conf="${nginx_conf//NGINX_SSL_PORT/${NGINX_SSL_PORT:-443}}"
  nginx_conf="${nginx_conf//ENV_NAME/$env_name}"
  
  # Return the configuration
  echo "$nginx_conf"
}
