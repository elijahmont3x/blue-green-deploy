#!/bin/bash
#
# bgd-db-migrations.sh - Database migration management plugin for Blue/Green Deployment
#
# This plugin provides database migration capabilities with zero-downtime approach:
# - Schema and full database backups
# - Shadow database for zero-downtime migrations
# - Automatic rollback capabilities

# Register plugin arguments
bgd_register_db_migrations_arguments() {
  bgd_register_plugin_argument "db-migrations" "DB_SHADOW_ENABLED" "true"
  bgd_register_plugin_argument "db-migrations" "DB_SHADOW_SUFFIX" "_shadow"
  bgd_register_plugin_argument "db-migrations" "DB_BACKUP_DIR" "./backups"
  bgd_register_plugin_argument "db-migrations" "MIGRATIONS_CMD" "npm run migrate"
  bgd_register_plugin_argument "db-migrations" "SKIP_MIGRATIONS" "false"
  bgd_register_plugin_argument "db-migrations" "DB_TYPE" "postgres" # postgres, mysql
}

# Get database type and connection details
bgd_get_db_connection_details() {
  # Parse DATABASE_URL to extract components
  if [ -n "${DATABASE_URL:-}" ]; then
    # Extract DB type from URL
    DB_TYPE=$(echo "$DATABASE_URL" | cut -d: -f1)
    
    # Parse connection details
    if [[ "$DATABASE_URL" =~ ^([^:]+)://([^:]+):([^@]+)@([^:/]+):([^/]+)/(.+)$ ]]; then
      DB_USER="${BASH_REMATCH[2]}"
      DB_PASSWORD="${BASH_REMATCH[3]}"
      DB_HOST="${BASH_REMATCH[4]}"
      DB_PORT="${BASH_REMATCH[5]}"
      DB_NAME="${BASH_REMATCH[6]}"
    fi
  fi
  
  # Apply defaults if not set
  DB_TYPE="${DB_TYPE:-postgres}"
  DB_USER="${DB_USER:-postgres}"
  DB_PASSWORD="${DB_PASSWORD:-postgres}"
  DB_HOST="${DB_HOST:-localhost}"
  DB_PORT="${DB_PORT:-5432}"
  DB_NAME="${DB_NAME:-$APP_NAME}"
}

# Create database connection URL
bgd_create_db_url() {
  local db_type="$1"
  local db_user="$2"
  local db_password="$3"
  local db_host="$4"
  local db_port="$5"
  local db_name="$6"
  
  printf "%s://%s:%s@%s:%s/%s" "$db_type" "$db_user" "$db_password" "$db_host" "$db_port" "$db_name"
}

# Backup the database
bgd_backup_database() {
  local version="$1"
  local env_name="$2"
  
  bgd_get_db_connection_details
  local backup_dir="${DB_BACKUP_DIR:-./backups}"
  
  # Create backup directory if it doesn't exist
  bgd_ensure_directory "$backup_dir"
  
  # Generate backup filename with timestamp
  local timestamp=$(date +"%Y%m%d-%H%M%S")
  local backup_file="$backup_dir/${APP_NAME}_${version}_${env_name}_${timestamp}.sql"
  
  bgd_log "Backing up database for version $version ($env_name environment)" "info"
  
  case "$DB_TYPE" in
    postgres|postgresql)
      # Use pg_dump for PostgreSQL
      PGPASSWORD="$DB_PASSWORD" pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f "$backup_file" || {
        bgd_log "Failed to backup PostgreSQL database" "error"
        return 1
      }
      ;;
    mysql)
      # Use mysqldump for MySQL
      mysqldump -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" > "$backup_file" || {
        bgd_log "Failed to backup MySQL database" "error"
        return 1
      }
      ;;
    *)
      bgd_log "Unsupported database type: $DB_TYPE" "error"
      return 1
      ;;
  esac
  
  bgd_log "Database backup completed: $backup_file" "success"
  return 0
}

# Create a shadow database for zero-downtime migrations
bgd_create_shadow_database() {
  local version="$1"
  
  bgd_get_db_connection_details
  local shadow_db_name="${DB_NAME}${DB_SHADOW_SUFFIX}"
  
  bgd_log "Creating shadow database for version $version" "info"
  
  case "$DB_TYPE" in
    postgres|postgresql)
      # Create PostgreSQL shadow database
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "DROP DATABASE IF EXISTS \"$shadow_db_name\";" || {
        bgd_log "Failed to drop existing shadow database" "warning"
      }
      
      # Create new shadow database as a clone of the current one
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "CREATE DATABASE \"$shadow_db_name\" WITH TEMPLATE \"$DB_NAME\";" || {
        bgd_log "Failed to create shadow database" "error"
        return 1
      }
      ;;
    mysql)
      # Create MySQL shadow database
      mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "DROP DATABASE IF EXISTS \`$shadow_db_name\`;" || {
        bgd_log "Failed to drop existing shadow database" "warning"
      }
      
      # Create new shadow database
      mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE DATABASE \`$shadow_db_name\`;" || {
        bgd_log "Failed to create shadow database" "error"
        return 1
      }
      
      # Copy data from original to shadow
      mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "SHOW TABLES FROM \`$DB_NAME\`;" | grep -v Tables_in | while read table; do
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -e "CREATE TABLE \`$shadow_db_name\`.\`$table\` LIKE \`$DB_NAME\`.\`$table\`; INSERT INTO \`$shadow_db_name\`.\`$table\` SELECT * FROM \`$DB_NAME\`.\`$table\`;"
      done
      ;;
    *)
      bgd_log "Unsupported database type: $DB_TYPE" "error"
      return 1
      ;;
  esac
  
  bgd_log "Shadow database created: $shadow_db_name" "success"
  
  # Create shadow database URL
  local shadow_db_url=$(bgd_create_db_url "$DB_TYPE" "$DB_USER" "$DB_PASSWORD" "$DB_HOST" "$DB_PORT" "$shadow_db_name")
  
  # Export shadow database URL for migrations
  export SHADOW_DATABASE_URL="$shadow_db_url"
  
  return 0
}

# Apply migrations to shadow database
bgd_apply_migrations_to_shadow() {
  local version="$1"
  local env_name="$2"
  
  bgd_get_db_connection_details
  local shadow_db_name="${DB_NAME}${DB_SHADOW_SUFFIX}"
  local shadow_db_url="${SHADOW_DATABASE_URL}"
  
  bgd_log "Applying migrations to shadow database" "info"
  
  # Get Docker Compose command
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Temporarily modify DATABASE_URL to point to shadow database
  local original_db_url="$DATABASE_URL"
  export DATABASE_URL="$shadow_db_url"
  
  # Run migrations on shadow database
  if $docker_compose -p "${APP_NAME}-${env_name}" exec -T -e DATABASE_URL="$shadow_db_url" app sh -c "${MIGRATIONS_CMD}"; then
    bgd_log "Migrations applied successfully to shadow database" "success"
    # Restore original DATABASE_URL
    export DATABASE_URL="$original_db_url"
    return 0
  else
    bgd_log "Failed to apply migrations to shadow database" "error"
    # Restore original DATABASE_URL
    export DATABASE_URL="$original_db_url"
    return 1
  fi
}

# Swap shadow database with main database
bgd_swap_databases() {
  bgd_get_db_connection_details
  local shadow_db_name="${DB_NAME}${DB_SHADOW_SUFFIX}"
  local temp_db_name="${DB_NAME}_temp"
  
  bgd_log "Swapping shadow database with main database" "info"
  
  case "$DB_TYPE" in
    postgres|postgresql)
      # Use PostgreSQL database renaming
      # First rename current to temp
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$temp_db_name\";" || {
        bgd_log "Failed to rename current database to temp" "error"
        return 1
      }
      
      # Rename shadow to current
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "ALTER DATABASE \"$shadow_db_name\" RENAME TO \"$DB_NAME\";" || {
        # Try to restore original name if shadow rename fails
        PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "ALTER DATABASE \"$temp_db_name\" RENAME TO \"$DB_NAME\";"
        bgd_log "Failed to rename shadow database to current" "error"
        return 1
      }
      
      # Rename temp to shadow for future use
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -c "ALTER DATABASE \"$temp_db_name\" RENAME TO \"$shadow_db_name\";" || {
        bgd_log "Failed to rename temp database to shadow" "warning"
        # Not critical, just a warning
      }
      ;;
    mysql)
      bgd_log "Database swapping is not supported for MySQL yet" "error"
      return 1
      ;;
    *)
      bgd_log "Unsupported database type: $DB_TYPE" "error"
      return 1
      ;;
  esac
  
  bgd_log "Database swap completed successfully" "success"
  return 0
}

# Database Migration Hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  # Skip if migrations are disabled
  if [ "${SKIP_MIGRATIONS:-false}" = "true" ]; then
    bgd_log "Database migrations are disabled, skipping pre-deployment database tasks" "info"
    return 0
  fi
  
  # Skip if no DATABASE_URL is provided
  if [ -z "${DATABASE_URL:-}" ]; then
    bgd_log "No DATABASE_URL provided, skipping database operations" "info"
    return 0
  fi
  
  # Backup database before deployment
  bgd_backup_database "$version" "${TARGET_ENV:-unknown}" || {
    bgd_log "Database backup failed, but continuing with deployment" "warning"
    # Continue despite warning
  }
  
  # Create shadow database if enabled
  if [ "${DB_SHADOW_ENABLED:-true}" = "true" ]; then
    bgd_create_shadow_database "$version" || {
      bgd_log "Shadow database creation failed" "error"
      return 1
    }
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Skip if migrations are disabled
  if [ "${SKIP_MIGRATIONS:-false}" = "true" ]; then
    bgd_log "Database migrations are disabled, skipping post-deployment database tasks" "info"
    return 0
  fi
  
  # Skip if no DATABASE_URL is provided
  if [ -z "${DATABASE_URL:-}" ]; then
    bgd_log "No DATABASE_URL provided, skipping database operations" "info"
    return 0
  fi
  
  # Apply migrations to shadow database if enabled
  if [ "${DB_SHADOW_ENABLED:-true}" = "true" ]; then
    if bgd_apply_migrations_to_shadow "$version" "$env_name"; then
      # Swap databases after successful migration
      bgd_swap_databases || {
        bgd_log "Database swap failed, application will use original database" "error"
        return 1
      }
    else
      bgd_log "Shadow database migrations failed" "error"
      return 1
    fi
  fi
  
  return 0
}

bgd_hook_pre_rollback() {
  # Prepare for database rollback if needed
  if [ -z "${DATABASE_URL:-}" ]; then
    return 0
  fi
  
  bgd_log "Preparing for database rollback" "info"
  
  # Backup current database state before rollback
  bgd_backup_database "rollback" "before" || {
    bgd_log "Failed to backup database before rollback" "warning"
    # Continue despite warning
  }
  
  return 0
}

bgd_hook_post_rollback() {
  local rollback_env="$1"
  
  # If we don't have a database URL, nothing to do
  if [ -z "${DATABASE_URL:-}" ]; then
    return 0
  fi
  
  bgd_log "Database rollback not required for simple environment switch" "info"
  
  return 0
}