# Blue/Green Deployment System

A comprehensive toolkit for implementing Blue/Green deployments with Docker containers.

## Overview

The Blue/Green Deployment (BGD) system provides a set of scripts and tools to implement zero-downtime deployments using the blue/green deployment strategy. This approach maintains two identical production environments, with only one serving production traffic at any time.

## Features

- **Zero-downtime deployments**: Switch between environments seamlessly
- **Traffic management**: Support for immediate or gradual traffic shifting
- **Health checks**: Automated verification of application health before cutover
- **Rollback capability**: Quick recovery from failed deployments
- **SSL management**: Let's Encrypt integration for automated certificate management
- **Multiple application support**: Deploy and manage multiple applications
- **Plugin architecture**: Extensible system with support for custom plugins
- **Monitoring**: Continuous health monitoring with notifications
- **Audit logging**: Comprehensive logging of all deployment operations

## Installation

1. Clone this repository to your server:

```bash
git clone https://github.com/username/blue-green-deploy.git
cd blue-green-deploy
```

2. Run the initialization script:

```bash
./scripts/bgd-init.sh
```

3. (Optional) Configure SSL with Let's Encrypt:

```bash
./scripts/bgd-init.sh --ssl=example.com --email=admin@example.com
```

## Quick Start

### Basic Deployment

Deploy an application with the following command:

```bash
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp
```

This will:
1. Deploy version 1.0.0 to the inactive environment
2. Run health checks
3. Not switch traffic automatically (waiting for manual cutover)

### Deploy and Cutover

To deploy and automatically cut over traffic to the new version:

```bash
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp --cutover
```

### Gradual Traffic Shifting

For critical applications, you can gradually shift traffic:

```bash
./scripts/bgd-deploy.sh 1.0.0 --app-name=myapp --image-repo=ghcr.io/myorg/myapp

# Then, after deployment:
./scripts/bgd-cutover.sh --app-name=myapp --target=green --gradual --step=10 --interval=30
```

This gradually moves traffic to the new environment in 10% increments every 30 seconds.

## Documentation

- [Usage Examples](./docs/bgd-usage-examples.md)
- [Modern Templates](./docs/bgd-modern-templates.md)
- [Plugin System](./docs/bgd-plugins.md)
- [Architecture Overview](./docs/bgd-architecture.md)

## Directory Structure