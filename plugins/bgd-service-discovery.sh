#!/bin/bash
#
# bgd-service-discovery.sh - Service discovery plugin for Blue/Green Deployment
#
# This plugin enables automatic service registration and discovery:
# - Registers services with internal and/or external registries
# - Generates service URLs for environment variables
# - Updates Nginx configuration for discovered services
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
bgd_register_service_discovery_arguments() {
  bgd_register_plugin_argument "service-discovery" "SERVICE_REGISTRY_ENABLED" "true"
  bgd_register_plugin_argument "service-discovery" "SERVICE_REGISTRY_URL" ""
  bgd_register_plugin_argument "service-discovery" "SERVICE_AUTO_GENERATE_URLS" "true"
  bgd_register_plugin_argument "service-discovery" "SERVICE_REGISTRY_FILE" "service-registry.json"
}

# Register a service in the local registry file
bgd_register_service() {
  local name="$1"
  local version="$2"
  local url="$3"
  local env="$4"
  
  bgd_log_info "Registering service: $name v$version at $url ($env environment)"
  
  # Create registry file if it doesn't exist
  local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
  if [ ! -f "$registry_file" ]; then
    echo '{"services": {}}' > "$registry_file"
  fi
  
  # Add service to registry
  local tmp_file=$(mktemp)
  jq --arg name "$name" \
     --arg version "$version" \
     --arg url "$url" \
     --arg env "$env" \
     --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
     '.services[$name] = {"version": $version, "url": $url, "environment": $env, "registered_at": $timestamp}' \
     "$registry_file" > "$tmp_file" && mv "$tmp_file" "$registry_file"
     
  bgd_log_info "Service registered in local registry: $registry_file"
}

# Register a service with an external registry
bgd_register_with_external_registry() {
  local name="$1"
  local version="$2"
  local url="$3"
  local env="$4"
  
  if [ -n "${SERVICE_REGISTRY_URL:-}" ]; then
    bgd_log_info "Registering service with external registry at $SERVICE_REGISTRY_URL"
    
    # Create registration payload
    local payload=$(jq -n \
      --arg name "$name" \
      --arg version "$version" \
      --arg url "$url" \
      --arg env "$env" \
      '{"name": $name, "version": $version, "url": $url, "environment": $env}')
      
    # Post to external registry
    curl -s -X POST -H "Content-Type: application/json" \
      -d "$payload" "$SERVICE_REGISTRY_URL/services" || {
      bgd_log_warning "Failed to register with external registry"
    }
  fi
}

# Discover services and add them to environment
bgd_discover_services() {
  local env_file="$1"
  
  if [ "${SERVICE_AUTO_GENERATE_URLS:-true}" = "true" ] && [ -f "$env_file" ]; then
    bgd_log_info "Adding service discovery variables to $env_file"
    
    # Get the registry file
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
      # Extract service URLs from registry and add to env file
      jq -r '.services | to_entries[] | "SERVICE_URL_" + (.key | ascii_upcase) + "=" + .value.url' \
        "$registry_file" >> "$env_file"
      
      bgd_log_info "Added service URLs to environment file"
    else
      bgd_log_warning "Service registry file not found: $registry_file"
    fi
  fi
}

# Update Nginx configuration based on discovered services
bgd_update_nginx_config() {
  local nginx_conf="$1"
  
  if [ -f "$nginx_conf" ]; then
    bgd_log_info "Updating Nginx configuration with discovered services"
    
    # Get the registry file
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
      # For now, just log that we would update
      bgd_log_info "Would update Nginx configuration based on service registry"
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
    
    # Register with external registry if configured
    bgd_register_with_external_registry "$APP_NAME" "$version" "$service_url" "$env_name"
    
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
    bgd_log_info "Updating service registry after cutover to $target_env"
    
    # Update registry to reflect cutover
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
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
    bgd_log_info "Updating service registry after rollback to $rollback_env"
    
    # Update registry to reflect rollback
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
      local tmp_file=$(mktemp)
      jq --arg name "$APP_NAME" \
         --arg env "$rollback_env" \
         '.services[$name].active = true | .services[$name].environment = $env | .services[$name].rollback = true' \
         "$registry_file" > "$tmp_file" && mv "$tmp_file" "$registry_file"
    fi
  fi
  
  return 0
}

bgd_hook_post_traffic_shift() {
  local version="$1"
  local target_env="$2"
  local blue_weight="$3"
  local green_weight="$4"
  
  if [ "${SERVICE_REGISTRY_ENABLED:-true}" = "true" ]; then
    bgd_log_info "Updating service registry after traffic shift"
    
    # Update registry to reflect traffic distribution
    local registry_file="${SERVICE_REGISTRY_FILE:-service-registry.json}"
    if [ -f "$registry_file" ]; then
      local blue_percentage=$((blue_weight * 10))
      local green_percentage=$((green_weight * 10))
      
      local tmp_file=$(mktemp)
      jq --arg name "$APP_NAME" \
         --arg blue "$blue_percentage" \
         --arg green "$green_percentage" \
         '.services[$name].traffic = {"blue": $blue | tonumber, "green": $green | tonumber}' \
         "$registry_file" > "$tmp_file" && mv "$tmp_file" "$registry_file"
    fi
  fi
  
  return 0
}
