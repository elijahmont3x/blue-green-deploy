# Blue/Green Deployment System - Usage Examples

This document contains practical examples of using the Blue/Green Deployment (BGD) system for various deployment scenarios.

## Table of Contents

- [Basic Deployment](#basic-deployment)
- [Deployment with Cutover](#deployment-with-cutover)
- [Gradual Traffic Shifting](#gradual-traffic-shifting)
- [Using SSL Certificates](#using-ssl-certificates)
- [Working with Databases](#working-with-databases)
- [Multi-App Deployment](#multi-app-deployment)
- [CI/CD Integration](#cicd-integration)
- [Rollback Operations](#rollback-operations)
- [Environment Cleanup](#environment-cleanup)
- [Health Checks](#health-checks)

## Basic Deployment

The simplest way to deploy an application using the BGD system:

```bash
# Deploy version 1.0.0 to the inactive environment (auto-selected)
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
```

This will:
1. Automatically select the inactive environment (blue or green)
2. Deploy the application from the specified image repository
3. Not switch traffic to the new deployment

## Deployment with Cutover

To deploy and automatically cut over traffic to the new version:

```bash
# Deploy and cut over
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp --cutover
```

By adding the `--cutover` flag, the system will:
1. Deploy to the inactive environment
2. Run health checks to ensure the deployment is healthy
3. Cut over traffic to the new environment if health checks pass

## Gradual Traffic Shifting

For critical applications, you may want to gradually shift traffic:

```bash
# Deploy to inactive environment
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp

# Gradually shift traffic (10% increments, 30 second intervals)
./scripts/bgd-cutover.sh --app-name=myapp --target=green --gradual --step=10 --interval=30
```

This will:
1. Begin with 10% of traffic to new environment
2. Increase by 10% every 30 seconds
3. Finally cut over completely when reaching 100%

## Using SSL Certificates

To deploy an application with SSL:

```bash
# First, initialize SSL with Let's Encrypt
./scripts/bgd-init.sh --ssl=myapp.example.com --email=admin@example.com

# Deploy with SSL enabled
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp \
  --domain-name=myapp.example.com --ssl-enabled
```

This will:
1. Generate/renew SSL certificates for your domain
2. Configure Nginx to use HTTPS
3. Set up automatic renewal

## Working with Databases

For applications with database migrations:

```bash
# Deploy with database migrations
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp \
  --db-migrations
```

With the `--db-migrations` flag, the system will:
1. Deploy to the inactive environment
2. Back up the database before migrations
3. Run database migrations using the configured command
4. Continue the deployment if migrations succeed

## Multi-App Deployment

Using the master proxy for multiple applications:

```bash
# Initialize the master proxy
./scripts/bgd-init.sh --proxy

# Deploy first app
./scripts/bgd-deploy.sh 1.0.0 --app-name=app1 --image-repo=ghcr.io/myorg/app1 \
  --domain-name=app1.example.com

# Deploy second app
./scripts/bgd-deploy.sh 2.0.0 --app-name=app2 --image-repo=ghcr.io/myorg/app2 \
  --domain-name=app2.example.com
```

The master proxy will:
1. Automatically route traffic based on domain names
2. Manage SSL certificates centrally
3. Provide a unified point of entry for all applications

## CI/CD Integration

Example GitHub Actions workflow:

```yaml
# In your repository's .github/workflows/deploy.yml
name: Deploy

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
        
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2
        
      - name: Build and push Docker image
        uses: docker/build-push-action@v3
        with:
          push: true
          tags: ghcr.io/myorg/myapp:${{ github.sha }}
          
      - name: Deploy using SSH
        uses: appleboy/ssh-action@v0.1.4
        with:
          host: ${{ secrets.SSH_HOST }}
          username: ${{ secrets.SSH_USERNAME }}
          key: ${{ secrets.SSH_PRIVATE_KEY }}
          script: |
            cd /opt/bgd
            ./scripts/bgd-deploy.sh ${{ github.sha }} \
              --app-name=myapp \
              --image-repo=ghcr.io/myorg/myapp \
              --cutover
```

## Rollback Operations

If you need to roll back to the previous version:

```bash
# Roll back to inactive environment
./scripts/bgd-rollback.sh --app-name=myapp

# Force rollback even if health checks fail
./scripts/bgd-rollback.sh --app-name=myapp --force

# Roll back including database changes
./scripts/bgd-rollback.sh --app-name=myapp --db-rollback
```

Rollback will:
1. Switch traffic back to the previous environment
2. Roll back database changes if requested
3. Log the rollback operation for audit purposes

## Environment Cleanup

Clean up environments after successful deployment:

```bash
# Clean up inactive environment
./scripts/bgd-cleanup.sh --app-name=myapp

# Clean up specific environment
./scripts/bgd-cleanup.sh --app-name=myapp --environment=blue

# Dry run to see what would be cleaned up
./scripts/bgd-cleanup.sh --app-name=myapp --dry-run
```

Cleanup operations:
1. Remove containers and networks
2. Remove volumes (unless --keep-volumes is specified)
3. Clean up unused Docker images

## Health Checks

Perform health checks on environments:

```bash
# Check health of specific environment
./scripts/bgd-health-check.sh --app-name=myapp --environment=blue

# Check both environments
./scripts/bgd-health-check.sh --app-name=myapp --environment=both

# Custom health check parameters
./scripts/bgd-health-check.sh --app-name=myapp --endpoint=/api/healthz --retries=20 --delay=10
```

Health checks ensure:
1. The application is responding correctly
2. The correct status codes are returned
3. The application is ready to receive traffic

## Advanced Examples

### Custom Deployment Profile

Create and use a deployment profile for different environments:

```bash
# Create a profile
cat > ./profiles/production/env.conf << EOL
HEALTH_RETRIES=20
HEALTH_DELAY=10
CACHE_ENABLED=true
SSL_ENABLED=true
DOMAIN_NAME=myapp.example.com
EOL

# Deploy using profile
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp \
  --profile=production --cutover
```

### Notification Setup

To receive notifications on deployment events:

```bash
# Set up Slack notifications
export NOTIFY_ENABLED=true
export NOTIFY_CHANNELS=slack
export SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL

# Deploy with notifications
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp \
  --cutover
```

This will send notifications for:
1. Deployment start and completion
2. Cutover operations
3. Rollbacks and failures