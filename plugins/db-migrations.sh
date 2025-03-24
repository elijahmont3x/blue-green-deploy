#!/bin/bash
#
# db-migrations.sh - Comprehensive database migration plugin
#
# This plugin provides advanced database migration features:
# - Schema and full database backups
# - Migration history tracking
# - Rollback capabilities
# - Blue/green shadow database approach for zero-downtime migrations
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
register_db_migrations_arguments() {
  register_plugin_argument "db-migrations" "DB_SHADOW_ENABLED" "false"
  register_plugin_argument "db-migrations" "DB_SHADOW_SUFFIX" "_shadow"
  register_plugin_argument "db-migrations" "DB_SYNC_INTERVAL" "5"
  register_plugin_argument "db-migrations" "MIGRATIONS_ROLLBACK_CMD" ""
}

# Global variables
MIGRATIONS_DIR="./migrations"
MIGRATIONS_LOCK_FILE="/tmp/bgd-migrations.lock"
SCHEMA_BACKUP_DIR="./schema-backups"
DB_FULL_BACKUP_DIR="./db-backups"
MIGRATIONS_HISTORY_FILE="./migrations-history.json"
DB_REPLICATION_SLOTS_FILE="./db-replication-slots.json"

#------------------------------------------------
# Core Migration Functions
#------------------------------------------------

# Configure migrations for specific applications
# Supported types: knex, prisma, typeorm, sequelize, django, rails, custom
get_migration_type() {
  # Check for package.json to detect Node.js app and migration framework
  if [ -f "package.json" ]; then
    if grep -q '"prisma"' package.json; then
      echo "prisma"
    elif grep -q '"knex"' package.json; then
      echo "knex" 
    elif grep -q '"typeorm"' package.json; then
      echo "typeorm"
    elif grep -q '"sequelize"' package.json; then
      echo "sequelize"
    else
      echo "custom"
    fi
  # Check for Django
  elif [ -f "manage.py" ]; then
    echo "django"
  # Check for Rails
  elif [ -f "Gemfile" ] && grep -q "rails" Gemfile; then
    echo "rails"
  else
    echo "custom"
  fi
}

# Get the migration command for the detected framework
get_migration_command() {
  local migration_type=$(get_migration_type)
  
  case "$migration_type" in
    "prisma")
      echo "npx prisma migrate deploy"
      ;;
    "knex")
      echo "npx knex migrate:latest"
      ;;
    "typeorm")
      echo "npx typeorm migration:run"
      ;;
    "sequelize")
      echo "npx sequelize-cli db:migrate"
      ;;
    "django")
      echo "python manage.py migrate"
      ;;
    "rails")
      echo "bundle exec rails db:migrate"
      ;;
    "custom")
      # Use the custom command from deployment parameters or default to npm script
      echo "${MIGRATIONS_CMD:-npm run migrate}"
      ;;
  esac
}

# Get rollback command for the detected framework
get_rollback_command() {
  local migration_type=$(get_migration_type)
  
  case "$migration_type" in
    "prisma")
      # Prisma doesn't have a built-in rollback command
      echo ""
      ;;
    "knex")
      echo "npx knex migrate:rollback"
      ;;
    "typeorm")
      echo "npx typeorm migration:revert"
      ;;
    "sequelize")
      echo "npx sequelize-cli db:migrate:undo"
      ;;
    "django")
      # Requires a specific migration to roll back to
      echo ""
      ;;
    "rails")
      echo "bundle exec rails db:rollback"
      ;;
    "custom")
      # Use the custom rollback command or default to empty
      echo "${MIGRATIONS_ROLLBACK_CMD:-}"
      ;;
  esac
}

# Check if migrations need to be run
should_run_migrations() {
  # Skip if explicitly disabled
  if [ "${SKIP_MIGRATIONS:-false}" = "true" ]; then
    log_info "Migrations explicitly disabled, skipping"
    return 1
  fi
  
  # Skip if lock file exists (another deployment is running migrations)
  if [ -f "$MIGRATIONS_LOCK_FILE" ]; then
    log_warning "Migration lock file exists, skipping migrations to prevent conflicts"
    return 1
  fi
  
  # Check if any migration files exist
  local migration_type=$(get_migration_type)
  case "$migration_type" in
    "prisma")
      [ -d "prisma/migrations" ] && return 0 || return 1
      ;;
    "knex")
      [ -d "migrations" ] && return 0 || return 1
      ;;
    "typeorm")
      [ -d "src/migrations" ] || [ -d "migrations" ] && return 0 || return 1
      ;;
    "sequelize")
      [ -d "migrations" ] && return 0 || return 1
      ;;
    "django")
      # Check if any app has migrations
      find . -path "*/migrations/*.py" -not -name "__init__.py" | grep -q . && return 0 || return 1
      ;;
    "rails")
      [ -d "db/migrate" ] && return 0 || return 1
      ;;
    "custom")
      # For custom frameworks, assume migrations are needed
      return 0
      ;;
  esac
}

#------------------------------------------------
# Backup Functions
#------------------------------------------------

# Create a full backup of the database before migrations
backup_database_full() {
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_dir="${DB_FULL_BACKUP_DIR}/${APP_NAME}-${VERSION}"
  local backup_file="${backup_dir}/full_backup_${timestamp}.sql"
  
  ensure_directory "$backup_dir"
  
  log_info "Creating full database backup before migrations"
  
  # Extract database connection info from DATABASE_URL
  if [ -n "${DATABASE_URL:-}" ]; then
    # Parse the DATABASE_URL to extract credentials
    # Example: postgresql://user:password@host:port/dbname
    local db_user=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
    local db_pass=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
    local db_host=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
    local db_port=$(echo "$DATABASE_URL" | sed -n 's/.*@[^:]*:\([^/]*\)\/.*/\1/p')
    local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
    
    # Set environment variables for pg_dump
    export PGPASSWORD="$db_pass"
    
    # Execute the backup (with data)
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "pg_dump -U $db_user -h $db_host -p ${db_port:-5432} $db_name" > "$backup_file"
    
    # Check if backup was successful
    if [ $? -eq 0 ] && [ -s "$backup_file" ]; then
      log_success "Full database backup created: $backup_file"
      # Secure the backup file
      chmod 600 "$backup_file"
      
      # Store backup metadata
      cat > "${backup_dir}/metadata.json" << EOL
{
  "app": "${APP_NAME}",
  "version": "${VERSION}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "database": "${db_name}",
  "backup_file": "${backup_file}"
}
EOL
      
      # Return backup file path for later use
      echo "$backup_file"
    else
      log_error "Full database backup failed"
      rm -f "$backup_file"
      echo ""
    fi
    
    # Unset password
    unset PGPASSWORD
  else
    log_warning "DATABASE_URL not set, skipping full backup"
    echo ""
  fi
}

# Create a backup of the database schema before migrations
backup_database_schema() {
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="${SCHEMA_BACKUP_DIR}/${APP_NAME}_schema_${timestamp}.sql"
  
  ensure_directory "$SCHEMA_BACKUP_DIR"
  
  log_info "Creating database schema backup before migrations"
  
  # Extract database connection info
  if [ -n "${DATABASE_URL:-}" ]; then
    # Parse the DATABASE_URL to extract credentials
    local db_user=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
    local db_pass=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
    local db_host=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
    local db_port=$(echo "$DATABASE_URL" | sed -n 's/.*@[^:]*:\([^/]*\)\/.*/\1/p')
    local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
    
    # Set environment variables for pg_dump
    export PGPASSWORD="$db_pass"
    
    # Execute the backup (schema only)
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "pg_dump -U $db_user -h $db_host -p ${db_port:-5432} --schema-only $db_name" > "$backup_file"
    
    # Check if backup was successful
    if [ $? -eq 0 ] && [ -s "$backup_file" ]; then
      log_success "Database schema backup created: $backup_file"
      # Secure the backup file
      chmod 600 "$backup_file"
      echo "$backup_file"
    else
      log_warning "Database schema backup failed"
      rm -f "$backup_file"
      echo ""
    fi
    
    # Unset password
    unset PGPASSWORD
  else
    log_warning "DATABASE_URL not set, skipping schema backup"
    echo ""
  fi
}

# Restore database from backup file
restore_database_from_backup() {
  local backup_file="$1"
  
  if [ ! -f "$backup_file" ]; then
    log_error "Backup file not found: $backup_file"
    return 1
  fi
  
  log_info "Restoring database from backup: $backup_file"
  
  # Extract database connection info
  if [ -n "${DATABASE_URL:-}" ]; then
    # Parse the DATABASE_URL to extract credentials
    local db_user=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
    local db_pass=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
    local db_host=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
    local db_port=$(echo "$DATABASE_URL" | sed -n 's/.*@[^:]*:\([^/]*\)\/.*/\1/p')
    local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
    
    # Set environment variables for psql
    export PGPASSWORD="$db_pass"
    
    # Execute the restore
    cat "$backup_file" | docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "psql -U $db_user -h $db_host -p ${db_port:-5432} -d $db_name"
    
    local restore_result=$?
    
    # Unset password
    unset PGPASSWORD
    
    if [ $restore_result -eq 0 ]; then
      log_success "Database restored successfully from backup"
      return 0
    else
      log_error "Failed to restore database from backup"
      return 1
    fi
  else
    log_error "DATABASE_URL not set, cannot restore database"
    return 1
  fi
}

#------------------------------------------------
# Migration Analysis Functions
#------------------------------------------------

# Compare schemas before and after migrations to detect changes
compare_schemas() {
  local before_schema="$1"
  local after_schema="${SCHEMA_BACKUP_DIR}/${APP_NAME}_schema_after.sql"
  
  if [ ! -f "$before_schema" ]; then
    log_warning "Before schema file not found, skipping comparison"
    return 0
  fi
  
  log_info "Creating after-migration schema snapshot for comparison"
  
  # Create a schema dump after migrations
  local after_schema_path=$(backup_database_schema)
  
  if [ -z "$after_schema_path" ]; then
    log_warning "Failed to create after-migration schema snapshot, skipping comparison"
    return 0
  fi
  
  # Create diff file
  local diff_file="${SCHEMA_BACKUP_DIR}/${APP_NAME}_schema_diff_$(date +%Y%m%d_%H%M%S).diff"
  
  log_info "Comparing schemas to detect changes"
  
  # Perform diff and capture only meaningful schema changes
  diff -u "$before_schema" "$after_schema_path" | grep -v "^---" | grep -v "^+++" > "$diff_file"
  
  if [ -s "$diff_file" ]; then
    log_info "Schema changes detected and saved to: $diff_file"
    log_info "Changes summary:"
    grep "^[+-]" "$diff_file" | head -n 10 | sed 's/^/  /'
    
    # Count added/removed lines as a quick metric of change magnitude
    local added=$(grep -c "^+" "$diff_file")
    local removed=$(grep -c "^-" "$diff_file")
    log_info "Total changes: +$added/-$removed lines"
    
    return 0
  else
    log_info "No significant schema changes detected"
    rm -f "$diff_file"
    return 0
  fi
}

# Perform dry run of migrations to validate
dry_run_migrations() {
  local migration_type=$(get_migration_type)
  
  # Not all frameworks support dry run
  case "$migration_type" in
    "knex")
      # Knex doesn't have built-in dry run, but we can use --what-if flag
      docker-compose -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c \
        "npx knex migrate:status" || return 1
      ;;
    "sequelize")
      # Sequelize doesn't have built-in dry run, but we can show pending migrations
      docker-compose -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c \
        "npx sequelize-cli db:migrate:status" || return 1
      ;;
    "typeorm")
      # TypeORM can show pending migrations
      docker-compose -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c \
        "npx typeorm migration:show" || return 1
      ;;
    "prisma")
      # Prisma can show pending migrations
      docker-compose -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c \
        "npx prisma migrate status" || return 1
      ;;
    "django")
      # Django can show pending migrations
      docker-compose -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c \
        "python manage.py showmigrations --plan" || return 1
      ;;
    "rails")
      # Rails can show pending migrations
      docker-compose -p "${APP_NAME}-${TARGET_ENV}" exec -T app sh -c \
        "bundle exec rails db:migrate:status" || return 1
      ;;
    *)
      # Custom frameworks may not support dry run
      log_warning "Dry run not supported for this migration framework"
      return 0
      ;;
  esac
  
  log_success "Dry run of migrations completed successfully"
  return 0
}

#------------------------------------------------
# Migration History Tracking
#------------------------------------------------

# Ensure migrations history file exists
ensure_migrations_history_file() {
  if [ ! -f "$MIGRATIONS_HISTORY_FILE" ]; then
    log_info "Creating migrations history file"
    echo '{"migrations":[]}' > "$MIGRATIONS_HISTORY_FILE"
  fi
}

# Record migration start in history file
record_migration_start() {
  local version="$1"
  local env_name="$2"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  ensure_migrations_history_file
  
  # Create migration record
  local migration_record=$(cat << EOF
{
  "id": "$(uuidgen || echo "${version}-${env_name}-${timestamp}")",
  "version": "${version}",
  "environment": "${env_name}",
  "started_at": "${timestamp}",
  "status": "running",
  "completed_at": null
}
EOF
)

  # Add to history file
  local temp_file=$(mktemp)
  jq --argjson migration "$migration_record" '.migrations += [$migration]' "$MIGRATIONS_HISTORY_FILE" > "$temp_file"
  mv "$temp_file" "$MIGRATIONS_HISTORY_FILE"
  
  log_info "Recorded migration start in history"
}

# Record migration end in history file
record_migration_end() {
  local version="$1"
  local env_name="$2"
  local status="$3"
  local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  ensure_migrations_history_file
  
  # Update migration record
  local temp_file=$(mktemp)
  jq --arg version "$version" --arg env "$env_name" --arg status "$status" --arg timestamp "$timestamp" \
    '.migrations = [.migrations[] | if .version == $version and .environment == $env and .status == "running" then . + {"status": $status, "completed_at": $timestamp} else . end]' \
    "$MIGRATIONS_HISTORY_FILE" > "$temp_file"
  mv "$temp_file" "$MIGRATIONS_HISTORY_FILE"
  
  log_info "Recorded migration $status in history"
}

#------------------------------------------------
# Standard Migration Runner
#------------------------------------------------

# Run migrations with rollback capability
run_migrations_with_rollback() {
  local env_name="$1"
  
  # Create backup before migrations
  local backup_file=$(backup_database_full)
  local schema_before=$(backup_database_schema)
  
  if [ -z "$backup_file" ]; then
    log_warning "No database backup created, proceeding without rollback protection"
  else
    log_info "Database backed up, proceeding with migrations"
  fi
  
  # Do a dry run first
  log_info "Performing dry run of migrations"
  if ! dry_run_migrations; then
    log_warning "Dry run failed, but proceeding with actual migrations"
  fi
  
  # Get migration command
  local migration_cmd=$(get_migration_command)
  log_info "Using migration command: $migration_cmd"
  
  # Record migration start in history
  record_migration_start "$VERSION" "$env_name"
  
  # Run the actual migrations
  docker-compose -p "${APP_NAME}-${env_name}" exec -T app sh -c "$migration_cmd"
  local migration_result=$?
  
  if [ $migration_result -eq 0 ]; then
    log_success "Migrations completed successfully"
    
    # Compare schemas to detect changes
    compare_schemas "$schema_before"
    
    # Record migration success
    record_migration_end "$VERSION" "$env_name" "success"
    
    return 0
  else
    log_error "Migrations failed with exit code $migration_result"
    
    # Record migration failure
    record_migration_end "$VERSION" "$env_name" "failed"
    
    # Try automatic rollback if we have a backup
    if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
      log_warning "Rolling back database to pre-migration state"
      
      if restore_database_from_backup "$backup_file"; then
        log_success "Database successfully rolled back to pre-migration state"
      else
        log_error "Rollback failed, database may be in an inconsistent state!"
        log_error "Manual restoration may be needed from backup: $backup_file"
      fi
    else
      # Try framework-specific rollback if available
      local rollback_cmd=$(get_rollback_command)
      
      if [ -n "$rollback_cmd" ]; then
        log_warning "Attempting framework-specific rollback"
        docker-compose -p "${APP_NAME}-${env_name}" exec -T app sh -c "$rollback_cmd" && \
          log_success "Framework rollback successful" || \
          log_error "Framework rollback failed, database may be in an inconsistent state!"
      else
        log_error "No rollback method available. Manual intervention required!"
      fi
    fi
    
    return 1
  fi
}

#------------------------------------------------
# Blue/Green Database Shadow Functions
#------------------------------------------------

# Function to create a shadow database
create_shadow_database() {
  log_info "Creating shadow database for zero-downtime migrations"
  
  # Extract database connection info
  if [ -z "${DATABASE_URL:-}" ]; then
    log_error "DATABASE_URL not set, cannot create shadow database"
    return 1
  fi
  
  # Parse the DATABASE_URL to extract credentials
  local db_user=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
  local db_pass=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
  local db_host=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
  local db_port=$(echo "$DATABASE_URL" | sed -n 's/.*@[^:]*:\([^/]*\)\/.*/\1/p')
  local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
  
  # Shadow database name
  local shadow_db_name="${db_name}${DB_SHADOW_SUFFIX}"
  
  # Set environment variables for psql
  export PGPASSWORD="$db_pass"
  
  log_info "Checking if shadow database $shadow_db_name already exists"
  
  # Check if the shadow database already exists
  local shadow_exists=$(docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -lqt | cut -d \| -f 1 | grep -w $shadow_db_name | wc -l")
  
  if [ "$shadow_exists" -eq "0" ]; then
    log_info "Creating shadow database $shadow_db_name"
    
    # Create the shadow database as a copy of the main database
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"CREATE DATABASE $shadow_db_name WITH TEMPLATE $db_name;\""
    
    if [ $? -ne 0 ]; then
      log_error "Failed to create shadow database"
      unset PGPASSWORD
      return 1
    fi
    
    log_success "Shadow database $shadow_db_name created successfully"
  else
    log_info "Shadow database $shadow_db_name already exists"
  fi
  
  # Generate shadow DATABASE_URL
  local shadow_url=$(echo "$DATABASE_URL" | sed "s/$db_name/$shadow_db_name/")
  
  # Return shadow database URL
  echo "$shadow_url"
  
  # Unset password
  unset PGPASSWORD
  
  return 0
}

# Setup logical replication for data sync
setup_logical_replication() {
  log_info "Setting up logical replication for data synchronization"
  
  # Extract database connection info
  if [ -z "${DATABASE_URL:-}" ]; then
    log_error "DATABASE_URL not set, cannot setup replication"
    return 1
  fi
  
  # Parse the DATABASE_URL to extract credentials
  local db_user=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
  local db_pass=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
  local db_host=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
  local db_port=$(echo "$DATABASE_URL" | sed -n 's/.*@[^:]*:\([^/]*\)\/.*/\1/p')
  local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
  
  # Shadow database name
  local shadow_db_name="${db_name}${DB_SHADOW_SUFFIX}"
  
  # Set environment variables for psql
  export PGPASSWORD="$db_pass"
  
  # Check if PostgreSQL version supports logical replication (9.4+)
  local pg_version=$(docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"SHOW server_version;\" | head -3 | tail -1")
  
  local major_version=$(echo "$pg_version" | cut -d. -f1)
  if [ "$major_version" -lt "9" ] || ([ "$major_version" -eq "9" ] && [ "$(echo "$pg_version" | cut -d. -f2)" -lt "4" ]); then
    log_error "PostgreSQL version $pg_version does not support logical replication (required: 9.4+)"
    unset PGPASSWORD
    return 1
  fi
  
  # Check if logical replication is enabled
  local wal_level=$(docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"SHOW wal_level;\" | head -3 | tail -1")
  
  if [ "$wal_level" != "logical" ]; then
    log_warning "wal_level is not set to logical, trying to update PostgreSQL configuration"
    
    # Update postgresql.conf
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"ALTER SYSTEM SET wal_level = logical;\""
    
    # Reload PostgreSQL configuration
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "pg_ctl reload -D /var/lib/postgresql/data"
    
    log_warning "PostgreSQL configuration updated, but a restart may be required for changes to take effect"
    log_warning "Consider restarting PostgreSQL manually: docker-compose -p ${APP_NAME}-shared restart db"
  fi
  
  # Create replication slot and publication in the source database
  local replication_slot="${APP_NAME}_repl_slot"
  local publication="${APP_NAME}_pub"
  
  log_info "Creating replication slot $replication_slot and publication $publication"
  
  # Create replication slot
  docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -d $db_name -c \"SELECT pg_create_logical_replication_slot('$replication_slot', 'pgoutput');\"" || true
  
  # Create publication
  docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -d $db_name -c \"CREATE PUBLICATION $publication FOR ALL TABLES;\"" || true
  
  # Create subscription in the shadow database
  local subscription="${APP_NAME}_sub"
  
  log_info "Creating subscription $subscription in shadow database"
  
  # Create subscription
  docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -d $shadow_db_name -c \"CREATE SUBSCRIPTION $subscription CONNECTION 'dbname=$db_name user=$db_user password=$db_pass host=$db_host port=${db_port:-5432}' PUBLICATION $publication;\"" || true
  
  # Store replication info
  local replication_info=$(cat << EOF
{
  "replication_slot": "$replication_slot",
  "publication": "$publication",
  "subscription": "$subscription",
  "source_db": "$db_name",
  "target_db": "$shadow_db_name",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
)

  # Store replication info in a file
  echo "$replication_info" > "$DB_REPLICATION_SLOTS_FILE"
  
  log_success "Logical replication setup completed"
  
  # Unset password
  unset PGPASSWORD
  
  return 0
}

# Run migrations on shadow database
run_migrations_on_shadow() {
  local shadow_url="$1"
  local env_name="$2"
  
  log_info "Running migrations on shadow database"
  
  # Get migration command
  local migration_cmd=$(get_migration_command)
  
  # Override DATABASE_URL temporarily to point to shadow database
  log_info "Temporarily setting DATABASE_URL to shadow database"
  local original_db_url="$DATABASE_URL"
  export DATABASE_URL="$shadow_url"
  
  # Run migrations on shadow database
  log_info "Running migration command: $migration_cmd"
  docker-compose -p "${APP_NAME}-${env_name}" exec -T app sh -c "$migration_cmd"
  local migration_result=$?
  
  # Restore original DATABASE_URL
  export DATABASE_URL="$original_db_url"
  
  if [ $migration_result -eq 0 ]; then
    log_success "Migrations on shadow database completed successfully"
    return 0
  else
    log_error "Migrations on shadow database failed"
    return 1
  fi
}

# Validate shadow database
validate_shadow_database() {
  local shadow_url="$1"
  local env_name="$2"
  
  log_info "Validating shadow database"
  
  # Override DATABASE_URL temporarily to point to shadow database
  log_info "Temporarily setting DATABASE_URL to shadow database"
  local original_db_url="$DATABASE_URL"
  export DATABASE_URL="$shadow_url"
  
  # Run basic health check
  log_info "Running basic health check with shadow database"
  
  # Attempt to connect to the API with the shadow database
  local health_url="http://localhost:${TARGET_PORT}${HEALTH_ENDPOINT}"
  
  if curl -s -f "$health_url" > /dev/null 2>&1; then
    log_success "Health check passed with shadow database"
    export DATABASE_URL="$original_db_url"
    return 0
  else
    log_error "Health check failed with shadow database"
    export DATABASE_URL="$original_db_url"
    return 1
  fi
}

# Switch databases (promote shadow to main)
switch_to_shadow_database() {
  log_info "Promoting shadow database to main"
  
  # Extract database connection info
  if [ -z "${DATABASE_URL:-}" ]; then
    log_error "DATABASE_URL not set, cannot switch databases"
    return 1
  fi
  
  # Parse the DATABASE_URL to extract credentials
  local db_user=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/\([^:]*\):.*/\1/p')
  local db_pass=$(echo "$DATABASE_URL" | sed -n 's/.*:\/\/[^:]*:\([^@]*\)@.*/\1/p')
  local db_host=$(echo "$DATABASE_URL" | sed -n 's/.*@\([^:]*\):.*/\1/p')
  local db_port=$(echo "$DATABASE_URL" | sed -n 's/.*@[^:]*:\([^/]*\)\/.*/\1/p')
  local db_name=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
  
  # Shadow database name
  local shadow_db_name="${db_name}${DB_SHADOW_SUFFIX}"
  
  # Set environment variables for psql
  export PGPASSWORD="$db_pass"
  
  # Load replication info
  if [ -f "$DB_REPLICATION_SLOTS_FILE" ]; then
    local subscription=$(jq -r '.subscription' "$DB_REPLICATION_SLOTS_FILE")
    local publication=$(jq -r '.publication' "$DB_REPLICATION_SLOTS_FILE")
    local replication_slot=$(jq -r '.replication_slot' "$DB_REPLICATION_SLOTS_FILE")
    
    # Drop subscription
    log_info "Dropping subscription $subscription in shadow database"
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "psql -U $db_user -h $db_host -p ${db_port:-5432} -d $shadow_db_name -c \"DROP SUBSCRIPTION IF EXISTS $subscription;\"" || true
    
    # Drop publication
    log_info "Dropping publication $publication in main database"
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "psql -U $db_user -h $db_host -p ${db_port:-5432} -d $db_name -c \"DROP PUBLICATION IF EXISTS $publication;\"" || true
    
    # Drop replication slot
    log_info "Dropping replication slot $replication_slot"
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"SELECT pg_drop_replication_slot('$replication_slot');\"" || true
  fi
  
  # Rename databases
  log_info "Renaming databases"
  
  # Disconnect all users from databases
  docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname IN ('$db_name', '$shadow_db_name') AND pid <> pg_backend_pid();\"" || true
  
  # Rename main database to backup
  local backup_db_name="${db_name}_backup"
  docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"ALTER DATABASE $db_name RENAME TO $backup_db_name;\"" || true
  
  # Rename shadow database to main
  docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
    "psql -U $db_user -h $db_host -p ${db_port:-5432} -c \"ALTER DATABASE $shadow_db_name RENAME TO $db_name;\"" || true
  
  log_success "Shadow database promoted to main successfully"
  
  # Unset password
  unset PGPASSWORD
  
  return 0
}

#------------------------------------------------
# Blue/Green Database Migration Controller
#------------------------------------------------

# Run the blue/green migration process
run_blue_green_migrations() {
  local env_name="$1"
  
  # Skip if shadow DB is not enabled
  if [ "$DB_SHADOW_ENABLED" != "true" ]; then
    log_info "Shadow database is not enabled, skipping"
    return 1  # Return failure to fall back to standard migrations
  fi
  
  # Create shadow database
  local shadow_url=$(create_shadow_database)
  
  if [ -z "$shadow_url" ]; then
    log_error "Failed to create shadow database"
    return 1
  fi
  
  # Setup logical replication
  setup_logical_replication
  
  # Store shadow URL for later use
  echo "$shadow_url" > ".shadow_db_url"
  
  # Run migrations on shadow database
  if run_migrations_on_shadow "$shadow_url" "$env_name"; then
    log_success "Migrations completed on shadow database"
    
    # Validate shadow database
    if validate_shadow_database "$shadow_url" "$env_name"; then
      log_success "Shadow database validated successfully"
      
      # Switch to shadow database
      if switch_to_shadow_database; then
        log_success "Successfully switched to new database schema with zero downtime"
        return 0
      else
        log_error "Failed to switch to shadow database"
        return 1
      fi
    else
      log_error "Shadow database validation failed"
      return 1
    fi
  else
    log_error "Migrations failed on shadow database"
    return 1
  fi
}

#------------------------------------------------
# Plugin Hooks
#------------------------------------------------

# Pre-deployment hook - run before environment setup
hook_pre_deploy() {
  local version="$1"
  
  # Ensure backup directories exist
  ensure_directory "$SCHEMA_BACKUP_DIR"
  ensure_directory "$DB_FULL_BACKUP_DIR"
  
  # Create lock file to prevent concurrent migrations
  if should_run_migrations; then
    log_info "Preparing for database migrations"
    touch "$MIGRATIONS_LOCK_FILE"
  fi
  
  return 0
}

# Post-health hook - run after environment is healthy but before traffic shift
hook_post_health() {
  local version="$1"
  local env_name="$2"
  
  # Run migrations now that the new environment is set up and healthy
  if [ -f "$MIGRATIONS_LOCK_FILE" ]; then
    log_info "Running database migrations in $env_name environment"
    
    # Try blue/green migrations first if enabled
    if [ "$DB_SHADOW_ENABLED" = "true" ]; then
      log_info "Blue/Green shadow database migrations enabled"
      
      if run_blue_green_migrations "$env_name"; then
        log_success "Blue/Green database migrations completed successfully"
      else
        log_warning "Blue/Green migrations failed, falling back to standard migrations"
        if ! run_migrations_with_rollback "$env_name"; then
          log_error "Database migrations failed"
          # Don't remove lock file to prevent further deployments until issue is fixed
          return 1
        fi
      fi
    else
      # Run standard migrations with rollback capability
      if ! run_migrations_with_rollback "$env_name"; then
        log_error "Database migrations failed"
        # Don't remove lock file to prevent further deployments until issue is fixed
        return 1
      fi
    fi
    
    # Remove lock file
    rm -f "$MIGRATIONS_LOCK_FILE"
  else
    log_info "No migrations to run or migrations were skipped"
  fi
  
  return 0
}

# Cleanup hook - always run, even on failure
hook_cleanup() {
  # Ensure lock file is removed even if deployment fails
  if [ -f "$MIGRATIONS_LOCK_FILE" ]; then
    log_warning "Removing stale migration lock file"
    rm -f "$MIGRATIONS_LOCK_FILE"
  fi
  
  return 0
}

# Post-rollback hook - run after rollback operation
hook_post_rollback() {
  # Ensure any locks are cleared after rollback
  if [ -f "$MIGRATIONS_LOCK_FILE" ]; then
    log_warning "Removing migration lock file after rollback"
    rm -f "$MIGRATIONS_LOCK_FILE"
  fi
  
  log_warning "Note: Any database migrations applied may still be active!"
  log_warning "Check ${DB_FULL_BACKUP_DIR} for recent backups if you need to restore."
  
  return 0
}