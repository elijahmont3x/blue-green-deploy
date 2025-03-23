#!/bin/bash
#
# db-migrations.sh - Plugin for handling database migrations in blue/green deployments
#
# This plugin integrates with the blue/green deployment system to handle database migrations
# safely during the deployment process. It adds hooks to run migrations at the right time
# and with proper safeguards.
#
# Place this file in the plugins/ directory to automatically activate it.
#
# Hooks implemented:
#   - hook_pre_deploy        - Runs before deployment starts (creates lock file, backup)
#   - hook_post_health       - Runs after health checks pass (executes migrations)
#   - hook_cleanup           - Ensures lock file is removed even on failure
#   - hook_post_rollback     - Handles migration lock files after rollback

# Global variables
MIGRATIONS_DIR="./migrations"
MIGRATIONS_LOCK_FILE="/tmp/bgd-migrations.lock"
SCHEMA_BACKUP_DIR="./schema-backups"

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

# Create a backup of the database schema before migrations
backup_database_schema() {
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="${SCHEMA_BACKUP_DIR}/${APP_NAME}_schema_${timestamp}.sql"
  
  ensure_directory "$SCHEMA_BACKUP_DIR"
  
  log_info "Creating database schema backup before migrations"
  
  # Extract database connection info (this needs to be adapted to your actual DB_URL format)
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
    
    # Execute the backup
    docker-compose -p "${APP_NAME}-shared" exec -T db sh -c \
      "pg_dump -U $db_user -h $db_host -p ${db_port:-5432} --schema-only $db_name" > "$backup_file"
    
    # Check if backup was successful
    if [ $? -eq 0 ] && [ -s "$backup_file" ]; then
      log_success "Database schema backup created: $backup_file"
      # Secure the backup file
      chmod 600 "$backup_file"
    else
      log_warning "Database schema backup failed"
      rm -f "$backup_file"
    fi
    
    # Unset password
    unset PGPASSWORD
  else
    log_warning "DATABASE_URL not set, skipping schema backup"
  fi
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

# Pre-deployment hook - run before environment setup
hook_pre_deploy() {
  local version="$1"
  
  # Create lock file to prevent concurrent migrations
  if should_run_migrations; then
    log_info "Preparing for database migrations"
    touch "$MIGRATIONS_LOCK_FILE"
    backup_database_schema
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
    
    local migration_cmd=$(get_migration_command)
    log_info "Using migration command: $migration_cmd"
    
    # Run migrations in the app container
    if docker-compose -p "${APP_NAME}-${env_name}" exec -T app sh -c "$migration_cmd"; then
      log_success "Database migrations completed successfully"
    else
      log_error "Database migrations failed"
      # Don't remove lock file to prevent further deployments until issue is fixed
      return 1
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
  
  log_warning "Note: Database migrations cannot be rolled back automatically!"
  log_warning "You may need to restore from a backup if migrations caused issues."
  
  return 0
}