#!/bin/bash
#
# bgd-ssl.sh - SSL certificate management plugin for Blue/Green Deployment
#
# This plugin handles SSL certificate management using DNS verification:
# - Supports multiple DNS providers (GoDaddy, Namecheap)
# - Automatic certificate generation and renewal
# - DNS challenge configuration for domain validation 
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
  bgd_register_plugin_argument "ssl" "SSL_DNS_PROPAGATION_WAIT" "60"
  bgd_register_plugin_argument "ssl" "SSL_SKIP_IF_CI" "true"
  
  # GoDaddy API credentials
  bgd_register_plugin_argument "ssl" "GODADDY_API_KEY" ""
  bgd_register_plugin_argument "ssl" "GODADDY_API_SECRET" ""
  
  # Namecheap API credentials
  bgd_register_plugin_argument "ssl" "NAMECHEAP_API_KEY" ""
  bgd_register_plugin_argument "ssl" "NAMECHEAP_API_USER" ""
  bgd_register_plugin_argument "ssl" "NAMECHEAP_USERNAME" ""
}

# Check if this is a CI environment
bgd_is_ci_environment() {
  # Check common CI environment variables
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ] || [ -n "${JENKINS_URL:-}" ] || [ -n "${TRAVIS:-}" ] || [ -n "${CIRCLECI:-}" ]; then
    return 0
  fi
  return 1
}

# Detect which DNS provider to use based on available credentials
bgd_get_dns_provider() {
  if [ -n "${GODADDY_API_KEY:-}" ] && [ -n "${GODADDY_API_SECRET:-}" ]; then
    echo "godaddy"
  elif [ -n "${NAMECHEAP_API_KEY:-}" ] && [ -n "${NAMECHEAP_API_USER:-}" ] && [ -n "${NAMECHEAP_USERNAME:-}" ]; then
    echo "namecheap"
  else
    echo ""
  fi
}

# Check if DNS provider credentials are available
bgd_has_dns_credentials() {
  if [ -n "$(bgd_get_dns_provider)" ]; then
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

# Check if certificate exists but needs reconfiguration for DNS validation
bgd_check_certificate_needs_reconfiguration() {
  local domain="${1:-$DOMAIN_NAME}"
  
  # Check if certificate exists
  if sudo certbot certificates | grep -q "$domain"; then
    # Check if it's not configured for DNS validation
    if ! grep -q "dns-godaddy\|dns-namecheap" "/etc/letsencrypt/renewal/$domain.conf" 2>/dev/null; then
      bgd_log_info "Found existing certificate for $domain that needs reconfiguration for DNS validation"
      return 0
    fi
  fi
  
  return 1
}

# Install required dependencies
bgd_install_ssl_dependencies() {
  # Ensure Certbot is installed
  if ! command -v certbot &> /dev/null; then
    bgd_log_info "Certbot not found. Installing..."
    sudo apt-get update
    sudo apt-get install -y certbot
    
    if ! command -v certbot &> /dev/null; then
      bgd_log_error "Failed to install certbot"
      return 1
    fi
  fi
  
  # Install appropriate DNS plugin based on provider
  local dns_provider=$(bgd_get_dns_provider)
  
  if [ "$dns_provider" = "godaddy" ]; then
    # Try to install with apt first (system package)
    if apt-cache search python3-certbot-dns-godaddy | grep -q python3-certbot-dns-godaddy; then
      bgd_log_info "Installing certbot-dns-godaddy plugin via apt..."
      sudo apt-get install -y python3-certbot-dns-godaddy || {
        bgd_log_error "Failed to install system package, falling back to pip"
      }
    fi
    
    # If apt install failed or package not available, use pip
    if ! python3 -c "import certbot_dns_godaddy" 2>/dev/null; then
      bgd_log_info "Installing certbot-dns-godaddy plugin via pip..."
      sudo pip3 install certbot-dns-godaddy || {
        bgd_log_error "Failed to install certbot-dns-godaddy plugin"
        return 1
      }
    fi
  elif [ "$dns_provider" = "namecheap" ]; then
    # Try to install with apt first (system package)
    if apt-cache search python3-certbot-dns-namecheap | grep -q python3-certbot-dns-namecheap; then
      bgd_log_info "Installing certbot-dns-namecheap plugin via apt..."
      sudo apt-get install -y python3-certbot-dns-namecheap || {
        bgd_log_error "Failed to install system package, falling back to pip"
      }
    fi
    
    # If apt install failed or package not available, use pip
    if ! python3 -c "import certbot_dns_namecheap" 2>/dev/null; then
      bgd_log_info "Installing certbot-dns-namecheap plugin via pip..."
      sudo pip3 install certbot-dns-namecheap || {
        bgd_log_error "Failed to install certbot-dns-namecheap plugin"
        return 1
      }
    fi
  else
    bgd_log_error "No DNS provider credentials detected"
    return 1
  fi
  
  return 0
}

# Create DNS provider credentials file
bgd_create_dns_credentials() {
  local dns_provider=$(bgd_get_dns_provider)
  
  if [ "$dns_provider" = "godaddy" ]; then
    # Create GoDaddy credentials
    local credentials_dir="/etc/letsencrypt/godaddy"
    local credentials_file="$credentials_dir/credentials.ini"
    
    if [ -n "${GODADDY_API_KEY:-}" ] && [ -n "${GODADDY_API_SECRET:-}" ]; then
      # Create directory if it doesn't exist
      sudo mkdir -p "$credentials_dir"
      
      # Create or overwrite credentials file
      sudo bash -c "cat > $credentials_file << EOF
dns_godaddy_key = $GODADDY_API_KEY
dns_godaddy_secret = $GODADDY_API_SECRET
EOF"
      
      # Set secure permissions
      sudo chmod 600 "$credentials_file"
      
      bgd_log_info "GoDaddy credentials configured for certbot"
      return 0
    else
      bgd_log_error "GoDaddy API key and secret are required"
      return 1
    fi
  elif [ "$dns_provider" = "namecheap" ]; then
    # Create Namecheap credentials
    local credentials_dir="/etc/letsencrypt/namecheap"
    local credentials_file="$credentials_dir/credentials.ini"
    
    if [ -n "${NAMECHEAP_API_KEY:-}" ] && [ -n "${NAMECHEAP_API_USER:-}" ] && [ -n "${NAMECHEAP_USERNAME:-}" ]; then
      # Create directory if it doesn't exist
      sudo mkdir -p "$credentials_dir"
      
      # Create or overwrite credentials file
      sudo bash -c "cat > $credentials_file << EOF
dns_namecheap_api_key = $NAMECHEAP_API_KEY
dns_namecheap_api_user = $NAMECHEAP_API_USER
dns_namecheap_username = $NAMECHEAP_USERNAME
EOF"
      
      # Set secure permissions
      sudo chmod 600 "$credentials_file"
      
      bgd_log_info "Namecheap credentials configured for certbot"
      return 0
    else
      bgd_log_error "Namecheap API key, API user, and username are required"
      return 1
    fi
  else
    bgd_log_error "No DNS provider credentials detected"
    return 1
  fi
}

# Reconfigure existing certificate to use DNS validation
bgd_reconfigure_certificate() {
  local domain="${1:-$DOMAIN_NAME}"
  local dns_provider=$(bgd_get_dns_provider)
  local propagation_wait="${SSL_DNS_PROPAGATION_WAIT:-60}"
  
  bgd_log_info "Reconfiguring existing certificate for $domain to use $dns_provider DNS validation"
  
  # Ensure credentials are set up
  bgd_create_dns_credentials || {
    bgd_log_error "Failed to create DNS credentials file"
    return 1
  }
  
  local certbot_cmd="certbot certonly --force-renewal"
  
  if [ "$dns_provider" = "godaddy" ]; then
    certbot_cmd+=" --authenticator dns-godaddy"
    certbot_cmd+=" --dns-godaddy-credentials /etc/letsencrypt/godaddy/credentials.ini"
    certbot_cmd+=" --dns-godaddy-propagation-seconds $propagation_wait"
  elif [ "$dns_provider" = "namecheap" ]; then
    certbot_cmd+=" --authenticator dns-namecheap"
    certbot_cmd+=" --dns-namecheap-credentials /etc/letsencrypt/namecheap/credentials.ini"
    certbot_cmd+=" --dns-namecheap-propagation-seconds $propagation_wait"
  else
    bgd_log_error "No DNS provider credentials detected"
    return 1
  fi
  
  # Add domain
  certbot_cmd+=" -d $domain"
  
  # Add extra domains if specified
  if [ -n "${SSL_DOMAINS:-}" ]; then
    for extra_domain in ${SSL_DOMAINS//,/ }; do
      certbot_cmd+=" -d $extra_domain"
    done
  fi
  
  # Add non-interactive flag
  certbot_cmd+=" --non-interactive"
  
  bgd_log_info "Running: $certbot_cmd"
  
  # Run Certbot
  eval "sudo $certbot_cmd" || {
    bgd_log_error "Failed to reconfigure certificate"
    return 1
  }
  
  # Update our certificate path
  local cert_path="${SSL_CERT_PATH:-./certs}"
  mkdir -p "$cert_path"
  sudo cp /etc/letsencrypt/live/${domain}/fullchain.pem "$cert_path/fullchain.pem"
  sudo cp /etc/letsencrypt/live/${domain}/privkey.pem "$cert_path/privkey.pem"
  sudo chmod 644 "$cert_path/fullchain.pem"
  sudo chmod 644 "$cert_path/privkey.pem"
  
  bgd_log_success "Certificate successfully reconfigured for $dns_provider DNS validation"
  return 0
}

# Obtain SSL certificates using Certbot with DNS verification
bgd_obtain_ssl_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local email="${CERTBOT_EMAIL}"
  local staging="${CERTBOT_STAGING:-false}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  local propagation_wait="${SSL_DNS_PROPAGATION_WAIT:-60}"
  local dns_provider=$(bgd_get_dns_provider)
  
  bgd_log_info "Obtaining SSL certificates for $domain using DNS verification"
  
  # Check if DNS provider credentials are available
  if [ -z "$dns_provider" ]; then
    bgd_log_error "DNS provider credentials are required for SSL certificate generation"
    bgd_log_error "Please provide either GoDaddy or Namecheap API credentials"
    bgd_log_error "For GoDaddy: --godaddy-api-key and --godaddy-api-secret"
    bgd_log_error "For Namecheap: --namecheap-api-key, --namecheap-api-user, and --namecheap-username"
    return 1
  fi
  
  # Check if we're in a CI environment
  local is_ci=false
  if bgd_is_ci_environment; then
    is_ci=true
    bgd_log_info "CI environment detected"
    
    # Skip if specified
    if [ "${SSL_SKIP_IF_CI:-true}" = "true" ]; then
      bgd_log_warning "Skipping SSL certificate generation in CI environment (--ssl-skip-if-ci=true)"
      return 0
    fi
  fi
  
  # Check required parameters
  if [ -z "$email" ]; then
    bgd_log_error "CERTBOT_EMAIL is required for SSL certificate generation"
    return 1
  fi
  
  # Install dependencies
  if [ "${SSL_AUTO_INSTALL_DEPS:-true}" = "true" ]; then
    bgd_install_ssl_dependencies || {
      bgd_log_error "Failed to install dependencies"
      return 1
    }
  fi
  
  # Create DNS provider credentials file
  bgd_create_dns_credentials || {
    bgd_log_error "Failed to create DNS credentials file"
    return 1
  }
  
  # Build Certbot command with DNS plugin
  local certbot_cmd="certbot certonly"
  
  if [ "$dns_provider" = "godaddy" ]; then
    certbot_cmd+=" --authenticator dns-godaddy"
    certbot_cmd+=" --dns-godaddy-credentials /etc/letsencrypt/godaddy/credentials.ini"
    certbot_cmd+=" --dns-godaddy-propagation-seconds $propagation_wait"
  elif [ "$dns_provider" = "namecheap" ]; then
    certbot_cmd+=" --authenticator dns-namecheap"
    certbot_cmd+=" --dns-namecheap-credentials /etc/letsencrypt/namecheap/credentials.ini"
    certbot_cmd+=" --dns-namecheap-propagation-seconds $propagation_wait"
  fi
  
  # Add domain
  certbot_cmd+=" -d ${domain}"
  
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
  eval "sudo $certbot_cmd" || {
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
  
  # Configure renewal
  if [ "$dns_provider" = "godaddy" ]; then
    sudo bash -c "echo 'authenticator = dns-godaddy' > /etc/letsencrypt/renewal/$domain.conf"
    sudo bash -c "echo 'dns_godaddy_credentials = /etc/letsencrypt/godaddy/credentials.ini' >> /etc/letsencrypt/renewal/$domain.conf"
  elif [ "$dns_provider" = "namecheap" ]; then
    sudo bash -c "echo 'authenticator = dns-namecheap' > /etc/letsencrypt/renewal/$domain.conf"
    sudo bash -c "echo 'dns_namecheap_credentials = /etc/letsencrypt/namecheap/credentials.ini' >> /etc/letsencrypt/renewal/$domain.conf"
  fi
  
  bgd_log_success "SSL certificates obtained successfully using $dns_provider DNS verification"
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

# Set up automatic renewal script
bgd_setup_auto_renewal() {
  local domain="${1:-$DOMAIN_NAME}"
  
  if [ "${SSL_AUTO_RENEWAL:-true}" = "true" ]; then
    bgd_log_info "Setting up automatic renewal for $domain SSL certificate"
    
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
    local dns_provider=$(bgd_get_dns_provider)
    
    # Only attempt SSL if DNS provider credentials are available
    if [ -n "$dns_provider" ]; then
      bgd_log_info "Setting up SSL for $domain using $dns_provider DNS verification"
      
      # Install required dependencies
      if [ "${SSL_AUTO_INSTALL_DEPS:-true}" = "true" ]; then
        bgd_install_ssl_dependencies || {
          bgd_log_error "Failed to install dependencies"
          bgd_log_warning "Continuing deployment without SSL"
          return 0
        }
      fi
      
      # Check if existing certificate needs reconfiguration
      if bgd_check_certificate_needs_reconfiguration "$domain"; then
        bgd_reconfigure_certificate "$domain" || {
          bgd_log_error "Failed to reconfigure certificate"
          bgd_log_warning "Will try obtaining a new certificate instead"
        }
      fi
      
      # Check if we still need to obtain a new certificate
      if ! bgd_check_certificates "$domain"; then
        # Obtain certificates
        bgd_obtain_ssl_certificates "$domain" || {
          bgd_log_error "Failed to obtain SSL certificates"
          bgd_log_warning "Continuing deployment without SSL"
        }
      fi
    else
      bgd_log_warning "DNS provider API credentials not provided, skipping SSL setup"
      bgd_log_warning "To enable SSL, provide one of the following:"
      bgd_log_warning "  GoDaddy: --godaddy-api-key and --godaddy-api-secret"
      bgd_log_warning "  Namecheap: --namecheap-api-key, --namecheap-api-user, and --namecheap-username"
    fi
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  if [ "${SSL_ENABLED:-true}" = "true" ] && bgd_has_dns_credentials; then
    local domain="${DOMAIN_NAME:-example.com}"
    
    # Set up Nginx with SSL if certificates exist
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
  
  if [ "${SSL_ENABLED:-true}" = "true" ] && bgd_has_dns_credentials; then
    local domain="${DOMAIN_NAME:-example.com}"
    
    # Ensure Nginx config is updated after cutover
    if bgd_check_certificates "$domain"; then
      bgd_log_info "Updating Nginx SSL configuration after cutover"
      bgd_setup_nginx_ssl "$domain"
    fi
  fi
  
  return 0
}