# Nginx Routing System Documentation

The Blue/Green Deployment toolkit includes a flexible routing system that supports multiple deployment architectures through the Nginx reverse proxy. This document explains how to use the routing system effectively.

## Routing Concepts

The routing system is designed to be fully architecture-agnostic and makes no assumptions about your application structure. It supports:

1. **Path-based routing**: Route different URL paths to different services
2. **Subdomain-based routing**: Route different subdomains to different services
3. **Mixed routing**: Use both path and subdomain routing simultaneously

## Configuration Parameters

Configure routing through the following command-line parameters:

### Basic Routing Parameters

- `--domain-name=DOMAIN`: The primary domain name for your application
- `--domain-aliases=LIST`: Additional domain aliases (comma-separated)
- `--paths=LIST`: Path:service:port mappings (comma-separated)
- `--subdomains=LIST`: Subdomain:service:port mappings (comma-separated)
- `--default-service=NAME`: Default service to route root traffic to (default: app)
- `--default-port=PORT`: Default port for the default service (default: 3000)

### Routing Format

Routing mappings use a simple format:

#### Path Format
```
path:service:port
```

- **path**: URL path (with or without leading slash)
- **service**: Container service name
- **port**: Internal port the service listens on

#### Subdomain Format
```
subdomain:service:port
```

- **subdomain**: Subdomain prefix
- **service**: Container service name
- **port**: Internal port the service listens on

## Examples

### Simple API Routing

```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=myorg/myapp \
  --paths="api:api-service:3000"
```

This routes:
- `/api/*` → api-service container on port 3000
- `/*` (all other paths) → default app service on port 3000

### Multi-Service Setup

```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=myorg/myapp \
  --paths="api:backend:3000,admin:admin-panel:4000" \
  --default-service=frontend --default-port=8080
```

This routes:
- `/api/*` → backend container on port 3000
- `/admin/*` → admin-panel container on port 4000
- `/*` (all other paths) → frontend container on port 8080

### Subdomain Routing

```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=myorg/myapp \
  --domain-name=example.com \
  --subdomains="api:api-service:3000,admin:admin-service:4000"
```

This routes:
- `api.example.com` → api-service container on port 3000
- `admin.example.com` → admin-service container on port 4000
- `example.com` → default app service on port 3000

### Combined Routing

```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=myorg/myapp \
  --domain-name=example.com \
  --paths="api:api-service:3000,docs:docs:8000" \
  --subdomains="admin:admin-panel:4000,staging:app:3000"
```

This complex setup routes:
- `example.com/api/*` → api-service container on port 3000
- `example.com/docs/*` → docs container on port 8000
- `admin.example.com` → admin-panel container on port 4000
- `staging.example.com` → app container on port 3000
- `example.com` (root) → default app service on port 3000

## How it Works

The routing system:

1. Processes path and subdomain mappings
2. Generates appropriate Nginx configuration based on the current deployment phase
   - During blue/green deployment: Creates weighted upstream blocks
   - After cutover: Creates direct routing to the active environment
3. Handles SSL configuration automatically when enabled

## Troubleshooting

If your routing isn't working as expected:

1. Check your path and subdomain mappings for syntax errors
2. Verify that service names match your docker-compose service names
3. Ensure your domain DNS records point to your server
4. Check Nginx logs: `docker logs myapp-nginx-blue`
5. Verify services are healthy: `./scripts/bgd-health-check.sh http://localhost:PORT/health`
```