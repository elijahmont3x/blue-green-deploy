#!/bin/bash
#
# bgd-notification.sh - Example notification plugin for Blue/Green Deployment
#
# This plugin demonstrates how to implement hooks in the new namespaced structure
# to send notifications at different points in the deployment process.
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
bgd_register_notification_arguments() {
  bgd_register_plugin_argument "notification" "NOTIFY_EMAIL" ""
  bgd_register_plugin_argument "notification" "NOTIFY_SLACK_WEBHOOK" ""
  bgd_register_plugin_argument "notification" "NOTIFY_EVENTS" "deploy,rollback,error"
  bgd_register_plugin_argument "notification" "NOTIFY_SILENT" "false"
}

# Helper function to send email notifications
bgd_send_email_notification() {
  local subject="$1"
  local message="$2"
  
  if [ -n "${NOTIFY_EMAIL:-}" ]; then
    bgd_log_info "Sending email notification to $NOTIFY_EMAIL"
    bgd_log_info "Subject: $subject"
    bgd_log_info "Message: $message"
    
    # In a real implementation, you'd use a tool like mail or sendmail
    # Example:
    # echo -e "$message" | mail -s "$subject" "$NOTIFY_EMAIL"
    
    # For now, just log that we would send it
    bgd_log_info "Email would be sent if this were a real implementation"
  fi
}

# Helper function to send Slack notifications
bgd_send_slack_notification() {
  local message="$1"
  
  if [ -n "${NOTIFY_SLACK_WEBHOOK:-}" ]; then
    bgd_log_info "Sending Slack notification"
    
    # In a real implementation, you'd use curl to post to the webhook
    # Example:
    # curl -X POST -H 'Content-type: application/json' \
    #   --data "{\"text\":\"$message\"}" \
    #   "$NOTIFY_SLACK_WEBHOOK"
    
    # For now, just log that we would send it
    bgd_log_info "Slack message would be sent if this were a real implementation"
    bgd_log_info "Message: $message"
  fi
}

# Deploy hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"deploy"* ]]; then
    bgd_send_email_notification \
      "Deployment started: $app_name v$version" \
      "A new deployment of $app_name version $version has started.\n\nTime: $(date)"
      
    bgd_send_slack_notification \
      "🚀 *Deployment started*: $app_name v$version"
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"deploy"* ]]; then
    bgd_send_email_notification \
      "Deployment completed: ${APP_NAME:-unknown} v$version" \
      "Deployment of ${APP_NAME:-unknown} version $version to $env_name environment has completed successfully.\n\nTime: $(date)"
      
    bgd_send_slack_notification \
      "✅ *Deployment completed*: ${APP_NAME:-unknown} v$version to $env_name environment"
  fi
  
  return 0
}

# Cutover hooks
bgd_hook_pre_cutover() {
  local target_env="$1"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"cutover"* ]]; then
    bgd_send_slack_notification \
      "🔄 *Traffic cutover starting*: Shifting traffic to $APP_NAME $target_env environment"
  fi
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"cutover"* ]]; then
    bgd_send_email_notification \
      "Traffic cutover completed: $APP_NAME" \
      "Traffic has been successfully shifted to the $target_env environment for $APP_NAME.\n\nTime: $(date)"
      
    bgd_send_slack_notification \
      "✅ *Traffic cutover completed*: All traffic now routed to $APP_NAME $target_env environment"
  fi
  
  return 0
}

# Rollback hooks
bgd_hook_pre_rollback() {
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"rollback"* ]]; then
    bgd_send_slack_notification \
      "⚠️ *Rollback initiated*: Rolling back $APP_NAME"
  fi
  
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"rollback"* ]]; then
    bgd_send_email_notification \
      "Rollback completed: $APP_NAME" \
      "Rollback of $APP_NAME to $rollback_env environment has completed.\n\nTime: $(date)"
      
    bgd_send_slack_notification \
      "✅ *Rollback completed*: $APP_NAME has been rolled back to $rollback_env environment"
  fi
  
  return 0
}

# Health check hook
bgd_hook_post_health() {
  local version="$1"
  local env_name="$2"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"health"* ]]; then
    bgd_send_slack_notification \
      "💚 *Health checks passed*: $APP_NAME v$version ($env_name environment) is healthy"
  fi
  
  return 0
}

# Error handling hook (this would be called in the error paths of your scripts)
bgd_hook_error() {
  local error_message="$1"
  local error_context="$2"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"error"* ]]; then
    bgd_send_email_notification \
      "ERROR: $APP_NAME deployment issue" \
      "An error occurred during deployment of $APP_NAME:\n\n$error_message\n\nContext: $error_context\n\nTime: $(date)"
      
    bgd_send_slack_notification \
      "🚨 *ERROR*: $APP_NAME deployment issue\n>$error_message\n>Context: $error_context"
  fi
  
  return 0
}

# Cleanup hook
bgd_hook_cleanup() {
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"cleanup"* ]]; then
    bgd_send_slack_notification \
      "🧹 *Cleanup*: Cleaning up $APP_NAME environments"
  fi
  
  return 0
}

# Traffic shift hook
bgd_hook_post_traffic_shift() {
  local version="$1"
  local target_env="$2"
  local blue_weight="$3"
  local green_weight="$4"
  
  if [[ "${NOTIFY_SILENT:-false}" != "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"traffic"* ]]; then
    bgd_send_slack_notification \
      "🔄 *Traffic shifted*: $APP_NAME v$version - Blue: $blue_weight, Green: $green_weight"
  fi
  
  return 0
}
