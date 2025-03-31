#!/bin/bash
#
# bgd-db-migrations.sh - Database migration plugin for Blue/Green Deployment
#
# This plugin adds database migration functionality to the deployment process

# Register plugin arguments
bgd_register_db_migrations_arguments() {
  bgd_register_plugin_argument "db-migrations" "DB_MIGRATIONS_ENABLED" "false"
  bgd_register_plugin_argument "db-migrations" "DB_MIGRATIONS_COMMAND" "npm run migrate"
  bgd_register_plugin_argument "db-migrations" "DB_BACKUP_ENABLED" "true"
  bgd_register_plugin_argument "db-migrations" "DB_ROLLBACK_COMMAND" "npm run migrate:rollback"
  bgd_register_plugin_argument "db-migrations" "DB_BACKUP_COMMAND" "npm run db:backup"
  bgd_register_plugin_argument "db-migrations" "DB_MIGRATION_TIMEOUT" "300"
}

# Run database migrations for an environment
bgd_run_migrations() {
  local env_name="$1"
  local app_name="${2:-$APP_NAME}"
  
  # Check if DB migrations are enabled
  if [ "${DB_MIGRATIONS_ENABLED:-false}" != "true" ]; then
    bgd_log "Database migrations are disabled" "info"
    return 0
  fi
  
  bgd_log "Running database migrations for $app_name ($env_name)" "info"
  
  # Backup database if enabled
  if [ "${DB_BACKUP_ENABLED:-true}" = "true" ]; then
    bgd_backup_database "$env_name" "$app_name"
  fi
  
  # Run migrations
  local container_name="${app_name}-${env_name}-app"
  local migration_command="${DB_MIGRATIONS_COMMAND:-npm run migrate}"
  local timeout="${DB_MIGRATION_TIMEOUT:-300}"
  
  bgd_log "Executing migration command in container $container_name: $migration_command" "info"
  
  # Run migrations in container with timeout
  if ! docker exec -t "$container_name" sh -c "timeout $timeout $migration_command"; then
    bgd_log "Migration failed for $app_name ($env_name)" "error"
    return 1
  fi
  
  bgd_log "Migration completed successfully for $app_name ($env_name)" "success"
  return 0
}

# Backup database before migrations
bgd_backup_database() {
  local env_name="$1"
  local app_name="${2:-$APP_NAME}"
  
  bgd_log "Backing up database for $app_name ($env_name)" "info"
  
  local container_name="${app_name}-${env_name}-app"
  local backup_command="${DB_BACKUP_COMMAND:-npm run db:backup}"
  
  # Create backup directory
  local backup_dir="${BGD_BASE_DIR}/backups/${app_name}"
  mkdir -p "$backup_dir" || {
    bgd_log "Failed to create backup directory: $backup_dir" "error"
    return 1
  }
  
  local backup_file="${backup_dir}/${app_name}-${env_name}-$(date +%Y%m%d%H%M%S).sql"
  
  # Run backup command in container
  if ! docker exec -t "$container_name" sh -c "$backup_command" > "$backup_file" 2>/dev/null; then
    bgd_log "Database backup failed for $app_name ($env_name)" "error"
    return 1
  fi
  
  bgd_log "Database backup completed successfully: $backup_file" "success"
  return 0
}

# Rollback database migrations
bgd_rollback_migrations() {
  local env_name="$1"
  local app_name="${2:-$APP_NAME}"
  
  # Check if DB migrations are enabled
  if [ "${DB_MIGRATIONS_ENABLED:-false}" != "true" ]; then
    bgd_log "Database migrations are disabled" "info"
    return 0
  fi
  
  bgd_log "Rolling back database migrations for $app_name ($env_name)" "info"
  
  local container_name="${app_name}-${env_name}-app"
  local rollback_command="${DB_ROLLBACK_COMMAND:-npm run migrate:rollback}"
  
  # Run rollback command in container
  if ! docker exec -t "$container_name" sh -c "$rollback_command"; then
    bgd_log "Migration rollback failed for $app_name ($env_name)" "error"
    return 1
  fi
  
  bgd_log "Migration rollback completed successfully for $app_name ($env_name)" "success"
  return 0
}

# Migration plugin hook for post environment start
bgd_hook_post_env_start() {
  local env_name="$1"
  
  # Check if DB migrations are enabled
  if [ "${DB_MIGRATIONS_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  # Run migrations
  bgd_run_migrations "$env_name" "${APP_NAME}" || {
    bgd_log "Migrations failed, deployment may be unstable" "warning"
    return 1
  }
  
  return 0
}

# Migration plugin hook for rollback
bgd_hook_post_rollback() {
  local target_env="$1"
  
  # Check if DB migrations are enabled and DB_ROLLBACK_ON_REVERT is true
  if [ "${DB_MIGRATIONS_ENABLED:-false}" != "true" ] || [ "${DB_ROLLBACK_ON_REVERT:-false}" != "true" ]; then
    return 0
  fi
  
  # Run migrations rollback
  bgd_rollback_migrations "$target_env" "${APP_NAME}" || {
    bgd_log "Migration rollback failed, rollback may be unstable" "warning"
    return 1
  }
  
  return 0
}