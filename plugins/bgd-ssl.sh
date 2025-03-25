#!/bin/bash
#
# bgd-ssl.sh - SSL certificate management plugin for Blue/Green Deployment
#
# This plugin handles SSL certificate management:
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
  bgd_register_plugin_argument "ssl" "SSL_DNS_PLUGIN" ""
  bgd_register_plugin_argument "ssl" "SSL_DNS_CREDENTIALS" ""
  bgd_register_plugin_argument "ssl" "SSL_DNS_PROPAGATION_WAIT" "60"
  bgd_register_plugin_argument "ssl" "SSL_SKIP_IF_CI" "true"
}

# Check if this is a CI environment
bgd_is_ci_environment() {
  # Check common CI environment variables
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ] || [ -n "${JENKINS_URL:-}" ] || [ -n "${TRAVIS:-}" ] || [ -n "${CIRCLECI:-}" ]; then
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

# Create a temporary Nginx config for ACME challenges
# Note: Kept for backward compatibility with HTTP validation if needed
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

# Obtain SSL certificates using Certbot with DNS verification
bgd_obtain_ssl_certificates() {
  local domain="${1:-$DOMAIN_NAME}"
  local email="${CERTBOT_EMAIL}"
  local staging="${CERTBOT_STAGING:-false}"
  local cert_path="${SSL_CERT_PATH:-./certs}"
  local dns_plugin="${SSL_DNS_PLUGIN:-}"
  local dns_credentials="${SSL_DNS_CREDENTIALS:-}"
  local propagation_wait="${SSL_DNS_PROPAGATION_WAIT:-60}"
  
  bgd_log_info "Obtaining SSL certificates for $domain using DNS verification"
  
  # Check if we're in a CI environment
  local is_ci=false
  if bgd_is_ci_environment; then
    is_ci=true
    bgd_log_info "CI environment detected"
    
    # Check if we should skip SSL in CI
    if [ "${SSL_SKIP_IF_CI:-true}" = "true" ] && [ -z "$dns_plugin" ]; then
      bgd_log_warning "Skipping SSL certificate generation in CI environment since no DNS plugin specified"
      bgd_log_warning "To enable SSL in CI, set --ssl-dns-plugin and --ssl-dns-credentials"
      return 0
    fi
  fi
  
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

  # Build Certbot command with DNS challenge
  local certbot_cmd="certbot certonly"
  
  # Determine if we can use interactive mode
  if [ "$is_ci" = "false" ] && [ -t 0 ] && [ -z "$dns_plugin" ]; then
    # Interactive mode with manual DNS challenge
    certbot_cmd+=" --manual --preferred-challenges dns"
    
    bgd_log_info "Interactive terminal detected. Will use manual DNS challenge."
    bgd_log_info "You will be prompted to create DNS TXT records."
    
    # Display guidance for interactive DNS verification
    echo "============================================================"
    echo "                DNS VERIFICATION INSTRUCTIONS                "
    echo "============================================================"
    echo "You will be prompted to create DNS TXT records for domain verification."
    echo ""
    echo "For each domain, you will need to:"
    echo "1. Create a TXT record with the provided name and value"
    echo "2. Wait for DNS propagation (can take 5-30 minutes)"
    echo "3. Confirm when the record is set by pressing Enter"
    echo ""
    echo "Tips for DNS record creation:"
    echo "- The record name will be '_acme-challenge.<your-domain>'"
    echo "- If your DNS provider requires just the subdomain part,"
    echo "  enter only '_acme-challenge' without your domain"
    echo "- Wait at least 5 minutes for DNS propagation before continuing"
    echo "- You can verify record propagation using: "
    echo "  dig txt _acme-challenge.<your-domain>"
    echo ""
    echo "Example TXT record for $domain:"
    echo "  Name:  _acme-challenge.$domain  (or just _acme-challenge)"
    echo "  Type:  TXT"
    echo "  Value: [certbot will provide this value]"
    echo "  TTL:   300 (or lowest available)"
    echo "============================================================"
    echo ""
  elif [ -n "$dns_plugin" ]; then
    # Non-interactive mode with DNS plugin
    certbot_cmd+=" --authenticator $dns_plugin"
    
    if [ -n "$dns_credentials" ]; then
      certbot_cmd+=" --$dns_plugin-credentials $dns_credentials"
    fi
    
    # Add propagation-seconds if provided
    certbot_cmd+=" --dns-${dns_plugin}-propagation-seconds $propagation_wait"
    
    bgd_log_info "Using DNS plugin: $dns_plugin for automated verification"
  else
    # Cannot proceed in non-interactive mode without a DNS plugin
    bgd_log_error "Cannot obtain SSL certificates in non-interactive environment without a DNS plugin"
    bgd_log_error "Please specify --ssl-dns-plugin and --ssl-dns-credentials for automated environments"
    bgd_log_error "Example providers: dns-cloudflare, dns-route53, dns-digitalocean"
    
    if [ "$is_ci" = "true" ]; then
      bgd_log_error "CI environment detected. SSL certificate generation requires DNS plugin configuration."
      bgd_log_error "If you wish to skip SSL in CI, set --ssl-skip-if-ci=true (default)"
    fi
    
    return 1
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
  certbot_cmd+=" --email $email --agree-tos"
  
  # Add non-interactive flag for non-interactive environments
  if [ "$is_ci" = "true" ] || [ ! -t 0 ] || [ -n "$dns_plugin" ]; then
    certbot_cmd+=" --non-interactive"
  fi
  
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
  local dns_plugin="${SSL_DNS_PLUGIN:-}"
  local dns_credentials="${SSL_DNS_CREDENTIALS:-}"
  
  if [ "${SSL_AUTO_RENEWAL:-true}" = "true" ]; then
    bgd_log_info "Setting up automatic renewal for $domain SSL certificate"
    
    # Create renewal script
    cat > renew-ssl.sh << 'EOL'
#!/bin/bash
# Renew SSL certificates using the same method as initial issuance
certbot renew
# Check if renewal was successful
if [ $? -eq 0 ]; then
  # Copy certificates to our cert path
  cp /etc/letsencrypt/live/DOMAIN_NAME/fullchain.pem CERT_PATH/fullchain.pem
  cp /etc/letsencrypt/live/DOMAIN_NAME/privkey.pem CERT_PATH/privkey.pem
  chmod 644 CERT_PATH/fullchain.pem
  chmod 644 CERT_PATH/privkey.pem
  
  # Restart nginx to apply new certificates
  docker compose restart nginx || docker-compose restart nginx
  echo "$(date) - Successfully renewed certificates and restarted nginx" >> CERT_PATH/renewal.log
else
  echo "$(date) - Certificate renewal failed" >> CERT_PATH/renewal.log
fi
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
      # Obtain certificates directly via DNS verification
      # No need to set up ACME challenge for HTTP validation
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