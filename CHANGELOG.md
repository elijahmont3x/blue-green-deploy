# Changelog

## v2.0.0 (2025-03-23)

### Major Enhancements

- **Namespace Management**: Complete refactoring to use proper namespacing
  - All internal functions prefixed with `bgd_` to avoid conflicts
  - All core files prefixed with `bgd-` (e.g., `bgd-core.sh`)
  - **Removed backward compatibility wrapper scripts**
  - Plugin system namespacing for extensibility

- **Plugin System**: Complete overhaul of the plugin architecture with argument registration
  - New hook system for extending deployment process
  - Plugin argument registration mechanism
  - Automatic environment variable propagation for plugins

- **Multi-Container Support**: Enhanced architecture for complex applications
  - Support for deploying multiple containers per environment
  - Separation of stateless and stateful services
  - Shared network and volume management
  - Improved docker-compose template handling

- **Domain-Based Routing**: Advanced traffic routing capabilities
  - Support for multiple domains and subdomains
  - Domain-specific service routing
  - Integrated SSL certificates for all domains

- **Database Migration Strategies**: Zero-downtime database handling
  - Shadow database approach for zero-downtime migrations
  - Comprehensive backup and restore capabilities
  - Migration history tracking
  - Framework-specific migration adapters

- **Service Discovery**: Automatic service registration
  - Local and external service registry integration
  - Dynamic service URL generation
  - Automatic Nginx configuration updates
  - Inter-service communication management

- **SSL Automation**: Completely rebuilt SSL certificate handling
  - DNS-based verification replaces HTTP verification 
  - Multiple DNS provider support (GoDaddy, Namecheap) with easy extensibility
  - Automatic detection and reconfiguration of existing certificates
  - Let's Encrypt integration with improved reliability
  - Automatic certificate renewal with proper credentials management
  - Multi-domain certificate support
  - Seamless CI/CD integration with secure API key handling
  - ACME challenge configuration

- **Audit Logging**: Comprehensive deployment tracking
  - Structured logging with timestamps
  - Integration with monitoring systems
  - Customizable notification options
  - Deployment history tracking

### New Scripts

- **health-check.sh**: Standalone utility for checking service health
  - Flexible endpoint verification
  - Custom retry and delay settings
  - Enhanced output and error handling

### Enhanced Scripts

- **common.sh**: Core utilities and plugin management
  - Added plugin registration system
  - Improved parameter parsing
  - Enhanced environment variable handling
  - Expanded helper functions

- **deploy.sh**: Primary deployment workflow
  - Support for multi-container deployments
  - Integration with all plugins
  - Improved error handling
  - Enhanced traffic shifting

- **cutover.sh**: Traffic transition management
  - Support for keeping old environments
  - Health verification before cutover
  - Multi-domain support

- **rollback.sh**: Recovery and rollback capabilities
  - Enhanced database rollback
  - Improved service restoration
  - Plugin integration for notifications

- **cleanup.sh**: Deployment cleanup utilities
  - More flexible cleanup options
  - Better docker resource management
  - Improved cleanup reporting

### New Plugins

- **db-migrations.sh**: Database migration management
  - Schema and full database backups
  - Migration history tracking
  - Shadow database zero-downtime migrations
  - Framework-specific adapters
  - Rollback capabilities

- **service-discovery.sh**: Service registration
  - Automatic service registration
  - Service URL generation
  - Nginx configuration updates
  - External registry integration

- **ssl-automation.sh**: Completely redesigned SSL management
  - DNS-based verification for more reliable certificate issuance
  - Support for multiple DNS providers (GoDaddy, Namecheap)
  - Automatic detection and reconfiguration of existing certificates
  - Enhanced renewal management
  - API-based automation for CI/CD environments
  - Multi-domain support
  - Improved error handling and recovery

- **audit-logging.sh**: Deployment tracking
  - Structured event logging
  - Monitoring system integration
  - Notification capabilities
  - History tracking

### Documentation

- Complete overhaul of the README.md
- Added comprehensive plugin documentation
- Added multi-container configuration examples
- Added domain-based routing examples
- Added troubleshooting guides
- Enhanced security documentation
- New usage examples for all features

### Bugfixes

- Fixed issue with environment variable propagation
- Improved handling of failed health checks
- Enhanced error recovery during deployments
- Fixed race conditions in traffic shifting
- Improved cleanup of orphaned containers
- Enhanced SSL certificate validation
- Fixed "chicken-and-egg" problem with SSL verification requiring a running webserver

### Breaking Changes

- Plugin system now requires explicit registration of custom arguments
- Default service name expected in docker-compose.yml is now `app`
- Stateful services must be marked with `bgd.role=persistent` label
- SSL certificate directory structure has changed
- SSL automation now requires DNS provider API credentials for fully automated operation