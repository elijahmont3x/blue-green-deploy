#!/bin/bash
#
# ssl-automation.sh - Automatic SSL certificate management with Let's Encrypt
#
# This plugin handles the automatic generation and renewal of SSL certificates
# using Let's Encrypt for domains configured in the blue/green deployment.
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
register_ssl_automation_arguments() {
  register_plugin_argument "ssl-automation" "SSL_ENABLED" "false"
  register_plugin_argument "ssl-automation" "CERTBOT_EMAIL" "admin@example.com"
  register_plugin_argument "ssl-automation" "CERTBOT_STAGING" "false"
}

# Global variables
SSL_CERT_DIR="./certs"
WEBROOT_DIR="./www/.well-known"
RENEWAL_SCRIPT="./scripts/renew-certificates.sh"

# Ensure webroot directory exists for ACME challenge
setup_webroot() {
  ensure_directory "$WEBROOT_DIR"
  
  # Create a special nginx config block to expose the webroot
  cat > "config/acme-challenge.conf" << EOL
# ACME challenge configuration block
location /.well-known/acme-challenge/ {
    root /var/www/html;
    allow all;
}
EOL

  log_info "Created ACME challenge configuration"
}

# Update nginx config to include ACME challenge configuration
update_nginx_config_for_acme() {
  local nginx_conf="$1"
  
  # Check if already contains ACME challenge
  if grep -q "ACME challenge" "$nginx_conf"; then
    log_info "Nginx config already contains ACME challenge configuration"
    return 0
  fi
  
  # Add include directive for ACME challenge
  sed -i '/location \/ {/i \    # Include ACME challenge config for Let\'s Encrypt\n    include /etc/nginx/acme-challenge.conf;\n' "$nginx_conf"
  
  log_info "Updated nginx config to include ACME challenge configuration"
}

# Generate SSL certificates for specified domains
generate_certificates() {
  local primary_domain="$1"
  shift
  local alt_domains=("$@")
  
  # Ensure SSL cert directory exists
  ensure_directory "$SSL_CERT_DIR"
  
  # Ensure webroot for ACME challenge
  setup_webroot
  
  # Check if certificates already exist and are valid
  if [ -f "$SSL_CERT_DIR/fullchain.pem" ] && [ -f "$SSL_CERT_DIR/privkey.pem" ]; then
    # Check certificate expiration (30 days margin)
    local expiry_date=$(openssl x509 -in "$SSL_CERT_DIR/fullchain.pem" -noout -enddate | cut -d= -f2)
    local expiry_epoch=$(date -d "$expiry_date" +%s)
    local now_epoch=$(date +%s)
    local thirty_days=$((30 * 24 * 60 * 60))
    
    if [ $((expiry_epoch - now_epoch)) -gt $thirty_days ]; then
      log_info "SSL certificates already exist and are valid for more than 30 days"
      return 0
    else
      log_info "SSL certificates exist but expire soon, renewing"
    fi
  else
    log_info "SSL certificates not found, generating new ones"
  fi
  
  # Prepare domain parameters
  local domain_params="-d $primary_domain"
  for domain in "${alt_domains[@]}"; do
    domain_params="$domain_params -d $domain"
  done
  
  # Use staging server for testing if enabled
  local staging_param=""
  if [ "$CERTBOT_STAGING" = "true" ]; then
    staging_param="--staging"
    log_warning "Using Let's Encrypt staging server (certificates won't be trusted)"
  fi
  
  # Starting nginx with special config for ACME challenge
  update_nginx_config_for_acme "nginx.conf"
  restart_nginx
  
  # Run certbot to get certificates
  log_info "Requesting certificates for domains: $primary_domain ${alt_domains[*]}"
  
  # Certbot command using webroot authentication
  docker run --rm \
    -v "$PWD/$SSL_CERT_DIR:/etc/letsencrypt" \
    -v "$PWD/$WEBROOT_DIR:/var/www/html/.well-known" \
    certbot/certbot certonly $staging_param \
    --webroot -w /var/www/html \
    --email "$CERTBOT_EMAIL" \
    $domain_params \
    --agree-tos --non-interactive
  
  local certbot_result=$?
  
  if [ $certbot_result -eq 0 ]; then
    log_success "Successfully obtained SSL certificates"
    
    # Copy certificates to the right location
    local cert_path="/etc/letsencrypt/live/$primary_domain"
    
    # Ensure proper symlinks for Nginx
    cp -L "$SSL_CERT_DIR$cert_path/fullchain.pem" "$SSL_CERT_DIR/fullchain.pem"
    cp -L "$SSL_CERT_DIR$cert_path/privkey.pem" "$SSL_CERT_DIR/privkey.pem"
    
    log_info "Certificates installed in $SSL_CERT_DIR"
    
    # Create renewal script
    create_renewal_script
    
    return 0
  else
    log_error "Failed to obtain SSL certificates (exit code: $certbot_result)"
    return 1
  fi
}

# Create a certificate renewal script
create_renewal_script() {
  log_info "Creating certificate renewal script"
  
  cat > "$RENEWAL_SCRIPT" << EOL
#!/bin/bash
#
# renew-certificates.sh - Automatic renewal of Let's Encrypt certificates
#
# This script is meant to be run as a cron job, e.g.:
# 0 0 * * * /path/to/renew-certificates.sh
#

# Set up environment
cd \$(dirname \$(readlink -f \$0))/..
source ./scripts/common.sh

# Ensure proper directories exist
mkdir -p ./www/.well-known
mkdir -p ./certs

# Update nginx config if needed
if grep -q "ACME challenge" nginx.conf; then
  echo "Nginx config already contains ACME challenge configuration"
else
  # Add include directive for ACME challenge
  sed -i '/location \\/ {/i \\\    # Include ACME challenge config for Let\\'\\'s Encrypt\\n    include /etc/nginx/acme-challenge.conf;\\n' nginx.conf
  
  # Restart nginx to apply changes
  docker-compose restart nginx
fi

# Run certbot renewal
docker run --rm \\
  -v "\$PWD/certs:/etc/letsencrypt" \\
  -v "\$PWD/www/.well-known:/var/www/html/.well-known" \\
  certbot/certbot renew --webroot -w /var/www/html \\
  --non-interactive

# If renewed, copy certificates to the right location
if [ \$? -eq 0 ]; then
  echo "Certificate renewal successful or not needed at this time"
  
  # Copy certificates to the right location if they were renewed
  find ./certs/live -type d -name "$DOMAIN_NAME" | while read cert_dir; do
    # Check if certificates were renewed based on timestamp
    if [ -n "\$(find \$cert_dir -name fullchain.pem -mtime -1)" ]; then
      echo "Certificates were renewed, updating symlinks"
      cp -L "\$cert_dir/fullchain.pem" ./certs/fullchain.pem
      cp -L "\$cert_dir/privkey.pem" ./certs/privkey.pem
      
      # Restart nginx to load new certificates
      docker-compose restart nginx
    fi
  done
else
  echo "Certificate renewal failed"
  exit 1
fi
EOL
  
  chmod +x "$RENEWAL_SCRIPT"
  log_success "Created renewal script: $RENEWAL_SCRIPT"
  
  # Add cron job for renewal
  setup_renewal_cron
}

# Set up renewal cron job
setup_renewal_cron() {
  log_info "Setting up renewal cron job"
  
  # Check if cron job already exists
  if crontab -l 2>/dev/null | grep -q "$RENEWAL_SCRIPT"; then
    log_info "Renewal cron job already exists"
    return 0
  fi
  
  # Get absolute path to renewal script
  local script_path=$(readlink -f "$RENEWAL_SCRIPT")
  
  # Add to crontab (twice a day as recommended by Let's Encrypt)
  (crontab -l 2>/dev/null; echo "0 0,12 * * * $script_path") | crontab -
  
  log_success "Added renewal cron job (runs at midnight and noon)"
}

# Restart nginx after config changes
restart_nginx() {
  log_info "Restarting nginx to apply configuration changes"
  
  local current_env=$(echo $(get_environments) | cut -d' ' -f1)
  if [ -n "$current_env" ]; then
    docker-compose -p "${APP_NAME}-${current_env}" restart nginx
  else
    log_warning "No active environment found, skipping nginx restart"
  fi
}

# Pre-deployment hook
hook_pre_deploy() {
  local version="$1"
  
  # Only proceed if SSL is enabled
  if [ "$SSL_ENABLED" != "true" ]; then
    return 0
  fi
  
  # If domain name is set, ensure certificates
  if [ -n "${DOMAIN_NAME:-}" ]; then
    log_info "Domain name is set to $DOMAIN_NAME, checking SSL certificates"
    
    # Prepare alternate domains
    local alt_domains=("www.$DOMAIN_NAME" "api.$DOMAIN_NAME" "team.$DOMAIN_NAME")
    
    # Generate certificates if needed
    generate_certificates "$DOMAIN_NAME" "${alt_domains[@]}"
  else
    log_info "No domain name set, skipping SSL certificate check"
  fi
  
  return 0
}