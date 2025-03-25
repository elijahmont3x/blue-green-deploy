#!/bin/bash
#
# bgd-ssl.sh - SSL certificate management plugin for Blue/Green Deployment
#
# This plugin handles SSL certificate management:
# - Automatic certificate generation and renewal
# - ACME challenge configuration
# - Nginx SSL configuration
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
bgd_register_ssl_arguments() {
  bgd_register_plugin_argument "ssl" "SSL_ENABLED" "true"
  bgd_register_plugin_argument "ssl" "CERTBOT_EMAIL" ""
  bgd_register_plugin_argument "ssl" "CERTBOT_STAGING" "false"
  bgd_register_plugin_argument "ssl" "SSL_DOMAINS" ""
  bgd_register_plugin_argument "ssl" "SSL_AUTO_RENEWAL" "true"
  bgd_register_plugin_argument "ssl" "SSL_CERT_PATH" "./certs"
  bgd_register_plugin_argument "ssl" "SSL_AUTO_INSTALL_DEPS" "true"
}

# Check if SSL certificates exist
bgd_check_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  if [ -f "$cert_path/fullchain.pem" ] && [ -f "$cert_path/privkey.pem" ]; then
    # Check if certificate is valid and not expired
    if openssl x509 -checkend 2592000 -noout -in "$cert_path/fullchain.pem" &>/dev/null; then
      bgd_log_info "Valid SSL certificates found for $domain"
      return 0
    else
      bgd_log_warning "SSL certificate for $domain will expire soon or is invalid"
      return 1
    fi
  else
    bgd_log_info "No SSL certificates found for $domain"
    return 1
  fi
}

# Create a temporary Nginx config for ACME challenges
bgd_setup_acme_challenge() {
  local domain="${1:-$DOMAIN_NAME}"
  bgd_log_info "Setting up ACME challenge for $domain"
  
  # Create directory for ACME challenges
  mkdir -p ./.well-known/acme-challenge
  chmod -R 755 ./.well-known
  
  # Create temporary Nginx config for ACME validation
  cat > nginx.acme.conf << EOL
server {
    listen 80;
    server_name ${domain} www.${domain};
    
    location /.well-known/acme-challenge/ {
        root $(pwd);
    }
    
    location / {
        return 301 https://${domain}\$request_uri;
    }
}
EOL

  # Get Docker Compose command
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Backup existing config
  if [ -f "nginx.conf" ]; then
    cp nginx.conf nginx.conf.backup
  fi
  
  # Use the temporary config
  cp nginx.acme.conf nginx.conf
  
  # Restart Nginx
  $docker_compose restart nginx || bgd_log_warning "Failed to restart Nginx for ACME configuration"
}

# Obtain SSL certificates using Certbot
bgd_obtain_ssl_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local email="${CERTBOT_EMAIL}"
  local webroot="${3:-$(pwd)}"
  local staging="${CERTBOT_STAGING:-false}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  bgd_log_info "Obtaining SSL certificates for $domain"
  
  if [ -z "$email" ]; then
    bgd_log_error "CERTBOT_EMAIL is required for SSL certificate generation"
    return 1
  fi
  
  # Ensure Certbot is installed
  if ! command -v certbot &> /dev/null; then
    if [ "${SSL_AUTO_INSTALL_DEPS:-true}" = "true" ]; then
      bgd_log_info "Certbot not found. Installing..."
      sudo apt-get update
      sudo apt-get install -y certbot
      
      if ! command -v certbot &> /dev/null; then
        bgd_log_error "Failed to install certbot"
        return 1
      fi
    else
      bgd_log_error "Certbot not found and auto-install disabled"
      return 1
    fi
  fi

  # Build Certbot command
  local certbot_cmd="certbot certonly --webroot -w $webroot -d ${domain}"
  
  # Add extra domains if specified
  if [ -n "${SSL_DOMAINS:-}" ]; then
    for extra_domain in ${SSL_DOMAINS//,/ }; do
      certbot_cmd+=" -d $extra_domain"
    done
  fi
  
  # Add email and other options
  certbot_cmd+=" --email $email --agree-tos --non-interactive"
  
  # Use staging if specified
  if [ "$staging" = "true" ]; then
    certbot_cmd+=" --staging"
  fi
  
  bgd_log_info "Running: $certbot_cmd"
  
  # Run Certbot
  eval "$certbot_cmd" || {
    bgd_log_error "Failed to obtain SSL certificates"
    return 1
  }
  
  # Create certificate directory
  mkdir -p "$cert_path"
  
  # Copy certificates to our cert path
  sudo cp /etc/letsencrypt/live/${domain}/fullchain.pem "$cert_path/fullchain.pem"
  sudo cp /etc/letsencrypt/live/${domain}/privkey.pem "$cert_path/privkey.pem"
  sudo chmod 644 "$cert_path/fullchain.pem"
  sudo chmod 644 "$cert_path/privkey.pem"
  
  bgd_log_success "SSL certificates obtained successfully"
  return 0
}

# Set up Nginx with SSL configuration
bgd_setup_nginx_ssl() {
  local domain="${1:-$DOMAIN_NAME}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  local template_dir="${BGD_SCRIPT_DIR:-./scripts}/../config/templates"
  
  bgd_log_info "Setting up Nginx SSL configuration for $domain"
  
  # Get the appropriate template
  local template="$template_dir/nginx-multi-domain.conf.template"
  if [ ! -f "$template" ]; then
    bgd_log_warning "Multi-domain template not found, using single-env template"
    template="$template_dir/nginx-single-env.conf.template"
  fi
  
  if [ ! -f "$template" ]; then
    bgd_log_error "No Nginx template found"
    return 1
  fi
  
  # Generate SSL-enabled config
  bgd_update_traffic_distribution 5 5 "$template" "nginx.conf"
  
  bgd_log_success "Nginx SSL configuration updated"
  return 0
}

# Set up automatic renewal cron job
bgd_setup_auto_renewal() {
  local domain="${1:-$DOMAIN_NAME}"
  
  if [ "${SSL_AUTO_RENEWAL:-true}" = "true" ]; then
    bgd_log_info "Setting up automatic renewal for $domain SSL certificate"
    
    # Create renewal script
    cat > renew-ssl.sh << 'EOL'
#!/bin/bash
certbot renew
cp /etc/letsencrypt/live/DOMAIN_NAME/fullchain.pem CERT_PATH/fullchain.pem
cp /etc/letsencrypt/live/DOMAIN_NAME/privkey.pem CERT_PATH/privkey.pem
docker compose restart nginx || docker-compose restart nginx
EOL
    
    # Replace placeholders
    sed -i "s/DOMAIN_NAME/$domain/g" renew-ssl.sh
    sed -i "s|CERT_PATH|${SSL_CERT_PATH:-./certs}|g" renew-ssl.sh
    
    # Make executable
    chmod +x renew-ssl.sh
    
    # Add cron job to run twice daily (standard for Let's Encrypt)
    crontab -l > mycron || echo "" > mycron
    if ! grep -q "renew-ssl.sh" mycron; then
      echo "0 0,12 * * * $(pwd)/renew-ssl.sh > $(pwd)/logs/renew-ssl.log 2>&1" >> mycron
      crontab mycron
      bgd_log_info "Added cron job for SSL certificate renewal"
    else
      bgd_log_info "SSL renewal cron job already exists"
    fi
    
    rm mycron
  fi
}

# SSL Plugin Hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [ "${SSL_ENABLED:-true}" = "true" ]; then
    local domain="${DOMAIN_NAME:-example.com}"
    
    bgd_log_info "Setting up SSL for $domain"
    
    # Check if we already have valid certificates
    if ! bgd_check_certificates "$domain"; then
      # Set up ACME challenge
      bgd_setup_acme_challenge "$domain"
      
      # Obtain certificates
      bgd_obtain_ssl_certificates "$domain" || {
        bgd_log_error "Failed to obtain SSL certificates"
        # Continue without SSL - we can try again later
      }
    fi
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${SSL_ENABLED:-true}" = "true" ]; then
    local domain="${DOMAIN_NAME:-example.com}"
    
    # Set up Nginx with SSL
    if bgd_check_certificates "$domain"; then
      bgd_setup_nginx_ssl "$domain"
      bgd_setup_auto_renewal "$domain"
    else
      bgd_log_warning "SSL certificates not available, using HTTP only"
    fi
  fi
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  if [ "${SSL_ENABLED:-true}" = "true" ]; then
    local domain="${DOMAIN_NAME:-example.com}"
    
    # Ensure Nginx config is updated after cutover
    if bgd_check_certificates "$domain"; then
      bgd_log_info "Updating Nginx SSL configuration after cutover"
      bgd_setup_nginx_ssl "$domain"
    fi
  fi
  
  return 0
}
