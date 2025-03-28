#!/bin/bash
#
# master-proxy.sh - Initialize the master proxy system
#
# This script sets up the master proxy directory structure and starts the proxy.

set -euo pipefail

# Configuration
MASTER_PROXY_DIR="/app/master-proxy"
MASTER_PROXY_REGISTRY="${MASTER_PROXY_DIR}/app-registry.json"
MASTER_PROXY_CONTAINER="bgd-master-proxy"

# Create directory structure
echo "Creating master proxy directory structure..."
mkdir -p "${MASTER_PROXY_DIR}/certs"
mkdir -p "${MASTER_PROXY_DIR}/logs"

# Create initial registry
if [ ! -f "${MASTER_PROXY_REGISTRY}" ]; then
  echo "Creating initial application registry..."
  echo '{"applications":[]}' > "${MASTER_PROXY_REGISTRY}"
fi

# Create initial configuration
echo "Creating initial NGINX configuration..."
cat > "${MASTER_PROXY_DIR}/nginx.conf" << EOL
# Master NGINX configuration
# Initially created $(date)

worker_processes auto;
events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    sendfile        on;
    keepalive_timeout  65;
    
    access_log  /var/log/nginx/access.log;
    error_log   /var/log/nginx/error.log;
    
    # Default server
    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        
        server_name _;
        
        location / {
            return 404 "No application configured for this domain.\\n";
        }
    }
}
EOL

# Start the container
echo "Starting master proxy container..."
docker stop "${MASTER_PROXY_CONTAINER}" 2>/dev/null || true
docker rm "${MASTER_PROXY_CONTAINER}" 2>/dev/null || true

docker run -d --name "${MASTER_PROXY_CONTAINER}" \
  --restart unless-stopped \
  -p 80:80 -p 443:443 \
  -v "${MASTER_PROXY_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${MASTER_PROXY_DIR}/certs:/etc/nginx/certs:ro" \
  -v "${MASTER_PROXY_DIR}/logs:/var/log/nginx" \
  nginx:stable-alpine

echo "Master proxy initialized successfully!"
echo "You can now deploy applications with domain routing using your existing BGD toolkit."