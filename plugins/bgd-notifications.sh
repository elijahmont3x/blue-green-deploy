#!/bin/bash
#
# bgd-notifications.sh - Notification plugin for Blue/Green Deployment
#
# This plugin provides notification capabilities for deployment events:
# - Telegram notifications
# - Slack notifications
# - Customizable notification levels and events

# Register plugin arguments
bgd_register_notification_arguments() {
  bgd_register_plugin_argument "notification" "NOTIFY_ENABLED" "false"
  bgd_register_plugin_argument "notification" "TELEGRAM_BOT_TOKEN" ""
  bgd_register_plugin_argument "notification" "TELEGRAM_CHAT_ID" ""
  bgd_register_plugin_argument "notification" "SLACK_WEBHOOK" ""
  bgd_register_plugin_argument "notification" "NOTIFY_EVENTS" "deploy,cutover,rollback,error"
}

# Send a notification
bgd_send_notification() {
  local message="$1"
  local level="${2:-info}"
  
  # Skip if notifications are disabled
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  # Add emoji based on level
  local emoji=""
  case "$level" in
    info) emoji="ℹ️" ;;
    warning) emoji="⚠️" ;;
    error) emoji="🚨" ;;
    success) emoji="✅" ;;
    *) emoji="ℹ️" ;;
  esac
  
  local formatted_message="$emoji *${APP_NAME}*: $message"
  
  # Send to Telegram if configured
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    bgd_log "Sending Telegram notification" "debug"
    
    # Securely send notification
    local telegram_token="${TELEGRAM_BOT_TOKEN}"
    local chat_id="${TELEGRAM_CHAT_ID}"
    
    curl -s -X POST "https://api.telegram.org/bot${telegram_token}/sendMessage" \
      -d "chat_id=${chat_id}" \
      -d "text=${formatted_message}" \
      -d "parse_mode=Markdown" > /dev/null
    
    local status=$?
    if [ $status -ne 0 ]; then
      bgd_log "Failed to send Telegram notification" "warning"
    fi
  fi
  
  # Send to Slack if configured
  if [ -n "${SLACK_WEBHOOK:-}" ]; then
    bgd_log "Sending Slack notification" "debug"
    
    # Securely send notification
    local slack_webhook="${SLACK_WEBHOOK}"
    
    curl -s -X POST "${slack_webhook}" \
      -H "Content-Type: application/json" \
      -d "{\"text\":\"${formatted_message}\"}" > /dev/null
    
    local status=$?
    if [ $status -ne 0 ]; then
      bgd_log "Failed to send Slack notification" "warning"
    fi
  fi
  
  return 0
}

# Deploy hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"deploy"* ]]; then
    bgd_send_notification "Deployment started: $app_name v$version" "info"
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"deploy"* ]]; then
    bgd_send_notification "Deployment of version $version to $env_name environment completed successfully" "success"
  fi
  
  return 0
}

# Cutover hooks
bgd_hook_pre_cutover() {
  local target_env="$1"
  
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"cutover"* ]]; then
    bgd_send_notification "Starting traffic cutover to $target_env environment" "info"
  fi
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"cutover"* ]]; then
    bgd_send_notification "Traffic cutover to $target_env environment completed successfully" "success"
  fi
  
  return 0
}

# Rollback hooks
bgd_hook_pre_rollback() {
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"rollback"* ]]; then
    bgd_send_notification "Starting rollback operation" "warning"
  fi
  
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"rollback"* ]]; then
    bgd_send_notification "Rollback to $rollback_env environment completed" "warning"
  fi
  
  return 0
}

# Error handler
bgd_hook_error() {
  local error_message="$1"
  local error_context="$2"
  
  if [[ "${NOTIFY_ENABLED:-false}" = "true" ]] && [[ "${NOTIFY_EVENTS:-}" == *"error"* ]]; then
    bgd_send_notification "Error: $error_message ($error_context)" "error"
  fi
  
  return 0
}