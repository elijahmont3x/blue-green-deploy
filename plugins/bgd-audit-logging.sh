#!/bin/bash
#
# bgd-audit-logging.sh - Audit logging plugin for Blue/Green Deployment
#
# This plugin provides comprehensive deployment event tracking:
# - Records deployment events with timestamps
# - Captures environment details
# - Integrates with external monitoring systems
# - Provides detailed logging and reporting
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
bgd_register_audit_logging_arguments() {
  bgd_register_plugin_argument "audit-logging" "AUDIT_LOG_LEVEL" "info"
  bgd_register_plugin_argument "audit-logging" "AUDIT_LOG_FILE" "audit.log"
  bgd_register_plugin_argument "audit-logging" "AUDIT_RETENTION_DAYS" "90"
  bgd_register_plugin_argument "audit-logging" "AUDIT_METRICS_ENABLED" "false"
  bgd_register_plugin_argument "audit-logging" "AUDIT_METRICS_URL" ""
}

# Log an audit event
bgd_audit_log() {
  local event="$1"
  local severity="${2:-info}"
  local details="${3:-{}}"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  # Skip if level is less than configured
  local level_map=("debug" "info" "warning" "error" "critical")
  local config_level="${AUDIT_LOG_LEVEL:-info}"
  
  local config_level_idx=1  # default to info
  local event_level_idx=1   # default to info
  
  for i in "${!level_map[@]}"; do
    if [ "${level_map[$i]}" = "$config_level" ]; then
      config_level_idx=$i
    fi
    if [ "${level_map[$i]}" = "$severity" ]; then
      event_level_idx=$i
    fi
  done
  
  if [ $event_level_idx -lt $config_level_idx ]; then
    return 0
  fi
  
  # Create log file if it doesn't exist
  local log_file="${AUDIT_LOG_FILE:-audit.log}"
  touch "$log_file" 2>/dev/null || {
    bgd_log_warning "Unable to write to audit log file: $log_file"
    return 1
  }
  
  # Create event JSON
  local json_event=$(jq -n \
    --arg timestamp "$timestamp" \
    --arg app "$APP_NAME" \
    --arg version "${VERSION:-unknown}" \
    --arg event "$event" \
    --arg severity "$severity" \
    --argjson details "$details" \
    '{"timestamp": $timestamp, "app": $app, "version": $version, "event": $event, "severity": $severity, "details": $details}')
  
  # Write to log file
  echo "$json_event" >> "$log_file"
  
  # If metrics enabled, send to metrics endpoint
  if [ "${AUDIT_METRICS_ENABLED:-false}" = "true" ] && [ -n "${AUDIT_METRICS_URL:-}" ]; then
    curl -s -X POST -H "Content-Type: application/json" \
      -d "$json_event" "${AUDIT_METRICS_URL}/events" &>/dev/null || {
      bgd_log_warning "Failed to send audit event to metrics endpoint"
    }
  fi
  
  return 0
}

# Generate a deployment report
bgd_generate_report() {
  local deployment_id="$1"
  local output_file="${2:-report-${deployment_id}.txt}"
  
  bgd_log_info "Generating deployment report for $deployment_id"
  
  # Get logs for this deployment
  local log_file="${BGD_LOGS_DIR}/${APP_NAME}-${deployment_id}.log"
  
  if [ ! -f "$log_file" ]; then
    bgd_log_error "No deployment log found for $deployment_id"
    return 1
  fi
  
  # Create report header
  cat > "$output_file" << EOL
==================================================
Deployment Report: ${APP_NAME} v${deployment_id}
==================================================
Generated: $(date)

EOL
  
  # Add deployment steps
  echo "Deployment Steps:" >> "$output_file"
  echo "----------------" >> "$output_file"
  cat "$log_file" | sed 's/^/  /' >> "$output_file"
  
  # Add environment information
  echo >> "$output_file"
  echo "Environment Information:" >> "$output_file"
  echo "----------------------" >> "$output_file"
  echo "  Domain: ${DOMAIN_NAME:-unknown}" >> "$output_file"
  echo "  Image: ${IMAGE_REPO:-unknown}:${deployment_id}" >> "$output_file"
  
  # Get active environment
  read ACTIVE_ENV INACTIVE_ENV <<< $(bgd_get_environments)
  echo "  Active Environment: $ACTIVE_ENV" >> "$output_file"
  
  bgd_log_info "Deployment report generated: $output_file"
  return 0
}

# Clean up old audit logs
bgd_cleanup_audit_logs() {
  local retention_days="${AUDIT_RETENTION_DAYS:-90}"
  local log_file="${AUDIT_LOG_FILE:-audit.log}"
  
  bgd_log_info "Cleaning up audit logs older than $retention_days days"
  
  if [ -f "$log_file" ]; then
    # Create a temporary file with only recent logs
    local tmp_file=$(mktemp)
    local cutoff_date=$(date -d "$retention_days days ago" +"%Y-%m-%dT%H:%M:%SZ")
    
    jq -c "select(.timestamp >= \"$cutoff_date\")" "$log_file" > "$tmp_file"
    mv "$tmp_file" "$log_file"
  fi
}

# Audit Logging Hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  # Log deployment start event
  local details=$(jq -n \
    --arg app_name "$app_name" \
    --arg version "$version" \
    '{"app": $app_name, "version": $version}')
    
  bgd_audit_log "deployment_started" "info" "$details"
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Log deployment complete event
  local details=$(jq -n \
    --arg app_name "$APP_NAME" \
    --arg version "$version" \
    --arg env_name "$env_name" \
    '{"app": $app_name, "version": $version, "environment": $env_name}')
    
  bgd_audit_log "deployment_completed" "info" "$details"
  
  # Generate deployment report
  bgd_generate_report "$version"
  
  # Clean up old audit logs
  bgd_cleanup_audit_logs
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  # Log cutover event
  local details=$(jq -n \
    --arg app_name "$APP_NAME" \
    --arg target_env "$target_env" \
    '{"app": $app_name, "environment": $target_env}')
    
  bgd_audit_log "cutover_completed" "info" "$details"
  
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  # Log rollback event
  local details=$(jq -n \
    --arg app_name "$APP_NAME" \
    --arg rollback_env "$rollback_env" \
    '{"app": $app_name, "environment": $rollback_env}')
    
  bgd_audit_log "rollback_completed" "warning" "$details"
  
  return 0
}

bgd_hook_post_traffic_shift() {
  local version="$1"
  local target_env="$2"
  local blue_weight="$3"
  local green_weight="$4"
  
  # Log traffic shift event
  local details=$(jq -n \
    --arg app_name "$APP_NAME" \
    --arg version "$version" \
    --arg target_env "$target_env" \
    --argjson blue_weight "$blue_weight" \
    --argjson green_weight "$green_weight" \
    '{"app": $app_name, "version": $version, "environment": $target_env, "traffic": {"blue": $blue_weight, "green": $green_weight}}')
    
  bgd_audit_log "traffic_shifted" "info" "$details"
  
  return 0
}
