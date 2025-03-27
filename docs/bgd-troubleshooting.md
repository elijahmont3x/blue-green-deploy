# Blue/Green Deployment System Troubleshooting Guide

This document provides solutions for common issues you might encounter when using the Blue/Green Deployment System.

## Table of Contents
- [Deployment Issues](#deployment-issues)
- [Health Check Issues](#health-check-issues)
- [Database Migration Issues](#database-migration-issues)
- [Network and Port Issues](#network-and-port-issues)
- [SSL Certificate Issues](#ssl-certificate-issues)
- [Plugin Issues](#plugin-issues)
- [CI/CD Integration Issues](#cicd-integration-issues)
- [Common Error Messages](#common-error-messages)
- [Diagnostic Commands](#diagnostic-commands)

## Deployment Issues

### Deployment Fails to Start

**Symptoms:**
- Error: "Failed to start environment"
- Docker Compose fails to bring up containers

**Solutions:**
1. Check Docker availability:
   ```bash
   docker info
   ```

2. Verify Docker Compose file:
   ```bash
   docker compose config
   ```

3. Check for port conflicts:
   ```bash
   # Use automatic port assignment
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --auto-port-assignment
   ```

4. Check Docker logs:
   ```bash
   docker logs myapp-blue-app-1
   ```

### Unable to Pull Images

**Symptoms:**
- Error: "Failed to pull image"
- Deployment halts during image pull

**Solutions:**
1. Verify image exists:
   ```bash
   docker pull ghcr.io/myorg/myapp:v1.0.0
   ```

2. Check registry credentials:
   ```bash
   docker login ghcr.io
   ```

3. Try with explicit credentials:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
   ```

## Health Check Issues

### Health Checks Failing

**Symptoms:**
- Error: "Health check failed"
- Deployment stops after starting containers

**Solutions:**
1. Verify health endpoint is configured correctly:
   ```bash
   curl http://localhost:8081/health
   ```

2. Check container logs:
   ```bash
   docker logs myapp-blue-app-1
   ```

3. Increase health check retries and delay:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --health-retries=20 --health-delay=10
   ```

4. Run health check manually:
   ```bash
   ./scripts/bgd-health-check.sh http://localhost:8081/health --collect-logs
   ```

### Application Takes Too Long to Start

**Symptoms:**
- Health checks time out
- Deployment fails due to timeout

**Solutions:**
1. Increase health check delay:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --health-delay=15
   ```

2. Increase health check retries:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --health-retries=20
   ```

3. Use exponential backoff for retries:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --retry-backoff
   ```

## Database Migration Issues

### Migration Failures

**Symptoms:**
- Error: "Database migrations failed"
- Migration command returns non-zero exit code

**Solutions:**
1. Check database connection:
   ```bash
   # Test database connection
   docker exec -it myapp-blue-app-1 sh -c "psql \$DATABASE_URL -c 'SELECT 1'"
   ```

2. Run migrations manually:
   ```bash
   docker exec -it myapp-blue-app-1 sh -c "npm run migrate"
   ```

3. Skip migrations if needed:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --skip-migrations
   ```

4. Use a custom migration command:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --migrations-cmd="./custom-migrate.sh"
   ```

### Shadow Database Issues

**Symptoms:**
- Error: "Failed to create shadow database"
- Database permission issues

**Solutions:**
1. Disable shadow database approach:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --db-shadow-enabled=false
   ```

2. Check database user permissions:
   ```sql
   -- PostgreSQL
   GRANT CREATE DATABASE TO your_user;
   ```

3. Use a custom shadow database suffix:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --db-shadow-suffix="_temp"
   ```

## Network and Port Issues

### Port Conflicts

**Symptoms:**
- Error: "Port is already allocated"
- Containers fail to start

**Solutions:**
1. Use automatic port assignment:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --auto-port-assignment
   ```

2. Specify different ports:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --blue-port=9081 --green-port=9082
   ```

3. Check what's using the port:
   ```bash
   sudo lsof -i :8081
   ```

### Network Creation Failed

**Symptoms:**
- Error: "Failed to create network"
- Deployment cannot proceed

**Solutions:**
1. Clean up old networks:
   ```bash
   ./scripts/bgd-cleanup.sh --app-name=myapp --cleanup-networks
   ```

2. Check Docker network list:
   ```bash
   docker network ls
   ```

3. Remove network manually:
   ```bash
   docker network rm myapp-blue-network
   ```

## SSL Certificate Issues

### Certificate Generation Fails

**Symptoms:**
- Error: "Failed to obtain SSL certificates"
- Let's Encrypt challenges fail

**Solutions:**
1. Verify domain points to server:
   ```bash
   dig +short example.com
   ```

2. Check port 80 is available for verification:
   ```bash
   sudo lsof -i :80
   ```

3. Try with staging environment first:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --certbot-staging=true
   ```

4. Check Certbot logs:
   ```bash
   sudo tail -n 100 /var/log/letsencrypt/letsencrypt.log
   ```

### Nginx SSL Configuration Issues

**Symptoms:**
- SSL certificates exist but site shows "Connection not secure"
- HTTPS doesn't work

**Solutions:**
1. Check certificate files:
   ```bash
   ls -la ./certs/
   ```

2. Verify Nginx configuration:
   ```bash
   docker exec -it myapp-nginx-blue sh -c "nginx -t"
   ```

3. Restart Nginx:
   ```bash
   docker compose restart nginx
   ```

## Plugin Issues

### Plugins Not Loading

**Symptoms:**
- Plugin functionality isn't working
- No plugin-related logs

**Solutions:**
1. Check plugin file permissions:
   ```bash
   chmod +x plugins/bgd-*.sh
   ```

2. Verify plugin file naming:
   ```bash
   # Rename to proper naming convention
   mv plugins/custom-plugin.sh plugins/bgd-custom-plugin.sh
   ```

3. Check for syntax errors:
   ```bash
   bash -n plugins/bgd-custom-plugin.sh
   ```

### Plugin Hook Failures

**Symptoms:**
- Error: "Plugin hook failed"
- Deployment continues but features don't work

**Solutions:**
1. Check plugin logs:
   ```bash
   cat logs/bgd-*.log | grep "plugin"
   ```

2. Run with debug logging:
   ```bash
   export BGD_LOG_LEVEL=debug
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp
   ```

3. Disable specific plugin temporarily:
   ```bash
   mv plugins/bgd-problematic-plugin.sh plugins/bgd-problematic-plugin.sh.disabled
   ```

## CI/CD Integration Issues

### SSH Connection Failures

**Symptoms:**
- CI/CD pipeline fails with SSH errors
- Cannot connect to server

**Solutions:**
1. Check SSH credentials:
   ```bash
   # Test SSH connection
   ssh -i /path/to/key user@server "echo 'Connection successful'"
   ```

2. Verify server is accessible:
   ```bash
   ping server-ip
   ```

3. Check SSH key permissions:
   ```bash
   chmod 600 /path/to/key
   ```

### Environment Variable Issues

**Symptoms:**
- Application behaves differently than expected
- Configuration values not applied

**Solutions:**
1. Verify environment variables are passed:
   ```bash
   # Add debugging output to CI/CD script
   env | grep -E 'APP_|DB_'
   ```

2. Check environment file:
   ```bash
   cat .env.blue
   ```

3. Explicitly set required variables:
   ```bash
   ./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --database-url="postgresql://user:pass@host/db"
   ```

## Common Error Messages

### "Failed to parse parameters"

**Cause:** Invalid command-line parameters or syntax.

**Solution:** Check parameter syntax and verify all required parameters:
```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
```

### "Docker is not running or not accessible"

**Cause:** Docker daemon is not running or current user doesn't have permission.

**Solution:** Start Docker and verify user permissions:
```bash
# Start Docker
sudo systemctl start docker

# Add user to Docker group
sudo usermod -aG docker $USER
```

### "Not all services are healthy"

**Cause:** One or more services failed health checks.

**Solution:** Check individual container logs:
```bash
# View logs for specific container
docker logs myapp-blue-app-1
```

### "Target environment is not running"

**Cause:** The environment you're trying to cutover to isn't running.

**Solution:** Deploy to the environment first:
```bash
./scripts/bgd-deploy.sh v1.0.0 --app-name=myapp --target-env=blue
```

## Diagnostic Commands

### Check Deployment Status

```bash
# List all environments
docker ps -a | grep myapp

# Check which environment is active
grep -E "blue|green" nginx.conf

# View deployment logs
cat logs/bgd-*.log | tail -n 50
```

### Verify Container Health

```bash
# Check container health status
docker inspect --format='{{.State.Health.Status}}' myapp-blue-app-1

# View health check logs
docker inspect --format='{{range .State.Health.Log}}{{.Output}}{{end}}' myapp-blue-app-1
```

### Test Network Connectivity

```bash
# Test internal connection
docker exec -it myapp-blue-app-1 curl -v http://myapp-blue-app-1:3000/health

# Test external connection
curl -v http://localhost:8081/health
```

### Check Docker Resources

```bash
# List all networks
docker network ls

# List all volumes
docker volume ls

# Check disk space
df -h /var/lib/docker
```

If you encounter issues not covered in this guide, please check the detailed logs in the `logs/` directory and use the following command to gather diagnostic information:

```bash
# Collect diagnostic information
./scripts/bgd-health-check.sh http://localhost:8081/health --app-name=myapp --collect-logs
```