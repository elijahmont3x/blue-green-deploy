#!/bin/bash
#
# service-discovery.sh - Service discovery plugin for blue/green deployments
#
# This plugin enables automatic service discovery and registration for
# blue/green deployments. It uses Docker's internal DNS and optional
# external service registry integration.
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
register_service_discovery_arguments() {
  register_plugin_argument "service-discovery" "SERVICE_REGISTRY_ENABLED" "false"
  register_plugin_argument "service-discovery" "SERVICE_REGISTRY_URL" ""
  register_plugin_argument "service-discovery" "SERVICE_AUTO_GENERATE_URLS" "true"
}

# Global variables
DISCOVERY_FILE="./service-registry.json"

# Register a service with the service registry
register_service() {
  local service_name="$1"
  local env_name="$2"
  local version="$3"
  local port="$4"
  local health_endpoint="${5:-/health}"
  
  # Create local service registry if it doesn't exist
  if [ ! -f "$DISCOVERY_FILE" ]; then
    echo '{"services":[]}' > "$DISCOVERY_FILE"
  fi
  
  # Define service info
  local service_info=$(cat << EOF
{
  "name": "${service_name}",
  "environment": "${env_name}",
  "version": "${version}",
  "endpoint": "http://${APP_NAME}-${env_name}-${service_name}-1:${port}",
  "external_endpoint": "http://localhost:${port}",
  "health_check": "${health_endpoint}",
  "registered_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

  # Update local registry
  local temp_file=$(mktemp)
  jq --argjson service "$service_info" '.services += [$service]' "$DISCOVERY_FILE" > "$temp_file"
  mv "$temp_file" "$DISCOVERY_FILE"
  
  log_info "Registered service ${service_name} (${env_name}) in local registry"
  
  # Register with external registry if configured
  if [ "$SERVICE_REGISTRY_ENABLED" = "true" ] && [ -n "$SERVICE_REGISTRY_URL" ]; then
    log_info "Registering service with external registry at $SERVICE_REGISTRY_URL"
    
    curl -s -X POST \
      -H "Content-Type: application/json" \
      -d "$service_info" \
      "${SERVICE_REGISTRY_URL}/services" || \
      log_warning "Failed to register with external service registry"
  fi
  
  return 0
}

# Deregister a service from the registry
deregister_service() {
  local service_name="$1"
  local env_name="$2"
  
  # Update local registry
  if [ -f "$DISCOVERY_FILE" ]; then
    local temp_file=$(mktemp)
    jq --arg name "$service_name" --arg env "$env_name" \
      '.services = [.services[] | select(.name != $name or .environment != $env)]' \
      "$DISCOVERY_FILE" > "$temp_file"
    mv "$temp_file" "$DISCOVERY_FILE"
    log_info "Deregistered service ${service_name} (${env_name}) from local registry"
  fi
  
  # Deregister from external registry if configured
  if [ "$SERVICE_REGISTRY_ENABLED" = "true" ] && [ -n "$SERVICE_REGISTRY_URL" ]; then
    log_info "Deregistering service from external registry"
    
    curl -s -X DELETE \
      "${SERVICE_REGISTRY_URL}/services/${service_name}/${env_name}" || \
      log_warning "Failed to deregister from external service registry"
  fi
  
  return 0
}

# Get service information
get_service_info() {
  local service_name="$1"
  local env_name="$2"
  
  if [ -f "$DISCOVERY_FILE" ]; then
    jq --arg name "$service_name" --arg env "$env_name" \
      '.services[] | select(.name == $name and .environment == $env)' \
      "$DISCOVERY_FILE"
    return $?
  fi
  
  return 1
}

# List all registered services
list_services() {
  if [ -f "$DISCOVERY_FILE" ]; then
    jq '.services' "$DISCOVERY_FILE"
    return $?
  fi
  
  echo "[]"
  return 0
}

# Generate service URLs for environment variables
generate_service_urls() {
  local env_name="$1"
  local env_file=".env.${env_name}"
  
  if [ ! -f "$DISCOVERY_FILE" ]; then
    return 0
  fi
  
  if [ "$SERVICE_AUTO_GENERATE_URLS" != "true" ]; then
    return 0
  fi
  
  log_info "Generating service URLs for $env_name environment"
  
  # Loop through services and add URLs to env file
  local services=$(jq -r '.services[].name' "$DISCOVERY_FILE" | sort | uniq)
  for service in $services; do
    local service_url=$(jq -r --arg name "$service" --arg env "$env_name" \
      '.services[] | select(.name == $name and .environment == $env) | .endpoint // empty' \
      "$DISCOVERY_FILE")
    
    if [ -n "$service_url" ]; then
      local env_var="${service^^}_URL"  # Convert to uppercase
      echo "${env_var}=${service_url}" >> "$env_file"
      log_info "Added ${env_var}=${service_url} to environment"
    fi
  done
  
  return 0
}

# Generate nginx configuration for discovered services
generate_nginx_config() {
  local template_file="$1"
  local output_file="$2"
  
  if [ ! -f "$DISCOVERY_FILE" ]; then
    log_warning "No service registry found, skipping nginx configuration generation"
    return 0
  fi
  
  log_info "Generating nginx configuration for discovered services"
  
  # Start with base template
  cat "$template_file" > "$output_file"
  
  # Add upstream blocks for each service type
  local service_types=$(jq -r '.services[].name' "$DISCOVERY_FILE" | sort | uniq)
  for service_type in $service_types; do
    # Skip if already in the template
    if grep -q "upstream $service_type {" "$output_file"; then
      continue
    fi
    
    # Add new upstream block
    cat >> "$output_file" << EOF
    
    # Auto-generated upstream for $service_type
    upstream $service_type {
EOF
    
    # Add server entries for blue/green environments
    local blue_endpoint=$(jq -r --arg name "$service_type" --arg env "blue" \
      '.services[] | select(.name == $name and .environment == $env) | .endpoint // empty' \
      "$DISCOVERY_FILE" | sed 's|http://||')
    
    local green_endpoint=$(jq -r --arg name "$service_type" --arg env "green" \
      '.services[] | select(.name == $name and .environment == $env) | .endpoint // empty' \
      "$DISCOVERY_FILE" | sed 's|http://||')
    
    # Add blue endpoint with weight if exists
    if [ -n "$blue_endpoint" ]; then
      echo "        server $blue_endpoint weight=BLUE_WEIGHT;" >> "$output_file"
    fi
    
    # Add green endpoint with weight if exists
    if [ -n "$green_endpoint" ]; then
      echo "        server $green_endpoint weight=GREEN_WEIGHT;" >> "$output_file"
    fi
    
    # Close upstream block
    echo "    }" >> "$output_file"
  done
  
  return 0
}

# Register services after deployment
hook_post_health() {
  local version="$1"
  local env_name="$2"
  
  if [ "$SERVICE_REGISTRY_ENABLED" != "true" ]; then
    return 0
  fi
  
  log_info "Registering services for $env_name environment"
  
  # Register the main app service
  register_service "app" "$env_name" "$version" "3000" "$HEALTH_ENDPOINT"
  
  # Check for frontend service and register if exists
  if docker ps --format "{{.Names}}" | grep -q "${APP_NAME}-${env_name}-frontend"; then
    register_service "frontend" "$env_name" "${FRONTEND_VERSION:-$version}" "80" "/health"
  fi
  
  # Generate service URLs for environment
  generate_service_urls "$env_name"
  
  return 0
}

# Deregister services after cutover
hook_post_cutover() {
  local new_env="$1"
  local old_env="$2"
  
  if [ "$SERVICE_REGISTRY_ENABLED" != "true" ]; then
    return 0
  fi
  
  # Only deregister if old environment is being stopped
  if [ "$KEEP_OLD" != "true" ]; then
    log_info "Deregistering services for $old_env environment"
    
    # Deregister all services for old environment
    if [ -f "$DISCOVERY_FILE" ]; then
      local services=$(jq -r --arg env "$old_env" \
        '.services[] | select(.environment == $env) | .name' \
        "$DISCOVERY_FILE" | sort | uniq)
      
      for service in $services; do
        deregister_service "$service" "$old_env"
      done
    fi
  fi
  
  return 0
}