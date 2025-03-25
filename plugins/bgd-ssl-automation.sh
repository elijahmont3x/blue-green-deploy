#!/bin/bash
#
# bgd-ssl-automation.sh - SSL certificate management plugin for Blue/Green Deployment
#
# This plugin automates SSL certificate handling:
# - Automatic certificate generation and renewal
# - ACME challenge configuration
# - Nginx SSL configuration
#
# Place this file in the plugins/ directory to automatically activate it.

# Register plugin arguments
bgd_register_ssl_automation_arguments() {
  bgd_register_plugin_argument "ssl-automation" "SSL_ENABLED" "true"
  bgd_register_plugin_argument "ssl-automation" "CERTBOT_EMAIL" ""
  bgd_register_plugin_argument "ssl-automation" "CERTBOT_STAGING" "false"
  bgd_register_plugin_argument "ssl-automation" "SSL_DOMAINS" ""
  bgd_register_plugin_argument "ssl-automation" "SSL_AUTO_RENEWAL" "true"
  bgd_register_plugin_argument "ssl-automation" "SSL_CERT_PATH" "./certs"
  bgd_register_plugin_argument "ssl-automation" "SSL_AUTO_INSTALL_DEPS" "true"
}

# Check if required tools are installed
bgd_check_ssl_dependencies() {
  if ! command -v certbot &> /dev/null; then
    if [ "${SSL_AUTO_INSTALL_DEPS:-true}" = "true" ]; then
      bgd_log_info "Certbot not found. Attempting to install it..."
      
      # Check which package manager is available
      if command -v apt-get &> /dev/null; then
        bgd_log_info "Using apt-get to install certbot..."
        sudo apt-get update
        sudo apt-get install -y certbot
      elif command -v yum &> /dev/null; then
        bgd_log_info "Using yum to install certbot..."
        sudo yum install -y certbot
      elif command -v dnf &> /dev/null; then
        bgd_log_info "Using dnf to install certbot..."
        sudo dnf install -y certbot
      elif command -v brew &> /dev/null; then
        bgd_log_info "Using brew to install certbot..."
        brew install certbot
      else
        bgd_log_error "Could not determine package manager to install certbot"
        bgd_log_error "Please install certbot manually: https://certbot.eff.org/instructions"
        return 1
      fi
      
      # Verify installation
      if ! command -v certbot &> /dev/null; then
        bgd_log_error "Failed to install certbot automatically"
        bgd_log_error "Please install certbot manually: https://certbot.eff.org/instructions"
        return 1
      fi
    else
      bgd_log_error "Certbot not found. Please install certbot: https://certbot.eff.org/instructions"
      bgd_log_error "Or set --ssl-auto-install-deps=true to attempt automatic installation"
      return 1
    fi
  fi
  
  return 0
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
bgd_obtain_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local email="${CERTBOT_EMAIL}"
  local staging="${CERTBOT_STAGING:-false}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  bgd_log_info "Obtaining SSL certificates for $domain"
  
  if [ -z "$email" ]; then
    bgd_log_error "CERTBOT_EMAIL is required for SSL certificate generation"
    return 1
  fi
  
  # Check dependencies first
  bgd_check_ssl_dependencies || return 1
  
  # Create cert directory if it doesn't exist
  bgd_ensure_directory "$cert_path"
  
  # Build Certbot command
  local certbot_cmd="certbot certonly --webroot -w $(pwd) -d ${domain} -d www.${domain}"
  
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
  
  # Copy certificates to our cert path
  cp /etc/letsencrypt/live/${domain}/fullchain.pem "$cert_path/fullchain.pem"
  cp /etc/letsencrypt/live/${domain}/privkey.pem "$cert_path/privkey.pem"
  
  bgd_log_success "SSL certificates obtained successfully"
  return 0
}

# Set up Nginx with SSL configuration
bgd_setup_nginx_ssl() {
  local domain="${1:-$DOMAIN_NAME}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  bgd_log_info "Setting up Nginx SSL configuration for $domain"
  
  # Check if we have a template for SSL
  local nginx_ssl_template="${BGD_SCRIPT_DIR:-./scripts}/../config/templates/nginx-ssl.conf.template"
  
  if [ ! -f "$nginx_ssl_template" ]; then
    bgd_log_warning "Nginx SSL template not found at $nginx_ssl_template, using default"
    
    # Create a basic template
    cat > nginx.ssl.conf << EOL
server {
    listen ${NGINX_PORT:-80};
    server_name ${domain} www.${domain};
    
    location /.well-known/acme-challenge/ {
        root $(pwd);
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen ${NGINX_SSL_PORT:-443} ssl;
    server_name ${domain} www.${domain};
    
    ssl_certificate ${cert_path}/fullchain.pem;
    ssl_certificate_key ${cert_path}/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;
    
    # Pass traffic to the current active environment
    location / {
        proxy_pass http://\$active_env;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOL

    # Use this as our Nginx config
    cp nginx.ssl.conf nginx.conf
  else
    # Use the provided template
    cat "$nginx_ssl_template" | \
      sed -e "s/DOMAIN_NAME/$domain/g" | \
      sed -e "s/CERT_PATH/${cert_path//\//\\/}/g" | \
      sed -e "s/NGINX_PORT/${NGINX_PORT:-80}/g" | \
      sed -e "s/NGINX_SSL_PORT/${NGINX_SSL_PORT:-443}/g" | \
      sed -e "s/APP_NAME/$APP_NAME/g" > nginx.conf
  fi
  
  # Get Docker Compose command
  local docker_compose=$(bgd_get_docker_compose_cmd)
  
  # Restart Nginx
  $docker_compose restart nginx || bgd_log_warning "Failed to restart Nginx with SSL configuration"
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
      # Check dependencies first
      if ! bgd_check_ssl_dependencies; then
        bgd_log_warning "SSL dependencies not satisfied. Continuing without SSL."
        return 0
      fi
      
      # Set up ACME challenge
      bgd_setup_acme_challenge "$domain"
      
      # Obtain certificates
      bgd_obtain_certificates "$domain" || {
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
