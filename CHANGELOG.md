# Changelog

All notable changes to the Blue/Green Deployment toolkit are documented in this file.

## [1.0.1] - 2025-03-30

### Enhancements
- **Complete Redesign of Nginx Templating System**:  
  - Discarded all legacy service-specific code.
  - Introduced dynamic generation of Nginx configurations that support both path-based and subdomain-based routing.
  - Improved SSL integration with automatic certificate management.
- **Dynamic Port Assignment**:  
  - Reinforced the auto-port-assignment logic to handle port conflicts seamlessly.
- **Enhanced Routing Options**:  
  - New command-line parameters (`--paths`, `--subdomains`, `--default-service`, and `--default-port`) for flexible, service-agnostic routing.
- **Plugin Improvements**:  
  - Updated plugin APIs for SSL, notifications, audit logging, and more.
  
### Bug Fixes
- Fixed duplicated file-writing routines by suggesting potential refactoring (no logical impact).
- Addressed a syntax error in the Nginx template processor.
  
### Documentation Updates
- Revised the README to reflect the new dynamic templating system and comprehensive feature set.
- Updated the Routing System and CI/CD integration examples.
- Added detailed troubleshooting and security best practices sections.

## [1.0.0] - 2025-03-26

### Initial Release

- **Core Framework**
  - Zero-downtime deployment system with blue/green environment management
  - Gradual traffic shifting with configurable weights (10%, 50%, 90%)
  - Comprehensive health checking with automatic diagnostics
  - Automatic port management with conflict resolution
  - Environment-specific configuration and resource isolation
  - Shared service support for stateful components (databases, caches)
  - Automatic rollback capabilities

- **Plugin System**
  - Database migrations with zero-downtime shadow database approach
  - Service discovery and registry for multi-service architectures
  - SSL automation with Let's Encrypt integration
  - Audit logging with structured event recording
  - Notification system with Telegram and Slack integration

- **Configuration Management**
  - Multi-domain routing with environment-based traffic control
  - Docker Compose template management
  - Environment-specific variable handling with secure storage
  - Automatic port assignment and conflict resolution

- **Tools and Utilities**
  - Deployment health verification
  - Resource cleanup and management
  - Deployment history tracking
  - Service status monitoring
  - Environment cutover management

- **Security Features**
  - Secure credential storage
  - Environment variable sanitization
  - SSL certificate automation
  - Sensitive data masking in logs

- **Documentation**
  - Comprehensive documentation with examples
  - Plugin usage guidelines
  - Troubleshooting guide
  - Integration examples for CI/CD pipelines

### Technical Notes

- Designed for modern containerized applications
- Compatible with Docker and Docker Compose
- Seamless integration with CI/CD platforms
- Language and framework agnostic deployment process
- Support for monorepo and multi-service architectures