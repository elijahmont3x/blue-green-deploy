#!/bin/bash
#
# bgd-notifications.sh - Notification Plugin for Blue/Green Deployment
# 
# This plugin provides deployment notifications:
# - Slack webhooks
# - Microsoft Teams webhooks
# - Email notifications
# - Custom webhook integrations

# Register plugin arguments
bgd_register_notification_arguments() {
  bgd_register_plugin_argument "notifications" "NOTIFY_ENABLED" "false"
  bgd_register_plugin_argument "notifications" "NOTIFY_CHANNELS" "slack"
  bgd_register_plugin_argument "notifications" "SLACK_WEBHOOK_URL" ""
  bgd_register_plugin_argument "notifications" "TEAMS_WEBHOOK_URL" ""
  bgd_register_plugin_argument "notifications" "EMAIL_RECIPIENTS" ""
  bgd_register_plugin_argument "notifications" "EMAIL_FROM" "bgd-deploy@example.com"
  bgd_register_plugin_argument "notifications" "EMAIL_SUBJECT_PREFIX" "[BGD] "
  bgd_register_plugin_argument "notifications" "CUSTOM_WEBHOOK_URL" ""
  bgd_register_plugin_argument "notifications" "CUSTOM_WEBHOOK_AUTH" ""
  bgd_register_plugin_argument "notifications" "NOTIFICATION_LEVELS" "success,error,warning"
}

# Send notification through configured channels
bgd_send_notification() {
  local message="$1"
  local level="${2:-info}"
  
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  # Check if notification level is enabled
  local enabled_levels="${NOTIFICATION_LEVELS:-success,error,warning}"
  if ! echo "$enabled_levels" | grep -q "$level"; then
    bgd_log "Notification level '$level' is not enabled" "debug"
    return 0
  fi
  
  bgd_log "Sending notification: $message (level: $level)" "info"
  
  # Get configured channels
  local channels="${NOTIFY_CHANNELS:-slack}"
  
  # Process each channel
  IFS=',' read -ra CHANNELS <<< "$channels"
  for channel in "${CHANNELS[@]}"; do
    case "$channel" in
      slack)
        bgd_send_slack_notification "$message" "$level"
        ;;
      teams)
        bgd_send_teams_notification "$message" "$level"
        ;;
      email)
        bgd_send_email_notification "$message" "$level"
        ;;
      webhook)
        bgd_send_webhook_notification "$message" "$level"
        ;;
      *)
        bgd_log "Unknown notification channel: $channel" "warning"
        ;;
    esac
  done
  
  return 0
}

# Send notification to Slack
bgd_send_slack_notification() {
  local message="$1"
  local level="${2:-info}"
  local webhook_url="${SLACK_WEBHOOK_URL:-}"
  
  if [ -z "$webhook_url" ]; then
    bgd_log "Slack webhook URL not configured" "warning"
    return 1
  fi
  
  # Determine color based on level
  local color=""
  case "$level" in
    success)
      color="#36a64f"  # Green
      ;;
    warning)
      color="#f2c744"  # Yellow
      ;;
    error)
      color="#d00000"  # Red
      ;;
    info|*)
      color="#3aa3e3"  # Blue
      ;;
  esac
  
  # Add app and version info if available
  local context=""
  if [ -n "${APP_NAME:-}" ]; then
    context+="App: ${APP_NAME}"
  fi
  
  if [ -n "${VERSION:-}" ]; then
    context+="${context:+ | }Version: ${VERSION}"
  fi
  
  if [ -n "${TARGET_ENV:-}" ]; then
    context+="${context:+ | }Environment: ${TARGET_ENV}"
  fi
  
  # Prepare JSON payload
  local payload='{
    "attachments": [
      {
        "fallback": "'$(echo "$message" | sed 's/"/\\"/g')'",
        "color": "'$color'",
        "title": "'$(echo "$level" | tr '[:lower:]' '[:upper:]')'",
        "text": "'$(echo "$message" | sed 's/"/\\"/g')'",
        "footer": "'$(echo "$context" | sed 's/"/\\"/g')'"
      }
    ]
  }'
  
  # Send notification
  local result=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url")
  
  if [ "$result" = "ok" ]; then
    bgd_log "Slack notification sent successfully" "debug"
    return 0
  else
    bgd_log "Failed to send Slack notification: $result" "warning"
    return 1
  fi
}

# Send notification to Microsoft Teams
bgd_send_teams_notification() {
  local message="$1"
  local level="${2:-info}"
  local webhook_url="${TEAMS_WEBHOOK_URL:-}"
  
  if [ -z "$webhook_url" ]; then
    bgd_log "Teams webhook URL not configured" "warning"
    return 1
  fi
  
  # Determine color based on level
  local color=""
  case "$level" in
    success)
      color="#36a64f"  # Green
      ;;
    warning)
      color="#f2c744"  # Yellow
      ;;
    error)
      color="#d00000"  # Red
      ;;
    info|*)
      color="#3aa3e3"  # Blue
      ;;
  esac
  
  # Prepare JSON payload
  local title=$(echo "$level" | tr '[:lower:]' '[:upper:]')
  local payload='{
    "@type": "MessageCard",
    "@context": "http://schema.org/extensions",
    "themeColor": "'$color'",
    "summary": "'$title': '$(echo "$message" | sed 's/"/\\"/g')'",
    "sections": [
      {
        "activityTitle": "'$title'",
        "activitySubtitle": "Blue/Green Deployment",
        "text": "'$(echo "$message" | sed 's/"/\\"/g')'"
      }
    ]
  }'
  
  # Add app and version facts if available
  if [ -n "${APP_NAME:-}" ] || [ -n "${VERSION:-}" ] || [ -n "${TARGET_ENV:-}" ]; then
    # Remove the closing brackets to add facts
    payload=${payload%]}}
    payload+=',
        "facts": ['
    
    local first=true
    
    if [ -n "${APP_NAME:-}" ]; then
      payload+='
          {
            "name": "App",
            "value": "'$APP_NAME'"
          }'
      first=false
    fi
    
    if [ -n "${VERSION:-}" ]; then
      if [ "$first" = false ]; then payload+=','; fi
      payload+='
          {
            "name": "Version",
            "value": "'$VERSION'"
          }'
      first=false
    fi
    
    if [ -n "${TARGET_ENV:-}" ]; then
      if [ "$first" = false ]; then payload+=','; fi
      payload+='
          {
            "name": "Environment",
            "value": "'$TARGET_ENV'"
          }'
    fi
    
    payload+='
        ]'
    
    # Close the JSON structure
    payload+='
      }
    ]
  }'
  fi
  
  # Send notification
  local result=$(curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$webhook_url")
  
  if [ -z "$result" ]; then
    bgd_log "Teams notification sent successfully" "debug"
    return 0
  else
    bgd_log "Failed to send Teams notification: $result" "warning"
    return 1
  fi
}

# Send notification via email
bgd_send_email_notification() {
  local message="$1"
  local level="${2:-info}"
  local recipients="${EMAIL_RECIPIENTS:-}"
  local from="${EMAIL_FROM:-bgd-deploy@example.com}"
  local subject_prefix="${EMAIL_SUBJECT_PREFIX:-[BGD] }"
  
  if [ -z "$recipients" ]; then
    bgd_log "Email recipients not configured" "warning"
    return 1
  fi
  
  # Check if mail command is available
  if ! command -v mail &>/dev/null; then
    bgd_log "Mail command not available, cannot send email" "warning"
    return 1
  fi
  
  # Prepare email subject
  local subject="${subject_prefix}$(echo "$level" | tr '[:lower:]' '[:upper:]')"
  
  if [ -n "${APP_NAME:-}" ]; then
    subject+=" - ${APP_NAME}"
  fi
  
  if [ -n "${VERSION:-}" ]; then
    subject+=" v${VERSION}"
  fi
  
  # Add app and version info if available
  local body="$message\n\n"
  
  if [ -n "${APP_NAME:-}" ]; then
    body+="App: ${APP_NAME}\n"
  fi
  
  if [ -n "${VERSION:-}" ]; then
    body+="Version: ${VERSION}\n"
  fi
  
  if [ -n "${TARGET_ENV:-}" ]; then
    body+="Environment: ${TARGET_ENV}\n"
  fi
  
  body+="\nTimestamp: $(date)\n"
  
  # Send email
  echo -e "$body" | mail -s "$subject" -r "$from" "$recipients"
  
  local status=$?
  if [ $status -eq 0 ]; then
    bgd_log "Email notification sent successfully to $recipients" "debug"
    return 0
  else
    bgd_log "Failed to send email notification: $status" "warning"
    return 1
  fi
}

# Send notification to custom webhook
bgd_send_webhook_notification() {
  local message="$1"
  local level="${2:-info}"
  local webhook_url="${CUSTOM_WEBHOOK_URL:-}"
  local webhook_auth="${CUSTOM_WEBHOOK_AUTH:-}"
  
  if [ -z "$webhook_url" ]; then
    bgd_log "Custom webhook URL not configured" "warning"
    return 1
  fi
  
  # Prepare JSON payload
  local payload='{
    "level": "'$level'",
    "message": "'$(echo "$message" | sed 's/"/\\"/g')'"'
  
  # Add app and version info if available
  if [ -n "${APP_NAME:-}" ]; then
    payload+=',
    "application": "'$APP_NAME'"'
  fi
  
  if [ -n "${VERSION:-}" ]; then
    payload+=',
    "version": "'$VERSION'"'
  fi
  
  if [ -n "${TARGET_ENV:-}" ]; then
    payload+=',
    "environment": "'$TARGET_ENV'"'
  fi
  
  # Add timestamp
  payload+=',
    "timestamp": "'$(date -u +"%Y-%m-%dT%H:%M:%SZ")'"
  }'
  
  # Prepare headers
  local headers=("-H" "Content-Type: application/json")
  
  # Add authorization if provided
  if [ -n "$webhook_auth" ]; then
    headers+=("-H" "Authorization: $webhook_auth")
  fi
  
  # Send notification
  local result=$(curl -s -X POST "${headers[@]}" -d "$payload" "$webhook_url")
  
  local status=$?
  if [ $status -eq 0 ]; then
    bgd_log "Custom webhook notification sent successfully" "debug"
    return 0
  else
    bgd_log "Failed to send custom webhook notification: $result" "warning"
    return 1
  fi
}

# Notification hooks for deployment lifecycle events
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local message="Deployment of version $version to $env_name environment completed successfully"
  bgd_send_notification "$message" "success"
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local message="Cutover to $target_env environment completed"
  if [ -n "${VERSION:-}" ]; then
    message+=" for version $VERSION"
  fi
  
  bgd_send_notification "$message" "success"
  
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local message="Rollback to $rollback_env environment completed"
  if [ -n "${VERSION:-}" ]; then
    message+=" from version $VERSION"
  fi
  
  bgd_send_notification "$message" "warning"
  
  return 0
}