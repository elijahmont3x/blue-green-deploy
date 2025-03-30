#!/bin/bash
#
# bgd-ssl.sh - SSL certificate management plugin for Blue/Green Deployment
#
# This plugin handles SSL certificate management:
# - Automatic certificate generation with Let's Encrypt
# - DNS challenge configuration
# - Nginx SSL configuration

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

# Check if this is a CI environment
bgd_is_ci_environment() {
  # Check common CI environment variables
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ] || [ -n "${JENKINS_URL:-}" ]; then
    return 0
  fi
  return 1
}

# Check if SSL certificates exist
bgd_check_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  if [ -f "$cert_path/fullchain.pem" ] && [ -f "$cert_path/privkey.pem" ]; then
    # Check if certificate is valid and not expired
    if openssl x509 -checkend 2592000 -noout -in "$cert_path/fullchain.pem" &>/dev/null; then
      bgd_log "Valid SSL certificates found for $domain" "info"
      return 0
    else
      bgd_log "SSL certificate for $domain will expire soon or is invalid" "warning"
      return 1
    fi
  else
    bgd_log "No SSL certificates found for $domain" "info"
    return 1
  fi
}

# Install required dependencies
bgd_install_ssl_dependencies() {
  # Skip dependency installation if disabled
  if [ "${SSL_AUTO_INSTALL_DEPS:-true}" != "true" ]; then
    bgd_log "Skipping dependency installation" "info"
    return 0
  fi

  # Ensure Certbot is installed
  if ! command -v certbot &> /dev/null; then
    bgd_log "Certbot not found. Installing..." "info"
    
    # Check package manager and install certbot
    if command -v apt-get &> /dev/null; then
      sudo apt-get update || {
        bgd_log "Failed to update package manager" "error"
        return 1
      }
      sudo apt-get install -y certbot || {
        bgd_log "Failed to install certbot via apt-get" "error"
        return 1
      }
    elif command -v yum &> /dev/null; then
      sudo yum install -y certbot || {
        bgd_log "Failed to install certbot via yum" "error"
        return 1
      }
    elif command -v dnf &> /dev/null; then
      sudo dnf install -y certbot || {
        bgd_log "Failed to install certbot via dnf" "error"
        return 1
      }
    else
      bgd_log "Unable to install certbot: No supported package manager found" "error"
      return 1
    fi
    
    if ! command -v certbot &> /dev/null; then
      bgd_log "Failed to install certbot" "error"
      return 1
    fi
  fi
  
  return 0
}

# Obtain SSL certificates using Certbot with improved security
bgd_obtain_ssl_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local email="${CERTBOT_EMAIL}"
  local staging="${CERTBOT_STAGING:-false}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  # Check if we're in a CI environment
  if bgd_is_ci_environment; then
    bgd_log "CI environment detected, skipping SSL certificate generation" "warning"
    return 0
  fi
  
  bgd_log "Obtaining SSL certificates for $domain" "info"
  
  # Check required parameters
  if [ -z "$email" ]; then
    bgd_log "CERTBOT_EMAIL is required for SSL certificate generation" "error"
    return 1
  fi
  
  # Install dependencies
  bgd_install_ssl_dependencies || {
    bgd_log "Failed to install dependencies" "error"
    return 1
  }
  
  # Create certificates directory with secure permissions
  bgd_ensure_directory "$cert_path"
  chmod 700 "$cert_path"
  
  # Create a secure temporary directory for certificate processing
  local temp_cert_dir=$(mktemp -d)
  chmod 700 "$temp_cert_dir"
  
  # Build Certbot command
  local certbot_cmd="certbot certonly --standalone"
  
  # Add domain
  certbot_cmd+=" -d $domain"
  
  # Add extra domains if specified
  if [ -n "${SSL_DOMAINS:-}" ]; then
    for extra_domain in ${SSL_DOMAINS//,/ }; do
      certbot_cmd+=" -d $extra_domain"
    done
  fi
  
  # Add email and other options
  certbot_cmd+=" --email $email --agree-tos --non-interactive"
  
  # Add option to save certificates to temp directory
  certbot_cmd+=" --cert-path $temp_cert_dir"
  
  # Use staging if specified
  if [ "$staging" = "true" ]; then
    certbot_cmd+=" --staging"
  fi
  
  bgd_log "Running: $certbot_cmd" "info"
  
  # Stop Nginx temporarily for port 80
  local docker_compose=$(bgd_get_docker_compose_cmd)
  $docker_compose stop nginx || true
  
  # Run Certbot
  eval "sudo $certbot_cmd" || {
    bgd_log "Failed to obtain SSL certificates" "error"
    # Restart Nginx
    $docker_compose start nginx || true
    # Clean up temp directory
    rm -rf "$temp_cert_dir"
    return 1
  }
  
  # Restart Nginx
  $docker_compose start nginx || true
  
  # Copy certificates to our cert path with secure permissions
  bgd_ensure_directory "$cert_path"
  sudo cp /etc/letsencrypt/live/$domain/fullchain.pem "$temp_cert_dir/fullchain.pem"
  sudo cp /etc/letsencrypt/live/$domain/privkey.pem "$temp_cert_dir/privkey.pem"
  
  # Set secure permissions on temp files
  sudo chmod 600 "$temp_cert_dir/fullchain.pem"
  sudo chmod 600 "$temp_cert_dir/privkey.pem"
  
  # Move files to final destination (atomic operation)
  mv "$temp_cert_dir/fullchain.pem" "$cert_path/fullchain.pem"
  mv "$temp_cert_dir/privkey.pem" "$cert_path/privkey.pem"
  
  # Set final permissions
  chmod 644 "$cert_path/fullchain.pem" # Certificate can be readable
  chmod 600 "$cert_path/privkey.pem"   # Private key must be secure
  
  # Clean up temp directory
  rm -rf "$temp_cert_dir"
  
  bgd_log "SSL certificates obtained and secured successfully" "success"
  return 0
}

# Set up Nginx with SSL configuration
bgd_setup_nginx_ssl() {
  local domain="${1:-$DOMAIN_NAME}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  
  bgd_log "Configuring Nginx with SSL for $domain" "info"
  
  # Check if certificates exist
  if ! bgd_check_certificates "$domain"; then
    bgd_log "SSL certificates not found, unable to configure Nginx for SSL" "error"
    return 1
  fi
  
  # Ensure certificate directory is properly linked in nginx config
  bgd_ensure_directory "$cert_path"
  # No need to modify nginx.conf templates as they already include SSL configuration
  # Our new template system handles SSL configuration properly
  
  bgd_log "Nginx SSL configuration is handled by the template system" "info"
  return 0
}

# Set up automatic renewal script
bgd_setup_auto_renewal() {
  local domain="${1:-$DOMAIN_NAME}"
  
  if [ "${SSL_AUTO_RENEWAL:-true}" = "true" ]; then
    bgd_log "Setting up automatic renewal for $domain SSL certificate" "info"
    
    # Skip in CI environment
    if bgd_is_ci_environment; then
      bgd_log "CI environment detected, skipping renewal setup" "warning"
      return 0
    fi
    
    # Create renewal script
    cat > renew-ssl.sh << 'EOL'
#!/bin/bash
# Renew SSL certificates using certbot's renew command
certbot renew --quiet

# Check if renewal was successful
if [ $? -eq 0 ]; then
  # Copy certificates to our cert path
  cp /etc/letsencrypt/live/DOMAIN_NAME/fullchain.pem CERT_PATH/fullchain.pem
  cp /etc/letsencrypt/live/DOMAIN_NAME/privkey.pem CERT_PATH/privkey.pem
  chmod 644 CERT_PATH/fullchain.pem
  chmod 644 CERT_PATH/privkey.pem
  
  # Restart nginx to apply new certificates
  cd APP_PATH
  docker compose restart nginx || docker-compose restart nginx
  echo "$(date) - Successfully renewed certificates and restarted nginx" >> CERT_PATH/renewal.log
else
  echo "$(date) - Certificate renewal failed" >> CERT_PATH/renewal.log
fi
EOL
    
    # Replace placeholders
    sed -i "s/DOMAIN_NAME/$domain/g" renew-ssl.sh
    sed -i "s|CERT_PATH|${SSL_CERT_PATH:-./certs}|g" renew-ssl.sh
    sed -i "s|APP_PATH|$(pwd)|g" renew-ssl.sh
    
    # Make executable
    chmod +x renew-ssl.sh
    
    # Add cron job to run twice daily (standard for Let's Encrypt)
    (crontab -l 2>/dev/null || echo "") | grep -v "renew-ssl.sh" > mycron
    echo "0 0,12 * * * $(pwd)/renew-ssl.sh > $(pwd)/logs/renew-ssl.log 2>&1" >> mycron
    crontab mycron
    rm mycron
    
    bgd_log "Automatic SSL renewal configured" "success"
  fi
  
  return 0
}

# SSL Plugin Hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [ "${SSL_ENABLED:-true}" = "true" ] && [ -n "${DOMAIN_NAME:-}" ]; then
    bgd_log "Setting up SSL for $DOMAIN_NAME" "info"
    
    # Check if certificates exist, obtain if missing
    if ! bgd_check_certificates "$DOMAIN_NAME"; then
      bgd_obtain_ssl_certificates "$DOMAIN_NAME" || {
        bgd_log "Failed to obtain SSL certificates" "warning"
        bgd_log "Continuing deployment without SSL" "warning"
        return 1
      }
    fi
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${SSL_ENABLED:-true}" = "true" ] && [ -n "${DOMAIN_NAME:-}" ]; then
    # Set up auto-renewal if certificates exist
    if bgd_check_certificates "$DOMAIN_NAME"; then
      bgd_setup_auto_renewal "$DOMAIN_NAME"
    else
      bgd_log "SSL certificates not available, using HTTP only" "warning"
    fi
  fi
  
  return 0
}