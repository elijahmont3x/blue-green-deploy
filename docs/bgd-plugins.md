# Blue/Green Deployment Plugin System

The Blue/Green Deployment system includes a flexible plugin architecture that allows extending the core functionality with custom integrations and features.

## Built-in Plugins

The system comes with several built-in plugins:

| Plugin | Description |
|--------|-------------|
| `ssl` | Manages SSL certificates with Let's Encrypt integration |
| `notifications` | Provides deployment notifications via Slack, Teams, and email |
| `db-migrations` | Handles database migrations during deployments |
| `audit-logging` | Provides comprehensive audit logging of all operations |
| `master-proxy` | Manages a master proxy for multiple applications |
| `profile-manager` | Handles environment profiles for different deployment scenarios |
| `service-discovery` | Integrates with service discovery systems like Consul |

## Using Plugins

### List Available Plugins

```bash
./scripts/bgd-plugin-manager.sh list
```

### Show Plugin Details

```bash
./scripts/bgd-plugin-manager.sh show notifications
```

### Install a Plugin

```bash
./scripts/bgd-plugin-manager.sh install ssl
```

### Enable or Disable a Plugin

```bash
# Enable a plugin
./scripts/bgd-plugin-manager.sh enable notifications

# Disable a plugin
./scripts/bgd-plugin-manager.sh disable notifications
```

## Plugin Lifecycle

Plugins can hook into various parts of the deployment lifecycle:

1. **Pre-Deploy**: Actions before deployment (`bgd_hook_pre_deploy`)
2. **Post-Environment-Start**: Actions after environment is started but before cutover (`bgd_hook_post_env_start`)
3. **Pre-Cutover**: Actions before traffic cutover (`bgd_hook_pre_cutover`)
4. **Post-Cutover**: Actions after traffic cutover (`bgd_hook_post_cutover`)
5. **Post-Deploy**: Actions after deployment is complete (`bgd_hook_post_deploy`)
6. **Pre-Cleanup**: Actions before environment cleanup (`bgd_hook_pre_cleanup`)
7. **Post-Rollback**: Actions after rollback operation (`bgd_hook_post_rollback`)
8. **Cleanup**: Actions during cleanup operations (`bgd_hook_cleanup`)

## Creating Custom Plugins

Custom plugins are Bash scripts that follow a specific structure and naming convention:

1. Create a file named `bgd-myplugin.sh` (replace "myplugin" with your plugin name)
2. Place the file in the `plugins` directory
3. Make sure it includes proper metadata and hook functions

### Example Plugin Structure

```bash
#!/bin/bash
#
# bgd-myplugin.sh - My custom plugin for Blue/Green Deployment
#
# This plugin does something useful

# Plugin metadata
PLUGIN_VERSION="1.0.0"
PLUGIN_DESCRIPTION="My useful plugin that does something"
PLUGIN_AUTHOR="Your Name"
PLUGIN_DEPENDENCIES=""

# Register plugin arguments
bgd_register_myplugin_arguments() {
  bgd_register_plugin_argument "myplugin" "MYPLUGIN_ENABLED" "false"
  bgd_register_plugin_argument "myplugin" "MYPLUGIN_OPTION" "default_value"
}

# Plugin initialization
bgd_myplugin_init() {
  if [ "${MYPLUGIN_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  bgd_log "Initializing my plugin" "info"
  # Plugin initialization code
  return 0
}

# Example implementation of a deployment lifecycle hook
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${MYPLUGIN_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  bgd_log "Executing post-deploy actions for $env_name, version $version" "info"
  # Custom post-deployment logic
  return 0
}
```

### Plugin Configuration

Plugins should register their configuration options using the `bgd_register_plugin_argument` function:

```bash
bgd_register_plugin_argument "plugin_name" "VARIABLE_NAME" "default_value"
```

This ensures the plugin's options are properly documented and can be set via command line arguments.

### Plugin Installation

Custom plugins can be installed from a local file:

```bash
./scripts/bgd-plugin-manager.sh install-custom --file=/path/to/bgd-myplugin.sh
```

## Plugin Development Guidelines

1. **Follow naming conventions**: Plugin files should be named `bgd-pluginname.sh`
2. **Include metadata**: Add version, description, and author information
3. **Document arguments**: Register all configuration options with default values
4. **Implement lifecycle hooks**: Add necessary hook functions for your plugin's features
5. **Fail gracefully**: Always check if your plugin is enabled before performing actions
6. **Log appropriately**: Use `bgd_log` for proper logging of actions
7. **Return correct status codes**: Return 0 for success, non-zero for failures
8. **Avoid conflicts**: Don't override core functionality or other plugins

## Plugin Examples

### Notifications Plugin Example

```bash
#!/bin/bash
bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${NOTIFY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local message="Deployed version $version to $env_name environment"
  bgd_send_notification "$message" "success"
  
  return 0
}
```

### Database Migrations Plugin Example

```bash
#!/bin/bash
bgd_hook_post_env_start() {
  local env_name="$1"
  
  if [ "${DB_MIGRATIONS_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  bgd_run_migrations "${APP_NAME}" "$env_name"
  
  return $?
}
```