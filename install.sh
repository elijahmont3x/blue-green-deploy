#!/bin/bash
#
# install.sh - Initializes the blue/green deployment system
#
# Usage:
#   ./install.sh [APP_NAME] [INSTALL_DIR]
#
# Arguments:
#   APP_NAME     Name of your application (default: "app")
#   INSTALL_DIR  Directory to install to (default: current directory)

set -euo pipefail

# Default values
APP_NAME=${1:-"app"}
INSTALL_DIR=${2:-"."}

# Ensure INSTALL_DIR is absolute path
if [[ "$INSTALL_DIR" != /* ]]; then
  INSTALL_DIR="$(pwd)/$INSTALL_DIR"
fi

echo "Initializing blue/green deployment system for $APP_NAME in $INSTALL_DIR"

# Create directory structure
mkdir -p "$INSTALL_DIR/scripts"
mkdir -p "$INSTALL_DIR/config/templates"
mkdir -p "$INSTALL_DIR/plugins"
mkdir -p "$INSTALL_DIR/.deployment_logs"

# Define current script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy scripts
echo "Installing deployment scripts..."
for script in "$SCRIPT_DIR/scripts/"*.sh; do
  if [ -f "$script" ]; then
    cp "$script" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/$(basename "$script")"
  fi
done

# Copy templates
echo "Installing configuration templates..."
for template in "$SCRIPT_DIR/config/templates/"*; do
  if [ -f "$template" ]; then
    cp "$template" "$INSTALL_DIR/config/templates/"
  fi
done

# Create .gitignore if it doesn't exist
if [ ! -f "$INSTALL_DIR/.gitignore" ]; then
  cat > "$INSTALL_DIR/.gitignore" << EOL
.env
.env.*
.deployment_logs/
nginx.conf
docker-compose.*.yml
EOL
  echo "Created .gitignore file"
fi

# Create README.md if it doesn't exist
if [ ! -f "$INSTALL_DIR/README.md" ]; then
  cat > "$INSTALL_DIR/README.md" << EOL
# Blue/Green Deployment for $APP_NAME

This deployment system provides zero-downtime updates using a blue/green deployment strategy.

## Basic Usage

Deploy a new version:
\`\`\`bash
./scripts/deploy.sh VERSION --app-name=$APP_NAME
\`\`\`

Complete cutover:
\`\`\`bash
./scripts/cutover.sh [blue|green] --app-name=$APP_NAME
\`\`\`

Rollback if needed:
\`\`\`bash
./scripts/rollback.sh --app-name=$APP_NAME
\`\`\`

Clean up:
\`\`\`bash
./scripts/cleanup.sh --app-name=$APP_NAME
\`\`\`

See script help for more options and detailed usage.
EOL
  echo "Created README.md file"
fi

# Create example plugin
if [ ! -f "$INSTALL_DIR/plugins/example.sh" ]; then
  cat > "$INSTALL_DIR/plugins/example.sh" << 'EOL'
#!/bin/bash

# This is an example plugin that shows how hooks work
# Uncomment and modify as needed

# hook_pre_deploy() {
#   local version="$1"
#   log_info "Running pre-deployment tasks for version $version"
#   return 0
# }

# hook_post_deploy() {
#   local version="$1"
#   local env_name="$2"
#   log_info "Running post-deployment tasks for version $version in $env_name environment"
#   return 0
# }

# hook_pre_cutover() {
#   local new_env="$1"
#   local old_env="$2"
#   log_info "Running pre-cutover tasks"
#   return 0
# }

# hook_post_cutover() {
#   local new_env="$1"
#   local old_env="$2"
#   log_info "Running post-cutover tasks"
#   return 0
# }

# hook_pre_rollback() {
#   log_info "Running pre-rollback tasks"
#   return 0
# }

# hook_post_rollback() {
#   local rollback_env="$1"
#   log_info "Running post-rollback tasks"
#   return 0
# }
EOL
  chmod +x "$INSTALL_DIR/plugins/example.sh"
  echo "Created example plugin"
fi

echo
echo "Installation completed successfully!"
echo
echo "Next steps:"
echo "1. Add your docker-compose.yml and Dockerfile to $INSTALL_DIR"
echo "2. Deploy your application with:"
echo "   cd $INSTALL_DIR && ./scripts/deploy.sh VERSION --app-name=$APP_NAME"
echo