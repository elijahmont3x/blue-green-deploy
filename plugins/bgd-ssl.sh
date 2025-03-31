#!/bin/bash
#
# bgd-ssl.sh - SSL Certificate Management for Blue/Green Deployment
#
# This plugin manages SSL certificates for domains:
# - Let's Encrypt integration
# - Certificate renewal
# - Self-signed certificate generation

# Register plugin arguments
bgd_register_ssl_arguments() {
  bgd_register_plugin_argument "ssl" "SSL_ENABLED" "false"
  bgd_register_plugin_argument "ssl" "SSL_PROVIDER" "letsencrypt"
  bgd_register_plugin_argument "ssl" "CERTBOT_EMAIL" ""
  bgd_register_plugin_argument "ssl" "CERT_PATH" "./certs"
  bgd_register_plugin_argument "ssl" "AUTO_RENEWAL" "true"
  bgd_register_plugin_argument "ssl" "RENEWAL_PERIOD" "60d"
  bgd_register_plugin_argument "ssl" "SSL_STAGING" "false"
  bgd_register_plugin_argument "ssl" "SSL_DOMAINS" ""
}

# Initialize SSL system
bgd_init_ssl() {
  if [ "${SSL_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  bgd_log "Initializing SSL certificate system" "info"
  
  local cert_path="${CERT_PATH:-./certs}"
  
  # Create certificate directory if it doesn't exist
  bgd_ensure_directory "$cert_path"
  
  # Set secure permissions
  chmod 700 "$cert_path" 2>/dev/null || true
  
  bgd_log "SSL certificate system initialized" "success"
  return 0
}

# Generate self-signed certificate
bgd_generate_self_signed_cert() {
  local domain="$1"
  local cert_path="${CERT_PATH:-./certs}"
  
  bgd_log "Generating self-signed certificate for $domain" "info"
  
  # Create certificate directory
  bgd_ensure_directory "$cert_path"
  
  # Check if OpenSSL is available
  if ! command -v openssl &> /dev/null; then
    bgd_log "OpenSSL not found, cannot generate self-signed certificate" "error"
    return 1
  fi
  
  # Set file paths
  local key_file="$cert_path/privkey.pem"
  local cert_file="$cert_path/fullchain.pem"
  
  # Generate a self-signed certificate
  bgd_log "Generating certificate files: $key_file and $cert_file" "debug"
  
  # Generate private key
  openssl genrsa -out "$key_file" 2048 2>/dev/null || {
    bgd_log "Failed to generate private key" "error"
    return 1
  }
  
  # Set secure permissions for the key
  chmod 600 "$key_file" || {
    bgd_log "Failed to set secure permissions on key file" "warning"
  }
  
  # Create CSR config
  local tmp_cnf=$(mktemp)
  cat > "$tmp_cnf" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
CN = $domain

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = $domain
DNS.2 = www.$domain
EOF

  # Generate certificate
  openssl req -new -key "$key_file" -out "$cert_path/csr.pem" -config "$tmp_cnf" 2>/dev/null || {
    bgd_log "Failed to generate CSR" "error"
    rm -f "$tmp_cnf"
    return 1
  }
  
  openssl x509 -req -days 365 -in "$cert_path/csr.pem" -signkey "$key_file" -out "$cert_file" \
    -extensions req_ext -extfile "$tmp_cnf" 2>/dev/null || {
    bgd_log "Failed to generate certificate" "error"
    rm -f "$tmp_cnf" "$cert_path/csr.pem" 
    return 1
  }
  
  # Clean up temporary files
  rm -f "$tmp_cnf" "$cert_path/csr.pem"
  
  bgd_log "Self-signed certificate generated successfully" "success"
  return 0
}

# Obtain Let's Encrypt certificate
bgd_obtain_letsencrypt_cert() {
  local domain="$1"
  local email="${CERTBOT_EMAIL:-}"
  local staging="${SSL_STAGING:-false}"
  local cert_path="${CERT_PATH:-./certs}"
  
  if [ -z "$email" ]; then
    bgd_log "Email address is required for Let's Encrypt certificates" "error"
    return 1
  fi
  
  bgd_log "Obtaining Let's Encrypt certificate for $domain" "info"
  
  # Check if certbot is available
  if ! command -v certbot &> /dev/null; then
    bgd_log "Certbot not found, attempting to use Docker" "warning"
    
    # Try to use certbot via Docker
    if ! command -v docker &> /dev/null; then
      bgd_log "Docker not found, cannot obtain Let's Encrypt certificate" "error"
      return 1
    fi
    
    # Create webroot directory for verification
    local webroot_dir="$(pwd)/certbot-webroot"
    bgd_ensure_directory "$webroot_dir"
    bgd_ensure_directory "$webroot_dir/.well-known"
    bgd_ensure_directory "$webroot_dir/.well-known/acme-challenge"
    
    # Create certificate directory
    bgd_ensure_directory "$cert_path"
    
    # Build certbot command
    local certbot_cmd="docker run --rm -v \"$cert_path:/etc/letsencrypt\" -v \"$webroot_dir:/webroot\" certbot/certbot certonly --webroot -w /webroot"
    certbot_cmd+=" -d $domain -m $email --agree-tos --non-interactive"
    
    # Add staging flag if requested
    if [ "$staging" = "true" ]; then
      certbot_cmd+=" --staging"
    fi
    
    # Run certbot
    bgd_log "Running certbot: $certbot_cmd" "debug"
    eval "$certbot_cmd" || {
      bgd_log "Failed to obtain Let's Encrypt certificate using Docker" "error"
      return 1
    }
    
    # Copy certificates to standard location
    cp "$cert_path/live/$domain/privkey.pem" "$cert_path/privkey.pem" || {
      bgd_log "Failed to copy privkey.pem to standard location" "error"
      return 1
    }
    
    cp "$cert_path/live/$domain/fullchain.pem" "$cert_path/fullchain.pem" || {
      bgd_log "Failed to copy fullchain.pem to standard location" "error"
      return 1
    }
  else
    # Create webroot directory for verification
    local webroot_dir="$(pwd)/certbot-webroot"
    bgd_ensure_directory "$webroot_dir"
    bgd_ensure_directory "$webroot_dir/.well-known"
    bgd_ensure_directory "$webroot_dir/.well-known/acme-challenge"
    
    # Create certificate directory
    bgd_ensure_directory "$cert_path"
    
    # Build certbot command
    local certbot_cmd="certbot certonly --webroot -w \"$webroot_dir\""
    certbot_cmd+=" -d $domain -m $email --agree-tos --non-interactive"
    
    # Add staging flag if requested
    if [ "$staging" = "true" ]; then
      certbot_cmd+=" --staging"
    fi
    
    # Run certbot
    bgd_log "Running certbot: $certbot_cmd" "debug"
    eval "$certbot_cmd" || {
      bgd_log "Failed to obtain Let's Encrypt certificate" "error"
      return 1
    }
    
    # Copy certificates to standard location
    cp "/etc/letsencrypt/live/$domain/privkey.pem" "$cert_path/privkey.pem" || {
      bgd_log "Failed to copy privkey.pem to standard location" "error"
      return 1
    }
    
    cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$cert_path/fullchain.pem" || {
      bgd_log "Failed to copy fullchain.pem to standard location" "error"
      return 1
    }
  fi
  
  # Set secure permissions
  chmod 600 "$cert_path/privkey.pem" 2>/dev/null || true
  chmod 644 "$cert_path/fullchain.pem" 2>/dev/null || true
  
  bgd_log "Let's Encrypt certificate obtained successfully" "success"
  return 0
}

# Renew Let's Encrypt certificate
bgd_renew_letsencrypt_cert() {
  local domain="$1"
  local cert_path="${CERT_PATH:-./certs}"
  
  bgd_log "Renewing Let's Encrypt certificate for $domain" "info"
  
  # Check if certbot is available
  if ! command -v certbot &> /dev/null; then
    bgd_log "Certbot not found, attempting to use Docker" "warning"
    
    # Try to use certbot via Docker
    if ! command -v docker &> /dev/null; then
      bgd_log "Docker not found, cannot renew Let's Encrypt certificate" "error"
      return 1
    fi
    
    # Create webroot directory for verification
    local webroot_dir="$(pwd)/certbot-webroot"
    bgd_ensure_directory "$webroot_dir"
    bgd_ensure_directory "$webroot_dir/.well-known"
    bgd_ensure_directory "$webroot_dir/.well-known/acme-challenge"
    
    # Run certbot
    docker run --rm -v "$cert_path:/etc/letsencrypt" -v "$webroot_dir:/webroot" \
      certbot/certbot renew --webroot -w /webroot --non-interactive || {
      bgd_log "Failed to renew Let's Encrypt certificate using Docker" "error"
      return 1
    }
    
    # Copy certificates to standard location
    docker run --rm -v "$cert_path:/etc/letsencrypt" --entrypoint cp \
      certbot/certbot /etc/letsencrypt/live/$domain/privkey.pem /etc/letsencrypt/privkey.pem || {
      bgd_log "Failed to copy privkey.pem to standard location" "error"
      return 1
    }
    
    docker run --rm -v "$cert_path:/etc/letsencrypt" --entrypoint cp \
      certbot/certbot /etc/letsencrypt/live/$domain/fullchain.pem /etc/letsencrypt/fullchain.pem || {
      bgd_log "Failed to copy fullchain.pem to standard location" "error"
      return 1
    }
  else
    # Create webroot directory for verification
    local webroot_dir="$(pwd)/certbot-webroot"
    bgd_ensure_directory "$webroot_dir"
    bgd_ensure_directory "$webroot_dir/.well-known"
    bgd_ensure_directory "$webroot_dir/.well-known/acme-challenge"
    
    # Run certbot
    certbot renew --webroot -w "$webroot_dir" --non-interactive || {
      bgd_log "Failed to renew Let's Encrypt certificate" "error"
      return 1
    }
    
    # Copy certificates to standard location
    cp "/etc/letsencrypt/live/$domain/privkey.pem" "$cert_path/privkey.pem" || {
      bgd_log "Failed to copy privkey.pem to standard location" "error"
      return 1
    }
    
    cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$cert_path/fullchain.pem" || {
      bgd_log "Failed to copy fullchain.pem to standard location" "error"
      return 1
    }
  fi
  
  # Set secure permissions
  chmod 600 "$cert_path/privkey.pem" 2>/dev/null || true
  chmod 644 "$cert_path/fullchain.pem" 2>/dev/null || true
  
  bgd_log "Let's Encrypt certificate renewed successfully" "success"
  return 0
}

# Check if certificate exists
bgd_check_certificate() {
  local domain="$1"
  local cert_path="${CERT_PATH:-./certs}"
  
  if [ ! -f "$cert_path/privkey.pem" ] || [ ! -f "$cert_path/fullchain.pem" ]; then
    return 1
  fi
  
  return 0
}

# Check if certificate needs renewal
bgd_needs_renewal() {
  local domain="$1"
  local cert_path="${CERT_PATH:-./certs}"
  
  # Check if certificate exists
  if ! bgd_check_certificate "$domain"; then
    return 0  # Certificate doesn't exist, needs issuance
  fi
  
  # Check certificate expiration date
  if ! command -v openssl &> /dev/null; then
    bgd_log "OpenSSL not found, assuming certificate needs renewal" "warning"
    return 0
  fi
  
  # Get expiration date in seconds since epoch
  local expiry_date=$(openssl x509 -noout -enddate -in "$cert_path/fullchain.pem" | sed -e 's/^notAfter=//')
  local expiry_seconds=$(date -d "$expiry_date" +%s)
  local current_seconds=$(date +%s)
  
  # Calculate seconds until expiry
  local seconds_until_expiry=$((expiry_seconds - current_seconds))
  
  # Renew if less than 30 days until expiry (2592000 seconds)
  if [ "$seconds_until_expiry" -lt 2592000 ]; then
    return 0  # Needs renewal
  fi
  
  return 1  # Doesn't need renewal
}

# Main SSL certificate management function
bgd_obtain_ssl_certificates() {
  local domain="$1"
  
  if [ "${SSL_ENABLED:-false}" != "true" ]; then
    bgd_log "SSL is not enabled" "info"
    return 0
  fi
  
  if [ -z "$domain" ]; then
    bgd_log "Domain name not specified" "error"
    return 1
  fi
  
  # Initialize SSL system
  bgd_init_ssl
  
  # Check if certificate exists and needs renewal
  if bgd_check_certificate "$domain" && ! bgd_needs_renewal "$domain"; then
    bgd_log "SSL certificate for $domain exists and is valid" "success"
    return 0
  fi
  
  # Determine SSL provider
  local provider="${SSL_PROVIDER:-letsencrypt}"
  
  case "$provider" in
    letsencrypt)
      # Obtain or renew Let's Encrypt certificate
      if bgd_check_certificate "$domain"; then
        bgd_renew_letsencrypt_cert "$domain"
      else
        bgd_obtain_letsencrypt_cert "$domain"
      fi
      ;;
    
    self-signed)
      # Generate self-signed certificate
      bgd_generate_self_signed_cert "$domain"
      ;;
    
    *)
      bgd_log "Unknown SSL provider: $provider" "error"
      return 1
      ;;
  esac
  
  return $?
}

# Plugin hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  if [ "${SSL_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  # Check if domain is set
  if [ -z "${DOMAIN_NAME:-}" ]; then
    bgd_log "Domain name not set, skipping SSL certificate management" "warning"
    return 0
  fi
  
  # Check and obtain/renew SSL certificates
  bgd_obtain_ssl_certificates "$DOMAIN_NAME"
  
  return $?
}