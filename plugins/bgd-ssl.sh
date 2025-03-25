#!/bin/bash
# Blue-Green Deployment SSL certificate management module

# Function to check if certificate exists and is valid
bgd_check_certificate() {
  local domain=$1
  local renewal_days=${2:-30}
  local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"
  
  if [ -f "$cert_path" ]; then
    echo "[INFO] Certificate exists for $domain, checking validity..."
    
    # Get certificate expiry date in seconds since epoch
    local expiry_date=$(date -d "$(openssl x509 -enddate -noout -in "$cert_path" | cut -d= -f2)" +%s)
    local current_date=$(date +%s)
    local seconds_until_expiry=$((expiry_date - current_date))
    local days_until_expiry=$((seconds_until_expiry / 86400))
    
    echo "[INFO] Certificate for $domain expires in $days_until_expiry days"
    
    if [ $days_until_expiry -le $renewal_days ]; then
      echo "[INFO] Certificate will expire soon ($days_until_expiry days), renewal needed"
      return 1  # Renewal needed
    else
      echo "[INFO] Certificate is still valid for $days_until_expiry days, no renewal needed"
      return 0  # No renewal needed
    fi
  else
    echo "[INFO] No existing certificate found for $domain, obtaining new one..."
    return 1  # Obtain new certificate
  fi
}

# Function to reload Nginx in a container-aware manner
bgd_reload_nginx() {
  local app_name=$1
  local environment=${2:-blue}
  
  echo "[INFO] Reloading Nginx to apply certificate changes..."
  
  # Check for specific container first
  if docker ps --format '{{.Names}}' | grep -q "${app_name}-${environment}-nginx"; then
    local nginx_container=$(docker ps --format '{{.Names}}' | grep "${app_name}-${environment}-nginx" | head -n1)
    echo "[INFO] Reloading Nginx in container: $nginx_container"
    docker exec $nginx_container nginx -s reload
    return $?
  # Then check for standard nginx container
  elif docker ps | grep -q nginx; then
    local nginx_container=$(docker ps | grep nginx | awk '{print $1}' | head -n1)
    echo "[INFO] Reloading Nginx in container: $nginx_container"
    docker exec $nginx_container nginx -s reload
    return $?
  # Finally try systemd
  elif command -v systemctl &> /dev/null && systemctl is-active nginx &> /dev/null; then
    echo "[INFO] Reloading Nginx using systemctl"
    sudo systemctl reload nginx
    return $?
  else
    echo "[WARN] No method found to reload Nginx"
    return 1
  fi
}

# Function to generate Diffie-Hellman parameters
bgd_generate_dhparam() {
  local dhparam_dir="/etc/nginx/certs"
  local dhparam_file="$dhparam_dir/dhparam.pem"
  local dhparam_bits=2048

  echo "===== GENERATING STRONG DH PARAMETERS ====="
  echo "This may take a few minutes..."

  # Create directory if it doesn't exist
  if [ ! -d "$dhparam_dir" ]; then
    echo "Creating certificates directory"
    mkdir -p "$dhparam_dir"
  fi

  # Check if file already exists
  if [ -f "$dhparam_file" ]; then
    echo "DH parameters file already exists at $dhparam_file"
    echo "Delete file manually if you want to regenerate it"
  else
    # Generate DH parameters
    openssl dhparam -out "$dhparam_file" $dhparam_bits
    
    # Set secure permissions
    chmod 644 "$dhparam_file"
    
    echo "DH parameters generated successfully"
  fi

  echo "===== DH PARAMETERS SETUP COMPLETE ====="
}

# Main function to obtain/renew SSL certificates
bgd_manage_ssl() {
  local domain=$1
  local email=$2
  local webroot=${3:-"/var/www/html"}
  local renewal_days=${4:-30}
  local force=${5:-false}
  
  # Ensure we have required parameters
  if [ -z "$domain" ] || [ -z "$email" ]; then
    echo "[ERROR] Domain and email are required for SSL certificate management"
    return 1
  fi
  
  echo "[INFO] Managing SSL certificates for $domain"
  
  # Ensure Certbot is installed
  if ! command -v certbot &> /dev/null; then
    echo "[INFO] Certbot not found, installing..."
    sudo apt-get update
    sudo apt-get install -y certbot
  fi
  
  # Check if we need to get/renew a certificate
  if [ "$force" = true ] || ! bgd_check_certificate "$domain" "$renewal_days"; then
    echo "[INFO] Obtaining/renewing certificate for $domain..."
    
    # Create webroot directory if it doesn't exist
    if [ ! -d "$webroot" ]; then
      echo "[INFO] Creating webroot directory: $webroot"
      mkdir -p "$webroot"
    fi
    
    # Set up acme-challenge directory
    local acme_dir="$webroot/.well-known/acme-challenge"
    mkdir -p "$acme_dir"
    
    # Make webroot accessible
    chmod -R 755 "$webroot"
    
    # Obtain/renew certificate
    sudo certbot certonly --webroot -w "$webroot" -d "$domain" --email "$email" \
      --agree-tos --non-interactive --keep-until-expiring --expand
    
    local cert_result=$?
    if [ $cert_result -ne 0 ]; then
      echo "[ERROR] Failed to obtain/renew certificate for $domain"
      return 1
    fi
    
    echo "[INFO] Certificate successfully obtained/renewed for $domain"
  else
    echo "[INFO] Certificate for $domain is still valid, no action required"
  fi

  # Generate DH parameters if not already present
  bgd_generate_dhparam

  # Reload Nginx to apply the new certificates
  bgd_reload_nginx "$APP_NAME" "$ENV_NAME"
}

# Export functions for use in other scripts
export -f bgd_check_certificate
export -f bgd_reload_nginx
export -f bgd_generate_dhparam
export -f bgd_manage_ssl
