#!/bin/bash
#
# bgd-master-proxy.sh - Master reverse proxy plugin for Blue/Green Deployment
#
# This plugin manages a top-level Nginx proxy for multiple applications:
# - Automatically routes traffic to applications based on domain name
# - Central SSL certificate management
# - Multiple applications under a single proxy

# Register plugin arguments
bgd_register_master_proxy_arguments() {
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_ENABLED" "false"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_NAME" "bgd-master-proxy"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_PORT" "80"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_SSL_PORT" "443"
  bgd_register_plugin_argument "master-proxy" "MASTER_PROXY_DIR" "./master-proxy"
  bgd_register_plugin_argument "master-proxy" "DEFAULT_APP" ""
  bgd_register_plugin_argument "master-proxy" "AUTO_REGISTER" "true"
  bgd_register_plugin_argument "master-proxy" "LETSENCRYPT_EMAIL" ""
}

# Initialize master proxy
bgd_init_master_proxy() {
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local proxy_dir="${MASTER_PROXY_DIR:-./master-proxy}"
  
  bgd_log "Initializing master proxy in $proxy_dir" "info"
  
  # Ensure master proxy directory exists
  bgd_ensure_directory "$proxy_dir"
  bgd_ensure_directory "$proxy_dir/config"
  bgd_ensure_directory "$proxy_dir/certs"
  bgd_ensure_directory "$proxy_dir/conf.d"
  bgd_ensure_directory "$proxy_dir/html"
  
  # Create default index and error pages
  cat > "$proxy_dir/html/index.html" << 'EOL'
<!DOCTYPE html>
<html>
<head>
  <title>Blue/Green Deployment Master Proxy</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
    h1 { color: #336699; }
    .container { max-width: 800px; margin: 0 auto; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Blue/Green Deployment Master Proxy</h1>
    <p>This is the default page for the master proxy. Configure applications to serve specific domains.</p>
  </div>
</body>
</html>
EOL

  cat > "$proxy_dir/html/404.html" << 'EOL'
<!DOCTYPE html>
<html>
<head>
  <title>404 - Not Found</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
    h1 { color: #cc3333; }
    .container { max-width: 800px; margin: 0 auto; }
  </style>
</head>
<body>
  <div class="container">
    <h1>404 - Not Found</h1>
    <p>The requested resource could not be found on this server.</p>
    <p><a href="/">Return to homepage</a></p>
  </div>
</body>
</html>
EOL

  cat > "$proxy_dir/html/50x.html" << 'EOL'
<!DOCTYPE html>
<html>
<head>
  <title>Server Error</title>
  <style>
    body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
    h1 { color: #cc3333; }
    .container { max-width: 800px; margin: 0 auto; }
  </style>
</head>
<body>
  <div class="container">
    <h1>Server Error</h1>
    <p>The server encountered an error and could not complete your request.</p>
    <p><a href="/">Return to homepage</a></p>
  </div>
</body>
</html>
EOL

  # Create the main nginx configuration file
  cat > "$proxy_dir/config/nginx.conf" << 'EOL'
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    multi_accept on;
    use epoll;
}

http {
    # Basic settings
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    
    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for" '
                    '$request_time $upstream_response_time $host';
    
    access_log /var/log/nginx/access.log main buffer=16k;
    error_log /var/log/nginx/error.log notice;
    
    # Optimized file delivery
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    
    # Security settings
    client_max_body_size 50M;
    client_body_buffer_size 128k;
    
    # Timeouts
    client_body_timeout 15s;
    client_header_timeout 15s;
    send_timeout 15s;
    
    # TLS settings
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # OCSP settings
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # Load application-specific configurations
    include /etc/nginx/conf.d/*.conf;
    
    # Default server - catches requests that don't match any server_name
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        listen 443 ssl default_server;
        listen [::]:443 ssl default_server;
        
        server_name _;
        
        # Default SSL certificates
        ssl_certificate /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        
        # Security headers
        add_header X-Content-Type-Options nosniff;
        add_header X-Frame-Options SAMEORIGIN;
        add_header X-XSS-Protection "1; mode=block";
        add_header Referrer-Policy strict-origin-when-cross-origin;
        
        # Default pages
        root /usr/share/nginx/html;
        
        location = /404.html {
            internal;
        }
        
        location = /50x.html {
            internal;
        }
        
        location / {
            try_files $uri $uri/ =404;
        }
        
        # Deny access to hidden files
        location ~ /\. {
            deny all;
            return 404;
        }
        
        # Error pages
        error_page 404 /404.html;
        error_page 500 502 503 504 /50x.html;
    }
}
EOL

  # Create docker-compose.yml for the master proxy
  cat > "$proxy_dir/docker-compose.yml" << 'EOL'
version: '3.8'

services:
  nginx:
    image: nginx:stable-alpine
    container_name: ${MASTER_PROXY_NAME}
    restart: unless-stopped
    ports:
      - "${MASTER_PROXY_PORT}:80"
      - "${MASTER_PROXY_SSL_PORT}:443"
    volumes:
      - ./config/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./certs:/etc/nginx/certs:ro
      - ./html:/usr/share/nginx/html:ro
      - ./logs:/var/log/nginx
    networks:
      - master-proxy-network
      - proxy-apps-network
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 10s
      timeout: 5s
      retries: 3

  certbot:
    image: certbot/certbot
    container_name: ${MASTER_PROXY_NAME}-certbot
    restart: unless-stopped
    volumes:
      - ./certs:/etc/letsencrypt
      - ./html:/var/www/html
    depends_on:
      - nginx
    entrypoint: /bin/sh -c "trap exit TERM; while :; do certbot renew --webroot -w /var/www/html --quiet; sleep 12h & wait $${!}; done"
    networks:
      - master-proxy-network

networks:
  master-proxy-network:
    name: ${MASTER_PROXY_NAME}-network
  proxy-apps-network:
    name: ${MASTER_PROXY_NAME}-apps-network
    external: true
EOL

  # Create environment file
  cat > "$proxy_dir/.env" << EOL
MASTER_PROXY_NAME=${MASTER_PROXY_NAME:-bgd-master-proxy}
MASTER_PROXY_PORT=${MASTER_PROXY_PORT:-80}
MASTER_PROXY_SSL_PORT=${MASTER_PROXY_SSL_PORT:-443}
EOL
  
  # Copy default SSL certificates if available, or create self-signed ones
  if [ -f "${SSL_CERT_PATH:-./certs}/fullchain.pem" ] && [ -f "${SSL_CERT_PATH:-./certs}/privkey.pem" ]; then
    bgd_log "Copying existing SSL certificates for master proxy" "info"
    cp "${SSL_CERT_PATH:-./certs}/fullchain.pem" "$proxy_dir/certs/"
    cp "${SSL_CERT_PATH:-./certs}/privkey.pem" "$proxy_dir/certs/"
  else
    bgd_log "Generating self-signed certificate for master proxy" "info"
    
    # Check if openssl is available
    if command -v openssl &> /dev/null; then
      openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$proxy_dir/certs/privkey.pem" \
        -out "$proxy_dir/certs/fullchain.pem" \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=localhost" \
        2>/dev/null
      
      chmod 600 "$proxy_dir/certs/privkey.pem"
    else
      bgd_log "OpenSSL not found, skipping self-signed certificate generation" "warning"
      
      # Create empty files so Docker doesn't complain
      touch "$proxy_dir/certs/fullchain.pem"
      touch "$proxy_dir/certs/privkey.pem"
    fi
  fi
  
  # Create default application configuration
  if [ -n "${DEFAULT_APP:-}" ]; then
    bgd_log "Configuring default app: $DEFAULT_APP" "info"
    bgd_register_app_with_master_proxy "$DEFAULT_APP" "localhost" "default"
  fi
  
  bgd_log "Master proxy initialized at $proxy_dir" "success"
  return 0
}

# Register an application with the master proxy
bgd_register_app_with_master_proxy() {
  local app_name="$1"
  local domain_name="$2"
  local is_default="${3:-false}"
  
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local proxy_dir="${MASTER_PROXY_DIR:-./master-proxy}"
  local active_env=""
  local backend_port=""
  
  bgd_log "Registering $app_name with domain $domain_name to master proxy" "info"
  
  # Determine active environment and port
  read active_env inactive_env <<< $(bgd_get_environments)
  
  if [ "$active_env" = "blue" ]; then
    backend_port="${BLUE_PORT:-8081}"
  elif [ "$active_env" = "green" ]; then
    backend_port="${GREEN_PORT:-8082}"
  else
    backend_port="${DEFAULT_PORT:-3000}"
  fi
  
  # Create configuration file
  local conf_file="$proxy_dir/conf.d/${app_name}.conf"
  local default_server=""
  
  # Add default_server if this is the default application
  if [ "$is_default" = "default" ]; then
    default_server=" default_server"
  fi
  
  # Create conf.d directory if it doesn't exist
  bgd_ensure_directory "$proxy_dir/conf.d"
  
  # Generate the configuration
  cat > "$conf_file" << EOL
# Application: $app_name
# Domain: $domain_name
# Generated: $(date)

server {
    listen 80$default_server;
    listen [::]:80$default_server;
    
    server_name $domain_name;
    
    # Redirect to HTTPS if certificates exist
    if (\$scheme = http) {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2$default_server;
    listen [::]:443 ssl http2$default_server;
    
    server_name $domain_name;
    
    # SSL configuration
    ssl_certificate /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    
    # Security headers
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy strict-origin-when-cross-origin;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    
    # Proxy to backend application
    location / {
        proxy_pass http://${app_name}-${active_env}:$backend_port;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_cache_bypass \$http_upgrade;
        
        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
    
    # Deny access to hidden files
    location ~ /\. {
        deny all;
        return 404;
    }
    
    # Error pages
    error_page 404 /404.html;
    error_page 500 502 503 504 /50x.html;
}
EOL
  
  bgd_log "Application $app_name registered with master proxy" "success"
  
  # Reload master proxy if running
  if docker ps | grep -q "${MASTER_PROXY_NAME:-bgd-master-proxy}"; then
    bgd_log "Reloading master proxy configuration" "info"
    docker exec "${MASTER_PROXY_NAME:-bgd-master-proxy}" nginx -s reload || {
      bgd_log "Failed to reload master proxy, trying restart" "warning"
      docker restart "${MASTER_PROXY_NAME:-bgd-master-proxy}" || {
        bgd_log "Failed to restart master proxy" "error"
        return 1
      }
    }
  fi
  
  return 0
}

# Start master proxy
bgd_start_master_proxy() {
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local proxy_dir="${MASTER_PROXY_DIR:-./master-proxy}"
  
  bgd_log "Starting master proxy..." "info"
  
  # Check if master proxy is initialized
  if [ ! -f "$proxy_dir/docker-compose.yml" ]; then
    bgd_log "Master proxy not initialized, initializing now" "info"
    bgd_init_master_proxy
  fi
  
  # Check if the proxy is already running
  if docker ps | grep -q "${MASTER_PROXY_NAME:-bgd-master-proxy}"; then
    bgd_log "Master proxy is already running" "info"
    return 0
  fi
  
  # Start the master proxy
  (
    cd "$proxy_dir" || return 1
    docker-compose up -d
  ) || {
    bgd_log "Failed to start master proxy" "error"
    return 1
  }
  
  bgd_log "Master proxy started successfully" "success"
  return 0
}

# Stop master proxy
bgd_stop_master_proxy() {
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  local proxy_dir="${MASTER_PROXY_DIR:-./master-proxy}"
  
  bgd_log "Stopping master proxy..." "info"
  
  # Check if the proxy is running
  if ! docker ps | grep -q "${MASTER_PROXY_NAME:-bgd-master-proxy}"; then
    bgd_log "Master proxy is not running" "info"
    return 0
  fi
  
  # Stop the master proxy
  (
    cd "$proxy_dir" || return 1
    docker-compose down
  ) || {
    bgd_log "Failed to stop master proxy" "error"
    return 1
  }
  
  bgd_log "Master proxy stopped successfully" "success"
  return 0
}

# Update application in master proxy after deployment
bgd_update_proxy_for_app() {
  local app_name="$1"
  local domain_name="${DOMAIN_NAME:-localhost}"
  
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ] || [ "${AUTO_REGISTER:-true}" != "true" ]; then
    return 0
  fi
  
  bgd_register_app_with_master_proxy "$app_name" "$domain_name"
  return $?
}

# Update proxy after cutover to reflect new active environment
bgd_update_proxy_after_cutover() {
  local app_name="$1"
  local target_env="$2"
  local domain_name="${DOMAIN_NAME:-localhost}"
  
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  bgd_log "Updating master proxy after cutover to $target_env" "info"
  bgd_register_app_with_master_proxy "$app_name" "$domain_name"
  
  return $?
}

# Request Let's Encrypt certificate for a domain
bgd_request_letsencrypt_cert() {
  local domain="$1"
  local email="${LETSENCRYPT_EMAIL:-}"
  
  if [ "${MASTER_PROXY_ENABLED:-false}" != "true" ]; then
    return 0
  fi
  
  if [ -z "$email" ]; then
    bgd_log "LETSENCRYPT_EMAIL is required for certificate requests" "error"
    return 1
  fi
  
  bgd_log "Requesting Let's Encrypt certificate for $domain" "info"
  
  local proxy_dir="${MASTER_PROXY_DIR:-./master-proxy}"
  local certbot_container="${MASTER_PROXY_NAME:-bgd-master-proxy}-certbot"
  
  # Check if certbot container is running
  if ! docker ps | grep -q "$certbot_container"; then
    bgd_log "Certbot container not running, starting master proxy first" "info"
    bgd_start_master_proxy
  fi
  
  # Run certbot
  docker exec "$certbot_container" certbot certonly --webroot \
    -w /var/www/html \
    -d "$domain" \
    --email "$email" \
    --agree-tos \
    --non-interactive \
    --expand
  
  local status=$?
  if [ $status -eq 0 ]; then
    bgd_log "Successfully obtained SSL certificate for $domain" "success"
    
    # Copy certificates to the right location
    docker exec "$certbot_container" cp /etc/letsencrypt/live/$domain/fullchain.pem /etc/letsencrypt/fullchain.pem
    docker exec "$certbot_container" cp /etc/letsencrypt/live/$domain/privkey.pem /etc/letsencrypt/privkey.pem
    
    # Reload nginx
    docker exec "${MASTER_PROXY_NAME:-bgd-master-proxy}" nginx -s reload
  else
    bgd_log "Failed to obtain SSL certificate for $domain" "error"
  fi
  
  return $status
}

# Plugin hooks
bgd_hook_pre_deploy() {
  local version="$1"
  local app_name="$2"
  
  # Ensure master proxy is initialized and running
  if [ "${MASTER_PROXY_ENABLED:-false}" = "true" ]; then
    bgd_init_master_proxy
    bgd_start_master_proxy
  fi
  
  return 0
}

bgd_hook_post_deploy() {
  local version="$1"
  local env_name="$2"
  
  # Register app with master proxy if applicable
  if [ "${MASTER_PROXY_ENABLED:-false}" = "true" ] && [ "${AUTO_REGISTER:-true}" = "true" ]; then
    bgd_update_proxy_for_app "${APP_NAME}"
  fi
  
  return 0
}

bgd_hook_post_cutover() {
  local target_env="$1"
  
  # Update proxy configuration after cutover
  if [ "${MASTER_PROXY_ENABLED:-false}" = "true" ]; then
    bgd_update_proxy_after_cutover "${APP_NAME}" "$target_env"
  fi
  
  return 0
}