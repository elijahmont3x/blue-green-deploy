# Blue/Green Deployment System Plugin Documentation

This document provides detailed information about the plugins available in the Blue/Green Deployment System.

## Table of Contents

- [Plugin System Overview](#plugin-system-overview)
- [Database Migrations Plugin](#database-migrations-plugin)
- [Service Discovery Plugin](#service-discovery-plugin)
- [SSL Automation Plugin](#ssl-automation-plugin)
- [Audit Logging Plugin](#audit-logging-plugin)
- [Notification Plugin](#notification-plugin)
- [Creating Custom Plugins](#creating-custom-plugins)

## Plugin System Overview

The Blue/Green Deployment System includes a plugin architecture that allows extending the core functionality through hooks at various points in the deployment process.

### Available Hooks

Plugins can implement any of the following hooks:

- `bgd_hook_pre_deploy`: Runs before deployment starts
- `bgd_hook_post_deploy`: Runs after deployment completes
- `bgd_hook_pre_cutover`: Runs before traffic cutover
- `bgd_hook_post_cutover`: Runs after traffic cutover
- `bgd_hook_pre_rollback`: Runs before rollback
- `bgd_hook_post_rollback`: Runs after rollback
- `bgd_hook_post_health`: Runs after health checks pass
- `bgd_hook_error`: Runs when an error occurs
- `bgd_hook_post_traffic_shift`: Runs after traffic is shifted
- `bgd_hook_cleanup`: Runs during cleanup operations

### Plugin Argument Registration

Plugins can register custom arguments using the registration function:

```bash
bgd_register_plugin_argument "plugin-name" "ARG_NAME" "default-value"
```

These arguments can then be passed to the deployment script:

```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --arg-name=custom-value
```

## Database Migrations Plugin

The database migrations plugin (`plugins/bgd-db-migrations.sh`) provides advanced database migration capabilities for zero-downtime deployments.

### Features

- Schema and full database backups
- Shadow database approach for zero-downtime migrations
- Automatic rollback capabilities
- Support for PostgreSQL and MySQL databases

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--db-shadow-enabled` | Enable shadow database approach | `true` |
| `--db-shadow-suffix` | Suffix for shadow database name | `_shadow` |
| `--db-backup-dir` | Directory for database backups | `./backups` |
| `--migrations-cmd` | Command to run migrations | `npm run migrate` |
| `--skip-migrations` | Skip database migrations | `false` |
| `--db-type` | Database type (postgres, mysql) | `postgres` |

### How the Shadow Database Works

1. Creates a copy of the production database as a "shadow" database
2. Applies migrations to the shadow database
3. Validates that migrations succeeded
4. Swaps the shadow database with the production database
5. Application continues running with the updated schema

This approach ensures that:
- Migrations are fully tested before affecting production
- Rollback is simple if migrations fail
- No downtime occurs during schema changes

### Example Usage

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --database-url="postgresql://user:pass@host/db" \
  --db-shadow-enabled=true \
  --db-shadow-suffix="_shadow" \
  --migrations-cmd="npx prisma migrate deploy"
```

## Service Discovery Plugin

The service discovery plugin (`plugins/bgd-service-discovery.sh`) enables automatic service registration and discovery.

### Features

- Registers services with internal registry
- Updates environment variables for service URLs
- Supports multi-service architectures

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--service-registry-enabled` | Enable service discovery | `true` |
| `--service-auto-generate-urls` | Auto-generate service URLs | `true` |
| `--service-registry-file` | Path to service registry file | `service-registry.json` |

### How Service Discovery Works

1. When a service is deployed, it's registered in a local registry file
2. Service URLs are generated and added to environment variables
3. Other services can discover and communicate with the service using these URLs

### Example Usage

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --service-registry-enabled=true \
  --service-auto-generate-urls=true
```

### Service Registry Format

The service registry is stored in JSON format:

```json
{
  "services": {
    "myapp": {
      "version": "v1.0.0",
      "url": "http://example.com",
      "environment": "blue",
      "registered_at": "2023-03-26T12:34:56Z"
    }
  }
}
```

## SSL Automation Plugin

The SSL automation plugin (`plugins/bgd-ssl.sh`) handles SSL certificate management with Let's Encrypt.

### Features

- Automatic certificate generation with Let's Encrypt
- Nginx SSL configuration
- Certificate renewal management

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--ssl-enabled` | Enable SSL automation | `true` |
| `--certbot-email` | Email for Let's Encrypt | `` |
| `--certbot-staging` | Use Let's Encrypt staging environment | `false` |
| `--ssl-domains` | Additional domains for certificate | `` |
| `--ssl-auto-renewal` | Set up automatic renewal | `true` |
| `--ssl-cert-path` | Path to store certificates | `./certs` |
| `--ssl-auto-install-deps` | Auto-install dependencies | `true` |

### How SSL Automation Works

1. Checks if certificates exist, obtains new ones if needed
2. Uses the standalone method for certificate issuance (temporarily stops Nginx)
3. Configures Nginx with the certificates
4. Sets up automatic renewal with cron

### Example Usage

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --domain-name="example.com" \
  --certbot-email="admin@example.com" \
  --ssl-enabled=true
```

## Audit Logging Plugin

The audit logging plugin (`plugins/bgd-audit-logging.sh`) provides deployment event tracking and reporting.

### Features

- Records deployment events with timestamps
- Captures environment details
- Provides deployment history and reports

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--audit-log-level` | Minimum log level to record | `info` |
| `--audit-log-file` | Path to audit log file | `audit.log` |
| `--audit-retention-days` | Days to retain audit logs | `90` |

### How Audit Logging Works

1. Records events throughout the deployment process (start, health check, completion, etc.)
2. Stores events in a structured JSON format
3. Provides reporting capabilities
4. Automatically cleans up old logs

### Example Usage

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --audit-log-level="info" \
  --audit-retention-days=90
```

### Audit Log Format

The audit log is stored in JSON format, with one event per line:

```json
{"timestamp":"2023-03-26T12:34:56Z","app":"myapp","version":"v1.0.0","event":"deployment_started","severity":"info","details":{"app":"myapp","version":"v1.0.0"}}
{"timestamp":"2023-03-26T12:35:10Z","app":"myapp","version":"v1.0.0","event":"health_check_passed","severity":"info","details":{}}
{"timestamp":"2023-03-26T12:35:30Z","app":"myapp","version":"v1.0.0","event":"deployment_completed","severity":"info","details":{"app":"myapp","version":"v1.0.0","environment":"blue"}}
```

## Notification Plugin

The notification plugin (`plugins/bgd-notification.sh`) provides deployment event notifications.

### Features

- Telegram notifications
- Slack notifications
- Customizable notification levels and events

### Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `--notify-enabled` | Enable notifications | `false` |
| `--telegram-bot-token` | Telegram bot token | `` |
| `--telegram-chat-id` | Telegram chat ID | `` |
| `--slack-webhook` | Slack webhook URL | `` |
| `--notify-events` | Events to send notifications for | `deploy,cutover,rollback,error` |

### How Notifications Work

1. Hooks into various deployment events
2. Formats messages with appropriate emojis and context
3. Sends notifications to configured channels
4. Provides secure handling of credentials

### Example Usage

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --notify-enabled=true \
  --telegram-bot-token="your-token" \
  --telegram-chat-id="your-chat-id" \
  --notify-events="deploy,error"
```

## Creating Custom Plugins

You can create your own plugins to extend the functionality of the deployment system.

### Plugin File Structure

Create a shell script in the `plugins/` directory with the `bgd-` prefix:

```bash
#!/bin/bash
#
# bgd-custom-plugin.sh - Custom plugin for Blue/Green Deployment
#
# Description of your plugin...

# Register plugin arguments
bgd_register_custom_plugin_arguments() {
  bgd_register_plugin_argument "custom-plugin" "CUSTOM_OPTION" "default-value"
}

# Implement hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  # Your pre-deployment logic here
  bgd_log "Custom plugin pre-deployment hook" "info"
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Your post-deployment logic here
  bgd_log "Custom plugin post-deployment hook" "info"
  
  return 0
}

# Add more hooks as needed...
```

### Plugin Best Practices

1. Use the `bgd_` prefix for all functions to avoid conflicts
2. Register all arguments with default values
3. Return 0 for success and non-zero for failure from hooks
4. Use the logging functions (`bgd_log`) for consistent output
5. Handle errors gracefully
6. Document your plugin's purpose and parameters

### Example Custom Plugin: Performance Monitoring

```bash
#!/bin/bash
#
# bgd-performance-monitor.sh - Performance monitoring plugin for Blue/Green Deployment
#
# This plugin integrates with external monitoring services to track
# performance metrics during deployments.

# Register plugin arguments
bgd_register_performance_monitor_arguments() {
  bgd_register_plugin_argument "performance-monitor" "MONITOR_ENABLED" "false"
  bgd_register_plugin_argument "performance-monitor" "MONITOR_ENDPOINT" ""
  bgd_register_plugin_argument "performance-monitor" "MONITOR_API_KEY" ""
}

# Send performance metrics
bgd_send_metrics() {
  local event_type="$1"
  local env_name="$2"
  
  if [ "${MONITOR_ENABLED:-false}" != "true" ] || [ -z "${MONITOR_ENDPOINT:-}" ]; then
    return 0
  fi
  
  bgd_log "Sending performance metrics for $event_type" "info"
  
  # Create payload
  local payload="{\"event\":\"$event_type\",\"app\":\"$APP_NAME\",\"environment\":\"$env_name\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
  
  # Send metrics to monitoring service
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${MONITOR_API_KEY}" \
    -d "$payload" \
    "${MONITOR_ENDPOINT}/api/metrics" > /dev/null
  
  return $?
}

# Hooks implementation
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  bgd_send_metrics "deployment" "$env_name"
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  bgd_send_metrics "cutover" "$target_env"
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  bgd_send_metrics "rollback" "$rollback_env"
  return 0
}
```