#!/bin/bash
#
# bgd-service-discovery.sh - Service discovery plugin for Blue/Green Deployment
#
# This plugin enables automatic service registration and discovery:
# - Registers services with internal registry
# - Updates environment variables for service URLs
# - Supports multi-service architectures

# Register plugin arguments
bgd_register_service_discovery_arguments() {
  bgd_register_plugin_argument "service-discovery" "SERVICE_REGISTRY_ENABLED" "true"
  bgd_register_plugin_argument "service-discovery" "SERVICE_AUTO_GENERATE_URLS" "true"
  bgd_register_plugin_argument "service-discovery" "SERVICE_REGISTRY_FILE" "service-registry.json"
}

# Register a service in the local registry file
bgd_register_service() {
  local name="$1"
  local version="$2"
  local url="$3"
  local env="$4"
  
  bgd_log "Registering service: $name v$version at $url ($env environment)" "info"
  
  # Create registry file if it doesn't exist
  local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
  if [ ! -f "$registry_file" ]; then
    echo '{"services": {}}' > "$registry_file"
  fi
  
  # Add service to registry
  local tmp_file=$(mktemp)
  if command -v jq &> /dev/null; then
    jq --arg name "$name" \
       --arg version "$version" \
       --arg url "$url" \
       --arg env "$env" \
       --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       '.services[$name] = {"version": $version, "url": $url, "environment": $env, "registered_at": $timestamp}' \
       "$registry_file" > "$tmp_file" && mv "$tmp_file" "$registry_file"
  else
    # Fallback if jq is not available
    local json="{\"services\":{\"$name\":{\"version\":\"$version\",\"url\":\"$url\",\"environment\":\"$env\",\"registered_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
    echo "$json" > "$registry_file"
  fi
     
  bgd_log "Service registered in local registry: $registry_file" "success"
}

# Discover services and add them to environment
bgd_discover_services() {
  local env_file="$1"
  
  if [ "${SERVICE_AUTO_GENERATE_URLS:-true}" = "true" ] && [ -f "$env_file" ]; then
    bgd_log "Adding service discovery variables to $env_file" "info"
    
    # Get the registry file
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
      # Extract service URLs from registry and add to env file
      if command -v jq &> /dev/null; then
        jq -r '.services | to_entries[] | "SERVICE_URL_" + (.key | ascii_upcase) + "=" + .value.url' \
          "$registry_file" >> "$env_file"
      else
        # Fallback if jq is not available
        bgd_log "jq not available, using simple service URL generation" "warning"
        echo "SERVICE_URL_${APP_NAME^^}=http://${DOMAIN_NAME:-localhost}" >> "$env_file"
      fi
      
      bgd_log "Added service URLs to environment file" "success"
    else
      bgd_log "Service registry file not found: $registry_file" "warning"
    fi
  fi
}

# Update Nginx configuration based on discovered services
bgd_update_nginx_config() {
  local nginx_conf="$1"
  
  if [ -f "$nginx_conf" ]; then
    bgd_log "Updating Nginx configuration with discovered services" "info"
    
    # Get the registry file
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
      bgd_log "Service registry found, but automatic Nginx configuration not yet implemented" "info"
      # For future enhancement: Parse registry and update Nginx config
    fi
  fi
}

# Service Discovery Hooks
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${SERVICE_REGISTRY_ENABLED:-true}" = "true" ]; then
    # Get the deployed service URL
    local service_url="http://${DOMAIN_NAME:-localhost}"
    
    # Register service in local registry
    bgd_register_service "$APP_NAME" "$version" "$service_url" "$env_name"
    
    # If we're updating an environment file, add service URLs
    if [ -f ".env.${env_name}" ]; then
      bgd_discover_services ".env.${env_name}"
    fi
    
    # Update Nginx config if needed
    bgd_update_nginx_config "nginx.conf"
  fi
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  if [ "${SERVICE_REGISTRY_ENABLED:-true}" = "true" ]; then
    bgd_log "Updating service registry after cutover to $target_env" "info"
    
    # Update registry to reflect cutover
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ] && command -v jq &> /dev/null; then
      local tmp_file=$(mktemp)
      jq --arg name "$APP_NAME" \
         --arg env "$target_env" \
         '.services[$name].active = true | .services[$name].environment = $env' \
         "$registry_file" > "$tmp_file" && mv "$tmp_file" "$registry_file"
    fi
  fi
  
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  if [ "${SERVICE_REGISTRY_ENABLED:-true}" = "true" ]; then
    bgd_log "Updating service registry after rollback to $rollback_env" "info"
    
    # Update registry to reflect rollback
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ] && command -v jq &> /dev/null; then
      local tmp_file=$(mktemp)
      jq --arg name "$APP_NAME" \
         --arg env "$rollback_env" \
         '.services[$name].active = true | .services[$name].environment = $env | .services[$name].rollback = true' \
         "$registry_file" > "$tmp_file" && mv "$tmp_file" "$registry_file"
    fi
  fi
  
  return 0
}