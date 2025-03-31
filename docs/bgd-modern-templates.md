# Blue/Green Deployment Modern Templates

This document describes the template system used in the Blue/Green Deployment toolkit to dynamically generate configuration files.

## Overview

The BGD system uses a lightweight, powerful templating engine to generate Nginx configurations, Docker Compose files, and other configuration files. Templates allow for dynamic content generation with variable substitution, conditional sections, and includes.

## Template Features

- **Variable substitution**: Use `{{VARIABLE}}` syntax to insert values
- **Conditional sections**: Include/exclude blocks with `{{#VARIABLE}}...{{/VARIABLE}}`
- **Inverse conditionals**: Use `{{^VARIABLE}}...{{/VARIABLE}}` for negative conditions
- **Partials/includes**: Include other templates with `{{#include:name}}`
- **Environment-specific values**: Apply different values based on environment

## Template Locations

Templates are stored in the following locations:

## Template Syntax

### Variable Substitution

Variables in templates are surrounded by double curly braces:
```bash
{{ variable_name }}
```

### Conditional Blocks

Conditional blocks allow sections of the template to be included or excluded based on the value of a variable:
```bash
{% if condition %}
# Content included if condition is true
{% endif %}
```

### Inverted Conditional Blocks

Inverted conditional blocks include content when the condition is false:
```bash
{% if not condition %}
# Content included if condition is false
{% endif %}
```

### Reusable Partials

Partials are reusable template fragments that can be included in other templates:
```bash
{% include 'partial_name' %}
```

### Environment-Specific Configurations

Templates can be customized for specific environments by using variables and conditionals.

## Installation

To install the modern template system, run:

```bash
./scripts/bgd-install-templates.sh
```

This will set up all required templates and include files.

## Template Structure

The modern template system consists of:

### Main Templates

- `nginx-dual-env.conf.template` - Configuration for blue/green weighted routing
- `nginx-single-env.conf.template` - Configuration for single environment routing
- `docker-compose.override.template` - Docker Compose overrides for deployment

### Partial Templates

- `ssl-server-block.template` - HTTPS server configuration
- `subdomain-block.template` - Subdomain server configuration

### Include Files

Include files provide modular functionality and are automatically generated:

- `proxy_params` - Common proxy headers and settings
- `websocket_params` - WebSocket support configuration
- `cors_params` - Cross-Origin Resource Sharing settings
- `security_headers` - Security-related HTTP headers

## Performance Optimizations

The modern templates include numerous performance optimizations:

1. **Connection Handling**
   - Increased worker connections
   - Multi-accept enabled
   - Epoll usage
   - Keepalive improvements

2. **File Operations**
   - AIO threads for asynchronous I/O
   - Optimized sendfile usage
   - TCP optimizations

3. **Caching**
   - Improved static file caching
   - Buffer optimizations
   - Open file cache configuration

4. **Compression**
   - Optimized gzip settings
   - Comprehensive MIME type support

## Security Enhancements

Enhanced security features include:

1. **TLS Configuration**
   - TLS 1.2/1.3 only
   - Strong cipher suites
   - OCSP stapling
   - SSL session improvements

2. **Security Headers**
   - Content Security Policy
   - XSS Protection
   - X-Frame-Options
   - Referrer Policy
   - Permissions Policy

3. **Access Controls**
   - Hidden file protection
   - Backoff controls for failed requests

## WebSocket Support

The templates provide built-in WebSocket support, which enables:
- Real-time applications
- Sustained connections
- Proper protocol upgrades
- Timeout configurations for long-lived connections

## Usage Examples

### Dual Environment Deployment

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --blue-port=8081 \
  --green-port=8082 \
  --domain-name=myapp.example.com
```

### Single Environment Cutover

```bash
./scripts/bgd-cutover.sh \
  --app-name=myapp \
  --target=blue
```

### Gradual Traffic Shifting

```bash
./scripts/bgd-cutover.sh \
  --app-name=myapp \
  --target=green \
  --gradual \
  --initial-weight=10 \
  --step=10 \
  --interval=60
```

## Customization

While the templates provide comprehensive configurations, you can further customize them:

1. Edit the template files directly in `config/templates/`
2. Add custom include files in the `nginx/` directory
3. Modify the Docker Compose override template for service-specific settings

## Troubleshooting

Use the validation tool to check your Nginx configuration:

```bash
./scripts/bgd-deploy.sh v1.0.0 \
  --app-name=myapp \
  --image-repo=ghcr.io/myorg/myapp \
  --validate-only
```

Or check directly:

```bash
docker run --rm -v "$(pwd)/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$(pwd)/nginx:/etc/nginx:ro" \
  nginx:stable-alpine nginx -t
```

## Migration from Legacy Templates

The modern templates are not backward compatible with the legacy system. To migrate:

1. Install the modern templates
2. Update any custom configurations to match the new structure
3. Redeploy your applications to apply the new templates

## Compatibility

The modern template system requires:
- Nginx 1.18+ 
- Docker 20.10+
- Bash 4.0+
