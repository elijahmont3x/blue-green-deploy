#!/bin/bash
#
# bgd-profile-manager.sh - Profile management plugin for Blue/Green Deployment
#
# This plugin provides profile management capabilities:
# - Automatic profile discovery and validation
# - Service dependency resolution
# - Profile reporting

# Register plugin arguments
bgd_register_profile_manager_arguments() {
  bgd_register_plugin_argument "profile-manager" "AUTO_DISCOVER_PROFILES" "true"
  bgd_register_plugin_argument "profile-manager" "VALIDATE_PROFILES" "true"
  bgd_register_plugin_argument "profile-manager" "AUTO_RESOLVE_DEPENDENCIES" "true"
  bgd_register_plugin_argument "profile-manager" "DEFAULT_PROFILE" "${ENV_NAME:-blue}"
  bgd_register_plugin_argument "profile-manager" "INCLUDE_PERSISTENCE" "true"
}

# Discover profiles in docker-compose.yml
bgd_discover_profiles() {
  local compose_file="${1:-docker-compose.yml}"
  
  bgd_log "Discovering profiles in $compose_file" "info"
  
  if ! [ -f "$compose_file" ]; then
    bgd_log "Docker Compose file not found: $compose_file" "error"
    return 1
  fi
  
  # Use yq if available, otherwise fallback to grep and awk
  if command -v yq &> /dev/null; then
    local profiles=$(yq eval '.services.*.profiles[]' "$compose_file" | sort -u)
    if [ -z "$profiles" ]; then
      bgd_log "No profiles found in $compose_file" "warning"
      return 1
    fi
    echo "$profiles"
    return 0
  else
    # Fallback method using grep and awk
    local profiles=$(grep -A 1 "profiles:" "$compose_file" | grep -v "profiles:" | awk -F'"' '{print $2}' | sort -u)
    if [ -z "$profiles" ]; then
      bgd_log "No profiles found in $compose_file" "warning"
      return 1
    fi
    echo "$profiles"
    return 0
  fi
}

# Validate that services have profiles defined
bgd_validate_profiles() {
  local compose_file="${1:-docker-compose.yml}"
  
  bgd_log "Validating profiles in $compose_file" "info"
  
  if ! [ -f "$compose_file" ]; then
    bgd_log "Docker Compose file not found: $compose_file" "error"
    return 1
  fi
  
  local missing_profiles=0
  
  # Find services without profiles
  if command -v yq &> /dev/null; then
    # Get all services
    local all_services=$(yq eval '.services | keys | .[]' "$compose_file")
    
    # Check each service for profiles
    for service in $all_services; do
      if ! yq eval ".services.${service}.profiles" "$compose_file" | grep -q "\[" ; then
        bgd_log "Service '$service' has no profiles defined" "warning"
        missing_profiles=$((missing_profiles + 1))
      fi
    done
  else
    # Fallback method using grep
    local services=$(grep -E "^  [a-zA-Z0-9_-]+:" "$compose_file" | sed 's/://' | tr -d ' ')
    
    for service in $services; do
      if ! grep -A 10 "^  $service:" "$compose_file" | grep -q "profiles:"; then
        bgd_log "Service '$service' has no profiles defined" "warning"
        missing_profiles=$((missing_profiles + 1))
      fi
    done
  fi
  
  if [ $missing_profiles -gt 0 ]; then
    bgd_log "Found $missing_profiles services without profiles" "warning"
    return 1
  else
    bgd_log "All services have profiles defined" "success"
    return 0
  fi
}

# Get services for a specific profile
bgd_get_profile_services() {
  local compose_file="${1:-docker-compose.yml}"
  local profile="$2"
  
  bgd_log "Getting services for profile: $profile" "info"
  
  if ! [ -f "$compose_file" ]; then
    bgd_log "Docker Compose file not found: $compose_file" "error"
    return 1
  fi
  
  # Use yq if available, otherwise fallback to grep
  if command -v yq &> /dev/null; then
    local services=$(yq eval ".services | to_entries | .[] | select(.value.profiles | contains([\"$profile\"])) | .key" "$compose_file")
    echo "$services"
    return 0
  else
    # Fallback method - less accurate but workable
    local services=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^[[:space:]]*([a-zA-Z0-9_-]+): ]]; then
        service="${BASH_REMATCH[1]}"
        # Look for profiles section
        if grep -A 5 "^[[:space:]]*$service:" "$compose_file" | grep -q "$profile"; then
          services="$services $service"
        fi
      fi
    done < "$compose_file"
    
    echo "$services"
    return 0
  fi
}

# Resolve service dependencies
bgd_resolve_dependencies() {
  local compose_file="${1:-docker-compose.yml}"
  local service_list="$2"
  
  bgd_log "Resolving dependencies for services: $service_list" "info"
  
  if ! [ -f "$compose_file" ]; then
    bgd_log "Docker Compose file not found: $compose_file" "error"
    return 1
  fi
  
  local resolved_services="$service_list"
  
  # Add persistence profile if enabled
  if [ "${INCLUDE_PERSISTENCE:-true}" = "true" ]; then
    bgd_log "Checking for persistence services" "info"
    
    # Use yq if available
    if command -v yq &> /dev/null; then
      local persistence_services=$(yq eval '.services | to_entries | .[] | select(.value.profiles | contains(["persistence"])) | .key' "$compose_file")
      
      for service in $persistence_services; do
        if ! echo "$resolved_services" | grep -q "$service"; then
          bgd_log "Adding persistence service: $service" "info"
          if [ -n "$resolved_services" ]; then
            resolved_services="$resolved_services,$service"
          else
            resolved_services="$service"
          fi
        fi
      done
    else
      # Fallback method using grep
      local potential_services=$(grep -B 5 "persistence" "$compose_file" | grep -E "^  [a-zA-Z0-9_-]+:" | sed 's/://' | tr -d ' ')
      
      for service in $potential_services; do
        if ! echo "$resolved_services" | grep -q "$service"; then
          bgd_log "Adding potential persistence service: $service" "info"
          if [ -n "$resolved_services" ]; then
            resolved_services="$resolved_services,$service"
          else
            resolved_services="$service"
          fi
        fi
      done
    fi
  fi
  
  # Check dependency tree for each service
  for service in $(echo "$service_list" | tr ',' ' '); do
    # Skip empty services
    if [ -z "$service" ]; then
      continue
    fi
    
    bgd_log "Checking dependencies for service: $service" "debug"
    
    # Use yq if available
    if command -v yq &> /dev/null; then
      # Get direct dependencies
      local dependencies=$(yq eval ".services.${service}.depends_on[]" "$compose_file" 2>/dev/null)
      
      # Add dependencies if not already included
      for dep in $dependencies; do
        if ! echo "$resolved_services" | grep -q "$dep"; then
          bgd_log "Adding dependency: $dep" "info"
          resolved_services="$resolved_services,$dep"
          
          # Recursively resolve dependencies of this dependency
          local sub_deps=$(bgd_resolve_dependencies "$compose_file" "$dep")
          
          # Add any new dependencies found
          for sub_dep in $(echo "$sub_deps" | tr ',' ' '); do
            if [ -n "$sub_dep" ] && ! echo "$resolved_services" | grep -q "$sub_dep"; then
              resolved_services="$resolved_services,$sub_dep"
            fi
          done
        fi
      done
    else
      # Fallback method using grep
      local dependencies=$(grep -A 10 "^  $service:" "$compose_file" | grep -A 5 "depends_on:" | grep -v "depends_on:" | grep -v "^\s*$" | sed 's/-//' | tr -d ' ')
      
      # Add dependencies if not already included
      for dep in $dependencies; do
        if ! echo "$resolved_services" | grep -q "$dep"; then
          bgd_log "Adding dependency: $dep" "info"
          resolved_services="$resolved_services,$dep"
        fi
      done
    fi
  done
  
  # Clean up comma-separated list (remove duplicates, leading/trailing commas)
  resolved_services=$(echo "$resolved_services" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/^,//;s/,$//')
  
  echo "$resolved_services"
  return 0
}

# Generate profile information report
bgd_generate_profile_report() {
  local compose_file="${1:-docker-compose.yml}"
  local output_file="${2:-profile-report.txt}"
  
  bgd_log "Generating profile report for $compose_file" "info"
  
  if ! [ -f "$compose_file" ]; then
    bgd_log "Docker Compose file not found: $compose_file" "error"
    return 1
  fi
  
  # Create report header
  cat > "$output_file" << EOL
===================================================
Docker Compose Profile Report
===================================================
File: $compose_file
Generated: $(date)

===================================================
1. Available Profiles
===================================================
EOL

  # Add discovered profiles
  local profiles=$(bgd_discover_profiles "$compose_file")
  echo "$profiles" | while read -r profile; do
    echo "- $profile" >> "$output_file"
  done

  # Add services section
  cat >> "$output_file" << EOL

===================================================
2. Services by Profile
===================================================
EOL

  # For each profile, list the services
  for profile in $profiles; do
    echo "Profile: $profile" >> "$output_file"
    echo "----------------" >> "$output_file"
    
    if command -v yq &> /dev/null; then
      local services=$(yq eval ".services | to_entries | .[] | select(.value.profiles | contains([\"$profile\"])) | .key" "$compose_file")
      echo "$services" | while read -r service; do
        echo "- $service" >> "$output_file"
      done
    else
      # Fallback method using grep
      local services=$(grep -B 10 "$profile" "$compose_file" | grep -E "^  [a-zA-Z0-9_-]+:" | sed 's/://' | tr -d ' ' | sort -u)
      for service in $services; do
        echo "- $service" >> "$output_file"
      done
    fi
    
    echo "" >> "$output_file"
  done

  # Add dependency section
  cat >> "$output_file" << EOL
===================================================
3. Service Dependencies
===================================================
EOL

  # List services and their dependencies
  if command -v yq &> /dev/null; then
    local all_services=$(yq eval '.services | keys | .[]' "$compose_file")
    
    for service in $all_services; do
      echo "Service: $service" >> "$output_file"
      
      # Get dependencies
      local deps=$(yq eval ".services.${service}.depends_on[]" "$compose_file" 2>/dev/null)
      
      if [ -n "$deps" ]; then
        echo "Dependencies:" >> "$output_file"
        echo "$deps" | while read -r dep; do
          echo "- $dep" >> "$output_file"
        done
      else
        echo "No explicit dependencies" >> "$output_file"
      fi
      
      echo "" >> "$output_file"
    done
  else
    # Simplified version for non-yq environments
    grep -E "^  [a-zA-Z0-9_-]+:" "$compose_file" | sed 's/://' | tr -d ' ' | while read -r service; do
      echo "Service: $service" >> "$output_file"
      
      # Try to find dependencies
      local deps=$(grep -A 5 "^  $service:" "$compose_file" | grep -A 5 "depends_on:" | grep -v "depends_on:" | grep -v "^\s*$" | sed 's/-//' | tr -d ' ')
      
      if [ -n "$deps" ]; then
        echo "Dependencies:" >> "$output_file"
        echo "$deps" | while read -r dep; do
          echo "- $dep" >> "$output_file"
        done
      else
        echo "No explicit dependencies" >> "$output_file"
      fi
      
      echo "" >> "$output_file"
    done
  fi

  # Add profile recommendations
  cat >> "$output_file" << EOL
===================================================
4. Profile Recommendations
===================================================
EOL

  # Example recommendation for blue/green deployment
  cat >> "$output_file" << EOL
For Blue/Green deployment:
- Use "blue" and "green" profiles for environment-specific services
- Use "persistence" profile for shared services like databases
- Use "tools" profile for utility services (monitoring, etc.)

Recommended service groups:
- Frontend services: Use environment profiles
- API services: Use environment profiles
- Database services: Use persistence profile
- Cache services: Use persistence profile
EOL

  bgd_log "Profile report generated: $output_file" "success"
  return 0
}

# Hook: Before deployment, validate profiles if enabled
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [ "${VALIDATE_PROFILES:-true}" = "true" ]; then
    bgd_validate_profiles "docker-compose.yml" || {
      bgd_log "Profile validation failed, continuing anyway" "warning"
    }
  fi
  
  # Auto-resolve dependencies if enabled and services specified
  if [ "${AUTO_RESOLVE_DEPENDENCIES:-true}" = "true" ] && [ -n "${SERVICES:-}" ]; then
    SERVICES=$(bgd_resolve_dependencies "docker-compose.yml" "$SERVICES")
    export SERVICES
    bgd_log "Resolved service dependencies: $SERVICES" "info"
  fi
  
  return 0
}

# Hook: After deployment, generate profile report
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Generate profile report
  if [ "${AUTO_DISCOVER_PROFILES:-true}" = "true" ]; then
    bgd_generate_profile_report "docker-compose.yml" "${BGD_LOGS_DIR}/profile-report-${version}.txt"
  fi
  
  return 0
}