#!/usr/bin/env bash
# LLDPq Update Script
# Updates system files while preserving configuration
# 
# Copyright (c) 2024-2026 LLDPq Project
# Licensed under MIT License - see LICENSE file for details
#
# Usage: ./update.sh [-y] [--enable-telemetry] [--disable-telemetry]
#   -y                  Auto-yes to all prompts (non-interactive mode)
#   --enable-telemetry  Enable streaming telemetry support (installs Docker)
#   --disable-telemetry Disable streaming telemetry support

set -e

# Determine LLDPQ install directory
# Read from existing config if available, otherwise use default based on user
if [[ -f /etc/lldpq.conf ]]; then
    LLDPQ_INSTALL_DIR=$(grep "^LLDPQ_DIR=" /etc/lldpq.conf 2>/dev/null | cut -d'=' -f2 || echo "")
fi
if [[ -z "$LLDPQ_INSTALL_DIR" ]]; then
    if [[ $EUID -eq 0 ]]; then
        LLDPQ_INSTALL_DIR="/opt/lldpq"
    else
        LLDPQ_INSTALL_DIR="$LLDPQ_INSTALL_DIR"
    fi
fi

# Parse arguments
AUTO_YES=false
ENABLE_TELEMETRY=false
DISABLE_TELEMETRY=false

for arg in "$@"; do
    case $arg in
        -y) AUTO_YES=true ;;
        --enable-telemetry) ENABLE_TELEMETRY=true ;;
        --disable-telemetry) DISABLE_TELEMETRY=true ;;
        -h|--help)
            echo "Usage: ./update.sh [-y] [--enable-telemetry] [--disable-telemetry]"
            echo ""
            echo "Options:"
            echo "  -y                  Auto-yes to all prompts"
            echo "  --enable-telemetry  Enable streaming telemetry (requires Docker)"
            echo "  --disable-telemetry Disable streaming telemetry"
            exit 0
            ;;
    esac
done

# Handle telemetry-only mode
if [[ "$ENABLE_TELEMETRY" == "true" ]] || [[ "$DISABLE_TELEMETRY" == "true" ]]; then
    if [[ "$ENABLE_TELEMETRY" == "true" ]]; then
        echo "Enabling Streaming Telemetry..."
        echo ""
        
        # Check/install Docker
        if ! command -v docker &> /dev/null; then
            echo "Docker not found. Installing Docker..."
            curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
            sudo sh /tmp/get-docker.sh
            sudo usermod -aG docker "$(whoami)"
            rm /tmp/get-docker.sh
            echo "Docker installed successfully"
            echo "[!] NOTE: You may need to logout/login for Docker group to take effect"
        else
            echo "Docker found: $(docker --version)"
        fi
        
        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            echo "Installing docker-compose..."
            sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            echo "docker-compose installed"
        fi
        
        # Update config
        if grep -q "^TELEMETRY_ENABLED=" /etc/lldpq.conf 2>/dev/null; then
            sudo sed -i 's/^TELEMETRY_ENABLED=.*/TELEMETRY_ENABLED=true/' /etc/lldpq.conf
        else
            echo "TELEMETRY_ENABLED=true" | sudo tee -a /etc/lldpq.conf > /dev/null
        fi
        
        if ! grep -q "^PROMETHEUS_URL=" /etc/lldpq.conf 2>/dev/null; then
            echo "PROMETHEUS_URL=http://localhost:9090" | sudo tee -a /etc/lldpq.conf > /dev/null
        fi
        
        echo ""
        echo "Telemetry support enabled!"
        echo ""
        
        # Configure Docker storage driver if needed (for VMs without overlay support)
        if [[ ! -f /etc/docker/daemon.json ]]; then
            echo "Configuring Docker storage driver..."
            sudo mkdir -p /etc/docker
            echo '{"storage-driver": "vfs"}' | sudo tee /etc/docker/daemon.json > /dev/null
            sudo systemctl restart docker
        fi
        
        # Start the telemetry stack automatically
        if [[ -f "$LLDPQ_INSTALL_DIR/telemetry/docker-compose.yaml" ]]; then
            echo ""
            echo "Starting telemetry stack..."
            cd "$LLDPQ_INSTALL_DIR/telemetry"
            # Use sudo for docker if user not yet in docker group (fresh install)
            if docker compose up -d 2>&1; then
                : # success without sudo
            elif docker-compose up -d 2>&1; then
                : # success with old docker-compose
            elif sudo docker compose up -d 2>&1; then
                : # success with sudo
            elif sudo docker-compose up -d 2>&1; then
                : # success with sudo + old docker-compose
            else
                echo "[!] Could not start stack. Try manually:"
                echo "    cd $LLDPQ_INSTALL_DIR/telemetry && sudo docker compose up -d"
            fi
            cd - > /dev/null
            
            # Wait a moment and check status
            sleep 3
            if docker ps --filter "name=lldpq-prometheus" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
                echo ""
                echo "Telemetry stack is running:"
                echo "  - OTEL Collector: http://localhost:4317"
                echo "  - Prometheus:     http://localhost:9090"
                echo "  - Alertmanager:   http://localhost:9093"
            fi
        else
            echo "[!] Telemetry files not found. Run ./install.sh or ./update.sh first."
        fi
        
        echo ""
        echo "Next step: Enable telemetry on switches from web UI:"
        echo "  Telemetry → Configuration → Enable Telemetry"
        
    elif [[ "$DISABLE_TELEMETRY" == "true" ]]; then
        echo "Disabling Streaming Telemetry..."
        echo ""
        echo "This will completely remove the telemetry stack and all stored metrics."
        
        # Stop and remove telemetry stack with volumes
        if [[ -f "$LLDPQ_INSTALL_DIR/telemetry/docker-compose.yaml" ]]; then
            cd "$LLDPQ_INSTALL_DIR/telemetry"
            echo "Stopping and removing containers..."
            docker-compose down -v 2>/dev/null || docker compose down -v 2>/dev/null || true
            cd - > /dev/null
            echo "Telemetry stack removed (containers + volumes)"
        fi
        
        # Remove saved collector config
        sudo sed -i '/^TELEMETRY_COLLECTOR_IP=/d' /etc/lldpq.conf 2>/dev/null || true
        sudo sed -i '/^TELEMETRY_COLLECTOR_PORT=/d' /etc/lldpq.conf 2>/dev/null || true
        sudo sed -i '/^TELEMETRY_COLLECTOR_VRF=/d' /etc/lldpq.conf 2>/dev/null || true
        
        # Update config
        if grep -q "^TELEMETRY_ENABLED=" /etc/lldpq.conf 2>/dev/null; then
            sudo sed -i 's/^TELEMETRY_ENABLED=.*/TELEMETRY_ENABLED=false/' /etc/lldpq.conf
        else
            echo "TELEMETRY_ENABLED=false" | sudo tee -a /etc/lldpq.conf > /dev/null
        fi
        
        echo "Telemetry support disabled"
    fi
    
    exit 0
fi

echo "LLDPq Update Script"
echo "======================"
if [[ "$AUTO_YES" == "true" ]]; then
    echo "   Running in non-interactive mode (-y)"
fi

# Check if running via sudo from non-root user (causes $HOME issues)
if [[ $EUID -eq 0 ]] && [[ -n "$SUDO_USER" ]] && [[ "$SUDO_USER" != "root" ]]; then
    echo "[!] Please run without sudo: ./update.sh"
    echo "   The script will ask for sudo when needed"
    exit 1
fi

# Running as root is OK (for dedicated servers)
if [[ $EUID -eq 0 ]]; then
    echo "Running as root - files will be in /opt/lldpq"
fi

# Check if we're in the lldpq-src directory
if [[ ! -f "README.md" ]] || [[ ! -d "lldpq" ]]; then
    echo "[!] Please run this script from the lldpq-src directory"
    echo "   Make sure you're in the directory containing README.md and lldpq/"
    exit 1
fi

# Load config with fallback
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

echo ""
echo "[01] Backup existing lldpq directory?"
if [[ -d "$LLDPQ_INSTALL_DIR" ]]; then
    if [[ "$AUTO_YES" == "true" ]]; then
        echo "   Skipping backup (auto-yes mode)"
    else
        read -p "Create backup of existing lldpq? [y/N]: " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            backup_dir="$LLDPQ_INSTALL_DIR.backup.$(date +%Y%m%d_%H%M%S)"
            echo "   Backing up $LLDPQ_INSTALL_DIR to $backup_dir"
            cp -r "$LLDPQ_INSTALL_DIR" "$backup_dir"
            echo "Backup created: $backup_dir"
        else
            echo "   Skipping backup as requested"
        fi
    fi
else
    echo "   No existing lldpq directory found, skipping backup"
fi

echo ""
echo "[02] Updating system files..."

# Backup user's system config files before overwriting
echo "   - Backing up user system configs..."
system_config_backup=$(mktemp -d)
# nccm.yml no longer needed - zzh loads from devices.yaml

echo "   - Updating etc/* to /etc/"
sudo cp -r etc/* /etc/

# Restore user's system config files
echo "   - Restoring user system configs..."
# nccm.yml no longer needed - zzh loads from devices.yaml

# Clean up backup
rm -rf "$system_config_backup"

echo "   - Updating html/* to $WEB_ROOT/"
sudo cp -r html/* "$WEB_ROOT/"

# Ensure Monaco Editor exists
MONACO_DIR="$WEB_ROOT/monaco"
if [[ ! -d "$MONACO_DIR" ]]; then
    echo "   - Downloading Monaco Editor..."
    MONACO_VERSION="0.45.0"
    TMP_DIR=$(mktemp -d)
    if curl -sL "https://registry.npmjs.org/monaco-editor/-/monaco-editor-${MONACO_VERSION}.tgz" -o "$TMP_DIR/monaco.tgz"; then
        mkdir -p "$TMP_DIR/monaco"
        tar -xzf "$TMP_DIR/monaco.tgz" -C "$TMP_DIR/monaco" --strip-components=1
        sudo mkdir -p "$MONACO_DIR"
        sudo cp -r "$TMP_DIR/monaco/min/vs" "$MONACO_DIR/"
        echo "   Monaco Editor installed"
    else
        echo "   [!] Monaco Editor download failed (editor will use CDN fallback)"
    fi
    rm -rf "$TMP_DIR"
fi

# Ensure js-yaml exists for YAML validation
echo "   - Verifying js-yaml..."
JSYAML_VERSION="4.1.0"
if [[ ! -f "$WEB_ROOT/css/js-yaml.min.js" ]]; then
    echo "     Downloading js-yaml..."
    sudo curl -sL "https://cdn.jsdelivr.net/npm/js-yaml@${JSYAML_VERSION}/dist/js-yaml.min.js" -o "$WEB_ROOT/css/js-yaml.min.js" || \
        echo "     [!] js-yaml download failed (will work without offline validation)"
fi

echo "   - Updating VERSION to $WEB_ROOT/"
sudo cp VERSION "$WEB_ROOT/"
sudo chmod 644 "$WEB_ROOT/VERSION"
# Make all shell scripts executable
sudo chmod +x "$WEB_ROOT"/*.sh

# Ensure auth sessions directory exists with correct permissions
# Parent dir must also be accessible by www-data
sudo mkdir -p /var/lib/lldpq/sessions
sudo chown www-data:www-data /var/lib/lldpq
sudo chown www-data:www-data /var/lib/lldpq/sessions
sudo chmod 755 /var/lib/lldpq
sudo chmod 700 /var/lib/lldpq/sessions
echo "   - Sessions directory configured"

# Create users file if it doesn't exist
if [[ ! -f /etc/lldpq-users.conf ]]; then
    ADMIN_HASH=$(echo -n "admin" | openssl dgst -sha256 | awk '{print $2}')
    OPERATOR_HASH=$(echo -n "operator" | openssl dgst -sha256 | awk '{print $2}')
    echo "admin:$ADMIN_HASH:admin" | sudo tee /etc/lldpq-users.conf > /dev/null
    echo "operator:$OPERATOR_HASH:operator" | sudo tee -a /etc/lldpq-users.conf > /dev/null
    echo "   - Created users file with default credentials (admin/admin, operator/operator)"
fi
# Always ensure correct permissions on users file
if [[ -f /etc/lldpq-users.conf ]]; then
    sudo chmod 600 /etc/lldpq-users.conf
    sudo chown www-data:www-data /etc/lldpq-users.conf
fi

echo "   - Setting up topology.dot for web editing"
# If topology.dot exists in web root, it's already set up - just ensure symlink
if [[ -f "$WEB_ROOT/topology.dot" ]]; then
    # Ensure lldpq directory exists before creating symlink
    mkdir -p "$LLDPQ_INSTALL_DIR"
    # Ensure symlink exists
    if [[ ! -L "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
        rm -f "$LLDPQ_INSTALL_DIR/topology.dot" 2>/dev/null
        ln -sf "$WEB_ROOT/topology.dot" "$LLDPQ_INSTALL_DIR/topology.dot"
    fi
else
    # First time setup: move topology.dot to web root
    if [[ -f "$LLDPQ_INSTALL_DIR/topology.dot" ]] && [[ ! -L "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
        sudo mv "$LLDPQ_INSTALL_DIR/topology.dot" "$WEB_ROOT/topology.dot"
        # www-data owns it (for web editing), user's group has access too
        sudo chown "$USER:www-data" "$WEB_ROOT/topology.dot"
        sudo chmod 664 "$WEB_ROOT/topology.dot"
        ln -sf "$WEB_ROOT/topology.dot" "$LLDPQ_INSTALL_DIR/topology.dot"
    fi
fi

echo "   - Setting up topology_config.yaml for web editing"
# If topology_config.yaml exists in web root, ensure symlink
if [[ -f "$WEB_ROOT/topology_config.yaml" ]]; then
    mkdir -p "$LLDPQ_INSTALL_DIR"
    if [[ ! -L "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
        rm -f "$LLDPQ_INSTALL_DIR/topology_config.yaml" 2>/dev/null
        ln -sf "$WEB_ROOT/topology_config.yaml" "$LLDPQ_INSTALL_DIR/topology_config.yaml"
    fi
else
    # First time setup: move topology_config.yaml to web root
    if [[ -f "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]] && [[ ! -L "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
        sudo mv "$LLDPQ_INSTALL_DIR/topology_config.yaml" "$WEB_ROOT/topology_config.yaml"
        sudo chown "$USER:www-data" "$WEB_ROOT/topology_config.yaml"
        sudo chmod 664 "$WEB_ROOT/topology_config.yaml"
        ln -sf "$WEB_ROOT/topology_config.yaml" "$LLDPQ_INSTALL_DIR/topology_config.yaml"
    fi
fi

echo "   - Updating /etc/lldpq.conf"
# Check existing ANSIBLE_DIR from config
ANSIBLE_DIR_EXISTING=""
if [[ -f /etc/lldpq.conf ]]; then
    ANSIBLE_DIR_EXISTING=$(grep "^ANSIBLE_DIR=" /etc/lldpq.conf 2>/dev/null | cut -d= -f2)
fi

# Verify if existing ANSIBLE_DIR still exists
if [[ -n "$ANSIBLE_DIR_EXISTING" ]] && [[ -d "$ANSIBLE_DIR_EXISTING" ]]; then
    echo "     Existing ANSIBLE_DIR still valid: $ANSIBLE_DIR_EXISTING"
    ANSIBLE_DIR="$ANSIBLE_DIR_EXISTING"
    
    # Ensure www-data is in user's group (may have been reset)
    echo "     Ensuring web access permissions..."
    sudo usermod -a -G "$(whoami)" www-data 2>/dev/null || true
    
    # Ensure ansible directory has group write permission
    chmod -R g+rw "$ANSIBLE_DIR" 2>/dev/null || true
    
    # Set default ACL so new files also get group write permission (survives git operations)
    if command -v setfacl &> /dev/null; then
        setfacl -R -d -m g::rwX "$ANSIBLE_DIR" 2>/dev/null || true
    fi
    
    # If git repo exists, add hooks to fix permissions after git operations
    if [[ -d "$ANSIBLE_DIR/.git" ]]; then
        # Create post-merge hook
        cat > "$ANSIBLE_DIR/.git/hooks/post-merge" << 'HOOKEOF'
#!/bin/bash
# Fix permissions after git pull/merge
chmod -R g+rw "$(git rev-parse --show-toplevel)" 2>/dev/null || true
HOOKEOF
        chmod +x "$ANSIBLE_DIR/.git/hooks/post-merge" 2>/dev/null || true
        
        # Create post-checkout hook (for git checkout, git reset)
        cp "$ANSIBLE_DIR/.git/hooks/post-merge" "$ANSIBLE_DIR/.git/hooks/post-checkout" 2>/dev/null || true
    fi
    
    # Add git safe.directory for www-data user
    # First ensure www-data can write to /var/www for .gitconfig
    sudo chmod 775 /var/www 2>/dev/null || true
    sudo chown root:www-data /var/www 2>/dev/null || true
    sudo touch /var/www/.gitconfig 2>/dev/null || true
    sudo chown www-data:www-data /var/www/.gitconfig 2>/dev/null || true
    sudo -u www-data git config --global --add safe.directory "$ANSIBLE_DIR" 2>/dev/null || true
    
    # Configure git sharedRepository for proper group permissions
    git -C "$ANSIBLE_DIR" config core.sharedRepository group 2>/dev/null || true
    
    # Fix existing .git directory permissions
    sudo chown -R "$(whoami):www-data" "$ANSIBLE_DIR/.git" 2>/dev/null || true
    sudo chmod -R g+rwX "$ANSIBLE_DIR/.git" 2>/dev/null || true
else
    if [[ -n "$ANSIBLE_DIR_EXISTING" ]]; then
        echo "     [!] Previous ANSIBLE_DIR no longer exists: $ANSIBLE_DIR_EXISTING"
    fi
    
    # Try to detect ansible directory
    echo "     Searching for Ansible directory..."
    ANSIBLE_DIR=""
    
    # Search all directories in home for ones containing inventory/ and playbooks/
    for dir in "$HOME"/*; do
        if [[ -d "$dir" ]] && [[ -d "$dir/inventory" ]] && [[ -d "$dir/playbooks" ]]; then
            ANSIBLE_DIR="$dir"
            echo "     Found Ansible directory: $ANSIBLE_DIR"
            break
        fi
    done
    
    # Configure web access if found
    if [[ -n "$ANSIBLE_DIR" ]]; then
        echo "     Ensuring web access permissions..."
        sudo usermod -a -G "$(whoami)" www-data 2>/dev/null || true
        
        # Ensure ansible directory has group write permission
        chmod -R g+rw "$ANSIBLE_DIR" 2>/dev/null || true
        
        # Set default ACL so new files also get group write permission (survives git operations)
        if command -v setfacl &> /dev/null; then
            setfacl -R -d -m g::rwX "$ANSIBLE_DIR" 2>/dev/null || true
        fi
        
        # If git repo exists, add hooks to fix permissions after git operations
        if [[ -d "$ANSIBLE_DIR/.git" ]]; then
            # Create post-merge hook
            cat > "$ANSIBLE_DIR/.git/hooks/post-merge" << 'HOOKEOF'
#!/bin/bash
# Fix permissions after git pull/merge
chmod -R g+rw "$(git rev-parse --show-toplevel)" 2>/dev/null || true
HOOKEOF
            chmod +x "$ANSIBLE_DIR/.git/hooks/post-merge" 2>/dev/null || true
            
            # Create post-checkout hook (for git checkout, git reset)
            cp "$ANSIBLE_DIR/.git/hooks/post-merge" "$ANSIBLE_DIR/.git/hooks/post-checkout" 2>/dev/null || true
        fi
        
        # Add git safe.directory for www-data user
        sudo -u www-data git config --global --add safe.directory "$ANSIBLE_DIR" 2>/dev/null || true
        
        # Configure git sharedRepository for proper group permissions
        git -C "$ANSIBLE_DIR" config core.sharedRepository group 2>/dev/null || true
        
        # Fix existing .git directory permissions
        sudo chown -R "$(whoami):www-data" "$ANSIBLE_DIR/.git" 2>/dev/null || true
        sudo chmod -R g+rwX "$ANSIBLE_DIR/.git" 2>/dev/null || true
        
        echo "     Ansible directory configured: $ANSIBLE_DIR"
    else
        ANSIBLE_DIR="$HOME/ansible"
        echo "     No Ansible directory detected, using default: $ANSIBLE_DIR"
    fi
fi

# Write updated config
echo "# LLDPq Configuration" | sudo tee /etc/lldpq.conf > /dev/null
echo "LLDPQ_DIR=$LLDPQ_INSTALL_DIR" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "WEB_ROOT=$WEB_ROOT" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "ANSIBLE_DIR=$ANSIBLE_DIR" | sudo tee -a /etc/lldpq.conf > /dev/null
# Set permissions so web server can update telemetry config
USER_GROUP=$(id -gn)
sudo chown root:$USER_GROUP /etc/lldpq.conf
sudo chmod 664 /etc/lldpq.conf
# Add www-data to user's group for web access
sudo usermod -a -G $USER_GROUP www-data 2>/dev/null || true
echo "     Configuration saved to /etc/lldpq.conf"

echo "   - Updating bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*

echo "   - Verifying Python packages..."
# Check if ruamel.yaml is installed (required for comment-preserving YAML)
if ! python3 -c "import ruamel.yaml" 2>/dev/null; then
    echo "     Installing ruamel.yaml..."
    pip3 install --user ruamel.yaml >/dev/null 2>&1 || \
        pip3 install ruamel.yaml >/dev/null 2>&1 || \
        echo "     [!] ruamel.yaml installation failed - YAML comment preservation may not work"
fi
# Check requests module
if ! python3 -c "import requests" 2>/dev/null; then
    echo "     Installing requests..."
    pip3 install --user requests >/dev/null 2>&1 || \
        pip3 install requests >/dev/null 2>&1 || true
fi
echo "   Python packages verified"
echo "System files updated"

echo ""
echo "[03] Backup monitoring data?"
backup_data_dir=""
if [[ -d "$LLDPQ_INSTALL_DIR/monitor-results" ]] || [[ -d "$LLDPQ_INSTALL_DIR/lldp-results" ]] || [[ -d "$LLDPQ_INSTALL_DIR/alert-states" ]]; then
    echo "   Found existing monitoring data directories:"
    [[ -d "$LLDPQ_INSTALL_DIR/monitor-results" ]] && echo "     • monitor-results/ (contains all analysis results)"
    [[ -d "$LLDPQ_INSTALL_DIR/lldp-results" ]] && echo "     • lldp-results/ (contains LLDP topology data)"
    [[ -d "$LLDPQ_INSTALL_DIR/alert-states" ]] && echo "     • alert-states/ (contains alert history and state tracking)"
    echo ""
    if [[ "$AUTO_YES" == "true" ]]; then
        REPLY="y"
    else
        read -p "Backup and preserve monitoring data? [Y/n]: " -n 1 -r
        echo ""
    fi
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "   [!] Monitoring data will be LOST during update!"
    else
        backup_data_dir=$(mktemp -d)
        echo "   Backing up monitoring data..."
        [[ -d "$LLDPQ_INSTALL_DIR/monitor-results" ]] && cp -r "$LLDPQ_INSTALL_DIR/monitor-results" "$backup_data_dir/"
        [[ -d "$LLDPQ_INSTALL_DIR/lldp-results" ]] && cp -r "$LLDPQ_INSTALL_DIR/lldp-results" "$backup_data_dir/"
        [[ -d "$LLDPQ_INSTALL_DIR/alert-states" ]] && cp -r "$LLDPQ_INSTALL_DIR/alert-states" "$backup_data_dir/"
        echo "   Monitoring data backed up to temporary location"
    fi
else
    echo "   No existing monitoring data found"
fi

echo ""
echo "[04] Updating lldpq directory (preserving configs)..."
# Create temp directory for selective copy
temp_dir=$(mktemp -d)
cp -r lldpq/* "$temp_dir/"

# If monitor exists, preserve config files
if [[ -d "$LLDPQ_INSTALL_DIR" ]]; then
    echo "   - Preserving configuration files:"
    
    if [[ -f "$LLDPQ_INSTALL_DIR/devices.yaml" ]]; then
        echo "     • devices.yaml"
        cp "$LLDPQ_INSTALL_DIR/devices.yaml" "$temp_dir/"
    fi
    
    # hosts.ini deprecated - now using endpoint_hosts in devices.yaml
    
    # topology.dot is now stored in web root with symlink in $LLDPQ_INSTALL_DIR
    # If it's a symlink, just note it; if it's a real file, migrate to web root
    if [[ -L "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
        echo "     • topology.dot (symlink to $WEB_ROOT)"
        # Symlink will be recreated later
    elif [[ -f "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
        echo "     • topology.dot (migrating to $WEB_ROOT)"
        sudo cp "$LLDPQ_INSTALL_DIR/topology.dot" "$WEB_ROOT/topology.dot"
        sudo chown "$USER:www-data" "$WEB_ROOT/topology.dot"
        sudo chmod 664 "$WEB_ROOT/topology.dot"
    fi
    
    # topology_config.yaml is stored in web root with symlink in $LLDPQ_INSTALL_DIR
    if [[ -L "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
        echo "     • topology_config.yaml (symlink to $WEB_ROOT)"
        # Symlink will be recreated later
    elif [[ -f "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
        echo "     • topology_config.yaml (migrating to $WEB_ROOT)"
        sudo cp "$LLDPQ_INSTALL_DIR/topology_config.yaml" "$WEB_ROOT/topology_config.yaml"
        sudo chown "$USER:www-data" "$WEB_ROOT/topology_config.yaml"
        sudo chmod 664 "$WEB_ROOT/topology_config.yaml"
    fi
    
    if [[ -f "$LLDPQ_INSTALL_DIR/notifications.yaml" ]]; then
        echo "     • notifications.yaml"
        cp "$LLDPQ_INSTALL_DIR/notifications.yaml" "$temp_dir/"
    fi
    
    # Check if lldpq processes are running before removing directory
    if pgrep -f "$LLDPQ_INSTALL_DIR/monitor.sh" >/dev/null 2>&1 || pgrep -f "/usr/local/bin/lldpq-trigger" >/dev/null 2>&1; then
        echo ""
        echo "   [!] WARNING: LLDPq processes are currently running!"
        if [[ "$AUTO_YES" == "true" ]]; then
            REPLY="y"
        else
            read -p "   Stop processes and continue? [Y/n]: " -n 1 -r
            echo ""
        fi
        if [[ ! $REPLY =~ ^[Nn]$ ]]; then
            echo "   Stopping lldpq processes..."
            pkill -f "$LLDPQ_INSTALL_DIR/monitor.sh" 2>/dev/null || true
            pkill -f "/usr/local/bin/lldpq-trigger" 2>/dev/null || true
            sleep 2
            echo "   Processes stopped"
        else
            echo "   [!] Proceeding with running processes (may cause issues)"
        fi
    fi
    
    # Remove old lldpq directory (now safer)
    echo "   - Removing old lldpq directory..."
    rm -rf "$LLDPQ_INSTALL_DIR"
fi

# Copy updated files with preserved configs
mv "$temp_dir" "$LLDPQ_INSTALL_DIR"

# Update telemetry stack (preserve user config files)
echo "   - Updating telemetry stack..."
if [[ -d "telemetry" ]]; then
    # Preserve user-modified config files
    if [[ -d "$LLDPQ_INSTALL_DIR/telemetry/config" ]]; then
        cp -r "$LLDPQ_INSTALL_DIR/telemetry/config" /tmp/lldpq-telemetry-config-backup 2>/dev/null || true
    fi
    
    cp -r telemetry "$LLDPQ_INSTALL_DIR/telemetry"
    chmod +x "$LLDPQ_INSTALL_DIR/telemetry/start.sh"
    
    # Restore user config files
    if [[ -d /tmp/lldpq-telemetry-config-backup ]]; then
        cp -r /tmp/lldpq-telemetry-config-backup/* "$LLDPQ_INSTALL_DIR/telemetry/config/" 2>/dev/null || true
        rm -rf /tmp/lldpq-telemetry-config-backup
        echo "     • telemetry config preserved"
    fi
fi

echo "   - Setting permissions on $LLDPQ_INSTALL_DIR for web access (search-api.sh)"
# www-data needs read+write access to devices.yaml (web UI editor) and read to monitor-results
chmod 750 $LLDPQ_INSTALL_DIR  # user=rwx, group=rx, other=none
chown "$LLDPQ_USER":www-data $LLDPQ_INSTALL_DIR/devices.yaml 2>/dev/null || true
chmod 664 $LLDPQ_INSTALL_DIR/devices.yaml 2>/dev/null || true  # user=rw, group=rw, other=r (web UI needs write)
mkdir -p $LLDPQ_INSTALL_DIR/monitor-results/fabric-tables 2>/dev/null || true
chmod 750 $LLDPQ_INSTALL_DIR/monitor-results 2>/dev/null || true
chmod 750 $LLDPQ_INSTALL_DIR/monitor-results/fabric-tables 2>/dev/null || true

# Set default ACL so new files/directories also get group read permission (survives git operations)
if command -v setfacl &> /dev/null; then
    setfacl -R -d -m g::rX $LLDPQ_INSTALL_DIR 2>/dev/null || true
    echo "   Default ACL set (new files will inherit group read permission)"
fi

# Add/update git hooks to preserve permissions after git operations
if [[ -d $LLDPQ_INSTALL_DIR/.git ]]; then
    echo "   - Updating git hooks for permission preservation..."
    cat > $LLDPQ_INSTALL_DIR/.git/hooks/post-merge << 'HOOKEOF'
#!/bin/bash
# Fix permissions after git pull/merge (preserve group read access for www-data)
chmod 750 "$(git rev-parse --show-toplevel)" 2>/dev/null || true
chmod 664 "$(git rev-parse --show-toplevel)/devices.yaml" 2>/dev/null || true
if [ -d "$(git rev-parse --show-toplevel)/monitor-results" ]; then
    chmod -R 750 "$(git rev-parse --show-toplevel)/monitor-results" 2>/dev/null || true
fi
HOOKEOF
    chmod +x $LLDPQ_INSTALL_DIR/.git/hooks/post-merge
    cp $LLDPQ_INSTALL_DIR/.git/hooks/post-merge $LLDPQ_INSTALL_DIR/.git/hooks/post-checkout
    
    # Configure git for group permissions
    git -C $LLDPQ_INSTALL_DIR config core.sharedRepository group 2>/dev/null || true
    echo "   Git hooks updated (permissions preserved after git operations)"
fi
echo "   Group read permissions set (www-data can access via group)"

# Ensure topology.dot symlink exists (after lldpq directory is created)
if [[ -f "$WEB_ROOT/topology.dot" ]] && [[ ! -L "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
    mkdir -p "$LLDPQ_INSTALL_DIR"  # Ensure directory exists
    rm -f "$LLDPQ_INSTALL_DIR/topology.dot" 2>/dev/null
    ln -sf "$WEB_ROOT/topology.dot" "$LLDPQ_INSTALL_DIR/topology.dot"
fi

# Ensure topology_config.yaml symlink exists (after lldpq directory is created)
if [[ -f "$WEB_ROOT/topology_config.yaml" ]] && [[ ! -L "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
    mkdir -p "$LLDPQ_INSTALL_DIR"  # Ensure directory exists
    rm -f "$LLDPQ_INSTALL_DIR/topology_config.yaml" 2>/dev/null
    ln -sf "$WEB_ROOT/topology_config.yaml" "$LLDPQ_INSTALL_DIR/topology_config.yaml"
fi
echo "lldpq directory updated with preserved configs"

# Restore monitoring data if backed up
if [[ -n "$backup_data_dir" ]] && [[ -d "$backup_data_dir" ]]; then
    echo ""
    echo "   Restoring monitoring data..."
    [[ -d "$backup_data_dir/monitor-results" ]] && cp -r "$backup_data_dir/monitor-results" "$LLDPQ_INSTALL_DIR/"
    [[ -d "$backup_data_dir/lldp-results" ]] && cp -r "$backup_data_dir/lldp-results" "$LLDPQ_INSTALL_DIR/"
    [[ -d "$backup_data_dir/alert-states" ]] && cp -r "$backup_data_dir/alert-states" "$LLDPQ_INSTALL_DIR/"
    echo "   Monitoring data restored successfully"
    # Clean up temporary backup
    rm -rf "$backup_data_dir"
fi

echo ""
echo "[05] Updating cron jobs..."
# Add Fabric Scan cron job if Ansible directory exists and not already configured
if [[ -d "$ANSIBLE_DIR" ]] && [[ -d "$ANSIBLE_DIR/playbooks" ]]; then
    if ! grep -q "fabric-scan-cron.sh" /etc/crontab 2>/dev/null; then
        echo "33 3 * * * $(whoami) $LLDPQ_INSTALL_DIR/fabric-scan-cron.sh" | sudo tee -a /etc/crontab > /dev/null
        echo "   Added Fabric Scan cron job (daily at 03:33)"
    else
        echo "   Fabric Scan cron job already configured"
    fi
    chmod +x $LLDPQ_INSTALL_DIR/fabric-scan-cron.sh 2>/dev/null || true
    # Ensure cache file exists with correct permissions
    if [[ ! -f "$WEB_ROOT/fabric-scan-cache.json" ]]; then
        sudo touch "$WEB_ROOT/fabric-scan-cache.json"
    fi
    sudo chown "$(whoami):www-data" "$WEB_ROOT/fabric-scan-cache.json" 2>/dev/null || true
    sudo chmod 664 "$WEB_ROOT/fabric-scan-cache.json" 2>/dev/null || true
fi

echo ""
echo "[06] Checking permissions and sudoers..."
# Ensure sudoers is configured for www-data to run SSH as LLDPQ user
if [[ ! -f /etc/sudoers.d/www-data-lldpq ]]; then
    LLDPQ_USER="${LLDPQ_USER:-$(whoami)}"
    echo "   Configuring sudoers for network device access..."
    echo "www-data ALL=($LLDPQ_USER) NOPASSWD: /usr/bin/timeout, /usr/bin/ssh" | sudo tee /etc/sudoers.d/www-data-lldpq > /dev/null
    sudo chmod 440 /etc/sudoers.d/www-data-lldpq
    echo "   Sudoers configured for MAC/ARP table access"
else
    echo "   Sudoers already configured"
fi

# Ensure LLDPQ_USER is in config
if ! grep -q "^LLDPQ_USER=" /etc/lldpq.conf 2>/dev/null; then
    echo "LLDPQ_USER=$(whoami)" | sudo tee -a /etc/lldpq.conf > /dev/null
    echo "   Added LLDPQ_USER to /etc/lldpq.conf"
fi

echo ""
echo "[07] Restarting web services..."
sudo systemctl restart nginx
sudo systemctl restart fcgiwrap
echo "nginx and fcgiwrap restarted"

echo ""
echo "[08] Data preservation summary:"
echo "   The following files/directories were preserved:"
echo "   Configuration files:"
# nccm.yml removed - zzh uses devices.yaml
# hosts.ini removed - now using endpoint_hosts in devices.yaml
echo "     • $LLDPQ_INSTALL_DIR/devices.yaml (includes endpoint_hosts for topology)"
echo "     • $WEB_ROOT/topology.dot (web-editable, symlinked from $LLDPQ_INSTALL_DIR)"
echo "     • $WEB_ROOT/topology_config.yaml (web-editable, symlinked from $LLDPQ_INSTALL_DIR)"
echo "     • $LLDPQ_INSTALL_DIR/notifications.yaml"
if [[ -n "$backup_data_dir" ]] || [[ -d "$LLDPQ_INSTALL_DIR/monitor-results" ]] || [[ -d "$LLDPQ_INSTALL_DIR/lldp-results" ]] || [[ -d "$LLDPQ_INSTALL_DIR/alert-states" ]]; then
    echo "   Monitoring data directories:"
    [[ -d "$LLDPQ_INSTALL_DIR/monitor-results" ]] && echo "     • monitor-results/ (all analysis results preserved)"
    [[ -d "$LLDPQ_INSTALL_DIR/lldp-results" ]] && echo "     • lldp-results/ (LLDP topology data preserved)"
    [[ -d "$LLDPQ_INSTALL_DIR/alert-states" ]] && echo "     • alert-states/ (alert history and state tracking preserved)"
fi

echo ""
echo "[09] Testing updated tools..."
echo "   You can test the updated tools:"
echo "   - lldpq"
echo "   - get-conf"
echo "   - zzh"
echo "   - pping"

echo ""
echo "Update Complete!"
echo "   Features available:"
echo "   - BGP Neighbor Analysis"
echo "   - Link Flap Detection"
echo "   - Hardware Health Analysis"
echo "   - Log Analysis with Severity Filtering"
echo "   - Slack Alert Integration with Smart Notifications"
echo "   - Enhanced monitoring capabilities"
echo "   - Data preservation during updates"
echo ""
echo "   Web interface: http://$(hostname -I | awk '{print $1}')"
echo ""
if [[ -n "$backup_dir" ]]; then
    echo "If you encounter issues, your backup is available at:"
    echo "      $backup_dir"
fi
echo "LLDPq update completed successfully!"
echo ""