#!/bin/bash
#
# install.sh - Initializes the blue/green deployment system
#
# Usage:
#   ./install.sh [APP_NAME] [INSTALL_DIR]executable first
#   ./install.sh [APP_NAME] [INSTALL_DIR]
# Arguments:
#   APP_NAME     Name of your application (default: "app")
#   INSTALL_DIR  Directory to install to (default: current directory)
#   INSTALL_DIR  Directory to install to (default: current directory)
set -euo pipefail
set -euo pipefail
# Default values
APP_NAME=${1:-"app"}
INSTALL_DIR=${2:-"."}
INSTALL_DIR=${2:-"."}
# Ensure INSTALL_DIR is absolute path
if [[ "$INSTALL_DIR" != /* ]]; thenth
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
 and ensure they're executable
# Copy scripts
echo "Installing deployment scripts..."
for script in "$SCRIPT_DIR/scripts/"*.sh; do
    cp "$script" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/$(basename "$script")"
    echo "  - Made $(basename "$script") executable"chmod +x "$INSTALL_DIR/scripts/$(basename "$script")"
  fi
donedone

# Copy templates
echo "Installing configuration templates..."
for template in "$SCRIPT_DIR/config/templates/"*; doconfig/templates/"*; do
  if [ -f "$template" ]; then
    cp "$template" "$INSTALL_DIR/config/templates/"cp "$template" "$INSTALL_DIR/config/templates/"
  fi
donedone

# Create .gitignore if it doesn't exist
if [ ! -f "$INSTALL_DIR/.gitignore" ]; thenhen
  cat > "$INSTALL_DIR/.gitignore" << EOLt > "$INSTALL_DIR/.gitignore" << EOL
.env
.env.*
.deployment_logs/t_logs/
nginx.conf
docker-compose.*.ymlker-compose.*.yml
EOL
  echo "Created .gitignore file"echo "Created .gitignore file"
fifi

# Create README.md if it doesn't exist
if [ ! -f "$INSTALL_DIR/README.md" ]; thenhen
  cat > "$INSTALL_DIR/README.md" << EOLOL
# Blue/Green Deployment for $APP_NAME# Blue/Green Deployment for $APP_NAME

This deployment system provides zero-downtime updates using a blue/green deployment strategy.This deployment system provides zero-downtime updates using a blue/green deployment strategy.

## Basic Usage## Basic Usage

Deploy a new version:ew version:
\`\`\`bash
./scripts/deploy.sh VERSION --app-name=$APP_NAMEpts/deploy.sh VERSION --app-name=$APP_NAME
\`\`\`\`\`\`

Complete cutover:utover:
\`\`\`bash
./scripts/cutover.sh [blue|green] --app-name=$APP_NAMEpts/cutover.sh [blue|green] --app-name=$APP_NAME
\`\`\`\`\`\`

Rollback if needed:f needed:
\`\`\`bash
./scripts/rollback.sh --app-name=$APP_NAMEpts/rollback.sh --app-name=$APP_NAME
\`\`\`\`\`\`

Clean up:
\`\`\`bash
./scripts/cleanup.sh --app-name=$APP_NAMEpts/cleanup.sh --app-name=$APP_NAME
\`\`\`\`\`\`

See script help for more options and detailed usage. script help for more options and detailed usage.
EOL
  echo "Created README.md file"echo "Created README.md file"
fifi

# Create example plugin
if [ ! -f "$INSTALL_DIR/plugins/example.sh" ]; thenn
  cat > "$INSTALL_DIR/plugins/example.sh" << 'EOL'NSTALL_DIR/plugins/example.sh" << 'EOL'
#!/bin/bash#!/bin/bash

# This is an example plugin that shows how hooks work shows how hooks work
# Uncomment and modify as needed# Uncomment and modify as needed

# hook_pre_deploy() {
#   local version="$1"
#   log_info "Running pre-deployment tasks for version $version" "Running pre-deployment tasks for version $version"
#   return 0 return 0
# }# }

# hook_post_deploy() {
#   local version="$1"
#   local env_name="$2"
#   log_info "Running post-deployment tasks for version $version in $env_name environment" "Running post-deployment tasks for version $version in $env_name environment"
#   return 0 return 0
# }# }

# hook_pre_cutover() {
#   local new_env="$1"
#   local old_env="$2"
#   log_info "Running pre-cutover tasks" "Running pre-cutover tasks"
#   return 0 return 0
# }# }

# hook_post_cutover() {{
#   local new_env="$1"
#   local old_env="$2"
#   log_info "Running post-cutover tasks" "Running post-cutover tasks"
#   return 0 return 0
# }# }

# hook_pre_rollback() {
#   log_info "Running pre-rollback tasks" "Running pre-rollback tasks"
#   return 0 return 0
# }# }

# hook_post_rollback() {
#   local rollback_env="$1"
#   log_info "Running post-rollback tasks" "Running post-rollback tasks"
#   return 0 return 0
# }
EOL
  chmod +x "$INSTALL_DIR/plugins/example.sh"s/example.sh"
  echo "Created example plugin"echo "Created example plugin"
fifi

echo
echo "Installation completed successfully!" "Installation completed successfully!"
echo
echo "Next steps:"
echo "1. Add your docker-compose.yml and Dockerfile to $INSTALL_DIR"d Dockerfile to $INSTALL_DIR"
echo "2. Deploy your application with:"
echo "   cd $INSTALL_DIR && ./scripts/deploy.sh VERSION --app-name=$APP_NAME" "   cd $INSTALL_DIR && ./scripts/deploy.sh VERSION --app-name=$APP_NAME"

echoecho