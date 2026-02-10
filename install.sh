#!/usr/bin/env bash
# LLDPq Installation Script
# 
# Copyright (c) 2024-2026 LLDPq Project  
# Licensed under MIT License - see LICENSE file for details
#
# Usage: ./install.sh [-y]
#   -y  Auto-yes to all prompts (non-interactive mode, uses defaults)

set -e

# Parse arguments
AUTO_YES=false
while getopts "y" opt; do
    case $opt in
        y) AUTO_YES=true ;;
        *) ;;
    esac
done

echo "LLDPq Installation Script"
echo "=================================="
if [[ "$AUTO_YES" == "true" ]]; then
    echo "   Running in non-interactive mode (-y)"
fi

# Check if running via sudo from non-root user (causes $HOME issues)
if [[ $EUID -eq 0 ]] && [[ -n "$SUDO_USER" ]] && [[ "$SUDO_USER" != "root" ]]; then
    echo "[!] Please run without sudo: ./install.sh"
    echo "   The script will ask for sudo when needed"
    exit 1
fi

# Running as root is OK (for dedicated servers)
# Use /opt/lldpq for root to allow www-data access
if [[ $EUID -eq 0 ]]; then
    LLDPQ_INSTALL_DIR="/opt/lldpq"
    echo ""
    echo "[!] Running as root"
    echo "    Files will be installed in $LLDPQ_INSTALL_DIR"
    echo "    Recommended: Install as a regular user (e.g., 'nvidia' or 'cumulus')"
    echo "    This allows better SSH key management and security."
    echo ""
    sleep 2
else
    LLDPQ_INSTALL_DIR="$HOME/lldpq"
fi

# Check if we're in the lldpq-src directory
if [[ ! -f "README.md" ]] || [[ ! -d "lldpq" ]]; then
    echo "[!] Please run this script from the lldpq-src directory"
    echo "   Make sure you're in the directory containing README.md and lldpq/"
    exit 1
fi

# Web root directory (default for Linux, can be changed in /etc/lldpq.conf for macOS etc.)
WEB_ROOT="/var/www/html"

echo ""
echo "[00] Checking for existing installation..."

# Detect existing LLDPq installation
EXISTING_INSTALL=false
if [[ -f /etc/lldpq.conf ]] || [[ -f /etc/lldpq-users.conf ]] || [[ -d /var/lib/lldpq ]]; then
    EXISTING_INSTALL=true
    echo "   [!] Existing LLDPq installation detected:"
    [[ -f /etc/lldpq.conf ]] && echo "     • /etc/lldpq.conf"
    [[ -f /etc/lldpq-users.conf ]] && echo "     • /etc/lldpq-users.conf (user credentials)"
    [[ -d /var/lib/lldpq ]] && echo "     • /var/lib/lldpq/ (sessions)"
    [[ -d "$LLDPQ_INSTALL_DIR" ]] && echo "     • $LLDPQ_INSTALL_DIR/ (scripts and configs)"
    echo ""
    echo "   Options:"
    echo "   1. Clean install - remove old files and start fresh (recommended if broken)"
    echo "   2. Keep existing - preserve user credentials and continue"
    echo ""
    if [[ "$AUTO_YES" == "true" ]]; then
        clean_response="n"
        echo "   Keeping existing files (auto-yes mode)"
    else
        read -p "   Clean install? [y/N]: " clean_response
    fi
    if [[ "$clean_response" =~ ^[Yy]$ ]]; then
        echo "   Cleaning existing installation..."
        sudo rm -f /etc/lldpq.conf
        sudo rm -f /etc/lldpq-users.conf
        sudo rm -rf /var/lib/lldpq
        # Don't remove ~/lldpq here - it has user configs like devices.yaml
        echo "   Old installation files removed"
    else
        echo "   Keeping existing files"
    fi
else
    echo "   No existing installation found - fresh install"
fi

echo ""
echo "[01] Checking for conflicting services..."

# Check if Apache2 is running (would conflict with nginx on port 80)
if systemctl is-active --quiet apache2 2>/dev/null; then
    echo "[!] Apache2 is running on port 80!"
    echo "   LLDPq uses nginx as web server."
    echo ""
    echo "   Options:"
    echo "   1. Stop Apache2 (recommended for LLDPq)"
    echo "   2. Exit and resolve manually"
    echo ""
    if [[ "$AUTO_YES" == "true" ]]; then
        response="y"
        echo "   Stopping Apache2 (auto-yes mode)"
    else
        read -p "   Stop and disable Apache2? [Y/n]: " response
    fi
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        sudo systemctl stop apache2
        sudo systemctl disable apache2
        echo "   Apache2 stopped and disabled"
    else
        echo "   [!] Please stop Apache2 or configure nginx to use a different port"
        echo "   Edit /etc/nginx/sites-available/lldpq to change the port"
        exit 1
    fi
fi

echo ""
echo "[02] Installing required packages..."
sudo apt update || { echo "[!] apt update failed"; exit 1; }
sudo apt install -y nginx fcgiwrap python3 python3-pip python3-yaml util-linux bsdextrautils sshpass unzip acl || {
    echo "[!] Package installation failed"
    echo "   Try running: sudo apt --fix-broken install"
    exit 1
}
sudo systemctl enable --now nginx
sudo systemctl enable --now fcgiwrap

echo ""
echo "[02b] Downloading Monaco Editor for offline use..."
MONACO_VERSION="0.45.0"
MONACO_DIR="$WEB_ROOT/monaco"
if [[ ! -d "$MONACO_DIR" ]]; then
    echo "   - Downloading Monaco Editor v${MONACO_VERSION}..."
    TMP_DIR=$(mktemp -d)
    if curl -sL "https://registry.npmjs.org/monaco-editor/-/monaco-editor-${MONACO_VERSION}.tgz" -o "$TMP_DIR/monaco.tgz"; then
        mkdir -p "$TMP_DIR/monaco"
        tar -xzf "$TMP_DIR/monaco.tgz" -C "$TMP_DIR/monaco" --strip-components=1
        sudo mkdir -p "$MONACO_DIR"
        sudo cp -r "$TMP_DIR/monaco/min/vs" "$MONACO_DIR/"
        echo "   Monaco Editor installed to $MONACO_DIR"
    else
        echo "   [!] Monaco Editor download failed (editor will use CDN fallback)"
    fi
    rm -rf "$TMP_DIR"
else
    echo "   Monaco Editor already exists, skipping download"
fi

# Install Python packages for LLDPq
echo "   - Installing Python packages..."
pip3 install --user requests ruamel.yaml >/dev/null 2>&1 || \
    pip3 install requests ruamel.yaml >/dev/null 2>&1 || \
    echo "   [!] Some Python packages may need manual installation"
echo "   Python packages installed (requests, ruamel.yaml)"

echo ""
echo "[03] Copying files to system directories..."
echo "   - Copying etc/* to /etc/"
sudo cp -r etc/* /etc/

echo "   - Copying html/* to $WEB_ROOT/"
sudo cp -r html/* "$WEB_ROOT/"

echo "   - Downloading js-yaml for YAML validation..."
JSYAML_VERSION="4.1.0"
if [[ ! -f "$WEB_ROOT/css/js-yaml.min.js" ]]; then
    sudo curl -sL "https://cdn.jsdelivr.net/npm/js-yaml@${JSYAML_VERSION}/dist/js-yaml.min.js" -o "$WEB_ROOT/css/js-yaml.min.js" || \
        echo "   [!] js-yaml download failed (will work without offline validation)"
    echo "   js-yaml installed"
else
    echo "   js-yaml already exists, skipping download"
fi

echo "   - Copying VERSION to $WEB_ROOT/"
sudo cp VERSION "$WEB_ROOT/"
sudo chmod 644 "$WEB_ROOT/VERSION"
# Make all shell scripts executable
sudo chmod +x "$WEB_ROOT"/*.sh

echo "   - Setting permissions on web directories"
# Ensure /var/www is traversable (some systems restrict it)
sudo chmod o+rx /var/www 2>/dev/null || true
# Set ownership: LLDPQ_USER owns files, www-data group for CGI write access
sudo chown -R "$USER:www-data" "$WEB_ROOT/"
# Directories: rwxrwxr-x (user+group can write, others can read/traverse)
sudo find "$WEB_ROOT" -type d -exec chmod 775 {} \;
# Files: rw-rw-r-- (user+group can write, others can read)
sudo find "$WEB_ROOT" -type f -exec chmod 664 {} \;
# Shell scripts need execute
sudo chmod +x "$WEB_ROOT"/*.sh
# Ensure writable directories for runtime data
sudo mkdir -p "$WEB_ROOT/hstr" "$WEB_ROOT/configs" "$WEB_ROOT/monitor-results"

echo "   - Copying bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*

echo "   - Copying lldpq to $LLDPQ_INSTALL_DIR"
mkdir -p "$LLDPQ_INSTALL_DIR"
cp -r lldpq/* "$LLDPQ_INSTALL_DIR/"

echo "   - Copying telemetry stack to $LLDPQ_INSTALL_DIR/telemetry"
cp -r telemetry "$LLDPQ_INSTALL_DIR/telemetry"
chmod +x "$LLDPQ_INSTALL_DIR/telemetry/start.sh"

echo "   - Setting permissions on $LLDPQ_INSTALL_DIR for web access (search-api.sh)"
# www-data needs read+write access to devices.yaml (web UI editor) and read to monitor-results
chmod 750 "$LLDPQ_INSTALL_DIR"  # user=rwx, group=rx, other=none
chown "$LLDPQ_USER":www-data "$LLDPQ_INSTALL_DIR/devices.yaml" 2>/dev/null || true
chmod 664 "$LLDPQ_INSTALL_DIR/devices.yaml"  # user=rw, group=rw, other=r (web UI needs write)
mkdir -p "$LLDPQ_INSTALL_DIR/monitor-results/fabric-tables"
chmod 750 "$LLDPQ_INSTALL_DIR/monitor-results"
chmod 750 "$LLDPQ_INSTALL_DIR/monitor-results/fabric-tables"

# Set default ACL so new files/directories also get group read permission (survives git operations)
if command -v setfacl &> /dev/null; then
    setfacl -R -d -m g::rX "$LLDPQ_INSTALL_DIR" 2>/dev/null || true
    echo "   Default ACL set (new files will inherit group read permission)"
fi
echo "   Group read permissions set (www-data can access via group)"

echo "   - Setting up topology.dot for web editing"
# Handle topology.dot - may be symlink from previous install, regular file, or not exist
if [[ -L "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
    # Already a symlink - just ensure web root file has correct permissions
    echo "     topology.dot symlink already exists"
    if [[ -f "$WEB_ROOT/topology.dot" ]]; then
        sudo chown "www-data:$USER" "$WEB_ROOT/topology.dot"
        sudo chmod 664 "$WEB_ROOT/topology.dot"
    fi
elif [[ -f "$LLDPQ_INSTALL_DIR/topology.dot" ]]; then
    # Regular file - move to web root and create symlink
    sudo mv "$LLDPQ_INSTALL_DIR/topology.dot" "$WEB_ROOT/topology.dot"
    sudo chown "www-data:$USER" "$WEB_ROOT/topology.dot"
    sudo chmod 664 "$WEB_ROOT/topology.dot"
    ln -sf "$WEB_ROOT/topology.dot" "$LLDPQ_INSTALL_DIR/topology.dot"
else
    # No file exists - create empty one in web root
    echo "     topology.dot not found, creating empty file"
    if [[ ! -f "$WEB_ROOT/topology.dot" ]]; then
        echo "# LLDPq Topology Definition" | sudo tee "$WEB_ROOT/topology.dot" > /dev/null
    fi
    sudo chown "www-data:$USER" "$WEB_ROOT/topology.dot"
    sudo chmod 664 "$WEB_ROOT/topology.dot"
    ln -sf "$WEB_ROOT/topology.dot" "$LLDPQ_INSTALL_DIR/topology.dot"
fi

echo "   - Setting up topology_config.yaml for web editing"
# Handle topology_config.yaml - may be symlink from previous install, regular file, or not exist
if [[ -L "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
    # Already a symlink - just ensure web root file has correct permissions
    echo "     topology_config.yaml symlink already exists"
    if [[ -f "$WEB_ROOT/topology_config.yaml" ]]; then
        sudo chown "www-data:$USER" "$WEB_ROOT/topology_config.yaml"
        sudo chmod 664 "$WEB_ROOT/topology_config.yaml"
    fi
elif [[ -f "$LLDPQ_INSTALL_DIR/topology_config.yaml" ]]; then
    # Regular file - move to web root and create symlink
    sudo mv "$LLDPQ_INSTALL_DIR/topology_config.yaml" "$WEB_ROOT/topology_config.yaml"
    sudo chown "www-data:$USER" "$WEB_ROOT/topology_config.yaml"
    sudo chmod 664 "$WEB_ROOT/topology_config.yaml"
    ln -sf "$WEB_ROOT/topology_config.yaml" "$LLDPQ_INSTALL_DIR/topology_config.yaml"
fi

echo "   - Detecting Ansible directory..."
# Try to detect ansible directory by searching for directories with inventory/ and playbooks/
ANSIBLE_DIR=""

# Search all directories in home for ones containing inventory/ and playbooks/
for dir in "$HOME"/*; do
    if [[ -d "$dir" ]] && [[ -d "$dir/inventory" ]] && [[ -d "$dir/playbooks" ]]; then
        ANSIBLE_DIR="$dir"
        echo ""
        echo "   Found Ansible directory: $ANSIBLE_DIR"
        break
    fi
done

if [[ -z "$ANSIBLE_DIR" ]]; then
    echo "   Ansible directory not detected automatically"
    echo ""
    echo "   Looking for a directory containing:"
    echo "     - inventory/ (Ansible inventory files)"
    echo "     - playbooks/ (Ansible playbooks)"
    echo "     - roles/ (optional, Ansible roles)"
fi

# Ask user for Ansible directory
echo ""
if [[ "$AUTO_YES" == "true" ]]; then
    # In auto-yes mode, use detected dir or default
    if [[ -n "$ANSIBLE_DIR" ]]; then
        echo "   Using detected Ansible directory: $ANSIBLE_DIR (auto-yes mode)"
    else
        ANSIBLE_DIR="$HOME/ansible"
        echo "   Using default Ansible directory: $ANSIBLE_DIR (auto-yes mode)"
    fi
else
    # Interactive mode
    if [[ -n "$ANSIBLE_DIR" ]]; then
        read -p "   Use detected Ansible directory? [Y/n] or enter custom path: " response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            read -p "   Enter Ansible directory path (or 'skip' to skip Ansible): " custom_path
            if [[ "$custom_path" == "skip" ]] || [[ -z "$custom_path" ]]; then
                ANSIBLE_DIR=""
                echo "   Skipping Ansible configuration"
            else
                ANSIBLE_DIR="$custom_path"
            fi
        elif [[ -n "$response" ]] && [[ ! "$response" =~ ^[Yy]$ ]]; then
            # User entered a custom path
            if [[ "$response" == "skip" ]]; then
                ANSIBLE_DIR=""
                echo "   Skipping Ansible configuration"
            else
                ANSIBLE_DIR="$response"
            fi
        fi
    else
        read -p "   Enter Ansible directory path (or press Enter to use ~/ansible, or 'skip'): " response
        if [[ "$response" == "skip" ]]; then
            ANSIBLE_DIR=""
            echo "   Skipping Ansible configuration"
        else
            ANSIBLE_DIR="${response:-$HOME/ansible}"
        fi
    fi
fi

# Validate ansible directory
if [[ -n "$ANSIBLE_DIR" ]] && [[ -d "$ANSIBLE_DIR" ]]; then
    echo "   Using Ansible directory: $ANSIBLE_DIR"
    
    # Add www-data to current user's group for ansible file access
    echo "   Configuring web access permissions..."
    sudo usermod -a -G "$(whoami)" www-data
    echo "   www-data user added to $(whoami) group"
    
    # Ensure ansible directory has group write permission (for file editing/delete)
    chmod -R g+rw "$ANSIBLE_DIR" 2>/dev/null || true
    echo "   Group write permission set on ansible directory"
    
    # Set default ACL so new files also get group write permission (survives git operations)
    if command -v setfacl &> /dev/null; then
        setfacl -R -d -m g::rwX "$ANSIBLE_DIR" 2>/dev/null || true
        echo "   Default ACL set (new files will inherit group write permission)"
    fi
    
    # If git repo exists, add hooks to fix permissions after git operations
    if [[ -d "$ANSIBLE_DIR/.git" ]]; then
        echo "   Setting up git hooks for permission management..."
        
        # Create post-merge hook
        cat > "$ANSIBLE_DIR/.git/hooks/post-merge" << 'HOOKEOF'
#!/bin/bash
# Fix permissions after git pull/merge
chmod -R g+rw "$(git rev-parse --show-toplevel)" 2>/dev/null || true
HOOKEOF
        chmod +x "$ANSIBLE_DIR/.git/hooks/post-merge"
        
        # Create post-checkout hook (for git checkout, git reset)
        cp "$ANSIBLE_DIR/.git/hooks/post-merge" "$ANSIBLE_DIR/.git/hooks/post-checkout"
        
        echo "   Git hooks created (post-merge, post-checkout)"
    fi
    
    # Add git safe.directory for www-data user (for git operations from web)
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
    
    echo "   Git safe.directory and sharedRepository configured for web access"
    
    # Configure sudoers for www-data to run SSH commands as LLDPQ user (for search-api.sh)
    echo "   Configuring sudoers for network device access..."
    echo "www-data ALL=($(whoami)) NOPASSWD: /usr/bin/timeout, /usr/bin/ssh" | sudo tee /etc/sudoers.d/www-data-lldpq > /dev/null
    sudo chmod 440 /etc/sudoers.d/www-data-lldpq
    echo "   Sudoers configured for MAC/ARP table access"
elif [[ -n "$ANSIBLE_DIR" ]]; then
    # User specified a path but it doesn't exist
    echo "   [!] Warning: Ansible directory '$ANSIBLE_DIR' does not exist"
    echo "   It will be created when needed or you can create it manually"
fi

# Set default if empty
if [[ -z "$ANSIBLE_DIR" ]]; then
    ANSIBLE_DIR="$HOME/ansible"
    echo "   Using default: $ANSIBLE_DIR (will be created when needed)"
fi

echo ""
echo "   - Creating /etc/lldpq.conf"
echo "# LLDPq Configuration" | sudo tee /etc/lldpq.conf > /dev/null
echo "LLDPQ_DIR=$LLDPQ_INSTALL_DIR" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "LLDPQ_USER=$(whoami)" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "WEB_ROOT=$WEB_ROOT" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "ANSIBLE_DIR=$ANSIBLE_DIR" | sudo tee -a /etc/lldpq.conf > /dev/null
# Set permissions so web server can update telemetry config
USER_GROUP=$(id -gn)
sudo chown root:$USER_GROUP /etc/lldpq.conf
sudo chmod 664 /etc/lldpq.conf
# Add www-data to user's group for web access
sudo usermod -a -G $USER_GROUP www-data 2>/dev/null || true
echo "   Configuration saved to /etc/lldpq.conf"
echo "Files copied successfully"

echo ""
echo "[04] Configuration files to edit:"
echo "   You need to manually edit these files with your network details:"
echo ""
echo "   1. nano $LLDPQ_INSTALL_DIR/devices.yaml           # Define your network devices (required)"
echo "   2. nano $LLDPQ_INSTALL_DIR/topology.dot           # Define your network topology"
echo "   Note: zzh (SSH manager) automatically loads devices from devices.yaml"
echo ""
echo "   See README.md for examples of each file format"

echo ""
echo "[05] Configuring nginx..."

# Enable LLDPq site
sudo ln -sf /etc/nginx/sites-available/lldpq /etc/nginx/sites-enabled/lldpq

# Disable Default site (if exists)
[ -L /etc/nginx/sites-enabled/default ] && sudo unlink /etc/nginx/sites-enabled/default || true

# Test and restart nginx and fcgiwrap
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl restart fcgiwrap
echo "nginx and fcgiwrap configured and restarted"

echo ""
echo "[05b] Setting up authentication..."

# Create sessions directory (parent dir must also be accessible by www-data)
sudo mkdir -p /var/lib/lldpq/sessions
sudo chown www-data:www-data /var/lib/lldpq
sudo chown www-data:www-data /var/lib/lldpq/sessions
sudo chmod 755 /var/lib/lldpq
sudo chmod 700 /var/lib/lldpq/sessions
echo "   - Sessions directory created"

# Create users file with default passwords
if [[ ! -f /etc/lldpq-users.conf ]]; then
    # Hash passwords: admin/admin, operator/operator
    ADMIN_HASH=$(echo -n "admin" | openssl dgst -sha256 | awk '{print $2}')
    OPERATOR_HASH=$(echo -n "operator" | openssl dgst -sha256 | awk '{print $2}')
    
    echo "admin:$ADMIN_HASH:admin" | sudo tee /etc/lldpq-users.conf > /dev/null
    echo "operator:$OPERATOR_HASH:operator" | sudo tee -a /etc/lldpq-users.conf > /dev/null
    sudo chmod 600 /etc/lldpq-users.conf
    sudo chown www-data:www-data /etc/lldpq-users.conf
    echo "   - Users file created with default credentials:"
    echo "     admin / admin"
    echo "     operator / operator"
    echo "   [!] IMPORTANT: Change default passwords after first login!"
else
    echo "   - Users file already exists, keeping existing credentials"
fi

echo "   - Authentication API configured"

echo ""
echo "[06] Adding cron jobs..."
# Remove existing LLDPq cron jobs if they exist
sudo sed -i '/lldpq\|monitor\|get-conf\|fabric-scan/d' /etc/crontab

# Add new cron jobs
echo "*/5 * * * * $(whoami) /usr/local/bin/lldpq" | sudo tee -a /etc/crontab > /dev/null
echo "0 */12 * * * $(whoami) /usr/local/bin/get-conf" | sudo tee -a /etc/crontab > /dev/null
echo "* * * * * $(whoami) /usr/local/bin/lldpq-trigger" | sudo tee -a /etc/crontab > /dev/null
echo "* * * * * $(whoami) cd $LLDPQ_INSTALL_DIR && ./fabric-scan.sh >/dev/null 2>&1" | sudo tee -a /etc/crontab > /dev/null
echo "0 0 * * * $(whoami) cd $LLDPQ_INSTALL_DIR && cp /var/www/html/topology.dot topology.dot.bkp 2>/dev/null; cp /var/www/html/topology_config.yaml topology_config.yaml.bkp 2>/dev/null; git add -A; git diff --cached --quiet || git commit -m 'auto: \$(date +\\%Y-\\%m-\\%d)'" | sudo tee -a /etc/crontab > /dev/null

# Add Fabric Scan cron job if Ansible directory exists
if [[ -d "$ANSIBLE_DIR" ]] && [[ -d "$ANSIBLE_DIR/playbooks" ]]; then
    echo "33 3 * * * $(whoami) $LLDPQ_INSTALL_DIR/fabric-scan-cron.sh" | sudo tee -a /etc/crontab > /dev/null
    chmod +x "$LLDPQ_INSTALL_DIR/fabric-scan-cron.sh"
    # Create cache file with user write permission
    sudo touch "$WEB_ROOT/fabric-scan-cache.json"
    sudo chown "$(whoami):www-data" "$WEB_ROOT/fabric-scan-cache.json"
    sudo chmod 664 "$WEB_ROOT/fabric-scan-cache.json"
    echo "   - fabric-scan:     daily at 03:33 (Ansible diff check)"
fi

echo "Cron jobs added:"
echo "   - lldpq:           every 5 minutes (system monitoring)"  
echo "   - get-conf:        every 12 hours"
echo "   - web triggers:    daemon (checks every 5 seconds, enables Run LLDP Check button)"
echo "   - git auto-commit: daily at midnight (tracks config changes)"

echo ""
echo "[07] Streaming Telemetry (Optional)"
echo "   Telemetry provides real-time metrics dashboard with:"
echo "   - Interface throughput, errors, drops charts"
echo "   - Platform temperature monitoring"
echo "   - Active alerts from Prometheus"
echo "   - Requires Docker to run OTEL Collector + Prometheus"
echo ""

TELEMETRY_ENABLED=false
if [[ "$AUTO_YES" == "true" ]]; then
    echo "   Skipping telemetry (auto-yes mode, run './update.sh --enable-telemetry' later)"
else
    read -p "   Enable streaming telemetry support? [y/N]: " telemetry_response
    if [[ "$telemetry_response" =~ ^[Yy]$ ]]; then
        TELEMETRY_ENABLED=true
    fi
fi

if [[ "$TELEMETRY_ENABLED" == "true" ]]; then
    echo ""
    echo "   Checking Docker installation..."
    
    if ! command -v docker &> /dev/null; then
        echo "   Docker not found. Installing Docker..."
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sudo sh /tmp/get-docker.sh
        sudo usermod -aG docker "$(whoami)"
        rm /tmp/get-docker.sh
        echo "   Docker installed successfully"
        echo "   [!] NOTE: You may need to logout/login for Docker group to take effect"
    else
        echo "   Docker found: $(docker --version)"
    fi
    
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo "   Installing docker-compose..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        echo "   docker-compose installed"
    fi
    
    # Mark telemetry as enabled in config
    if grep -q "^TELEMETRY_ENABLED=" /etc/lldpq.conf 2>/dev/null; then
        sudo sed -i 's/^TELEMETRY_ENABLED=.*/TELEMETRY_ENABLED=true/' /etc/lldpq.conf
    else
        echo "TELEMETRY_ENABLED=true" | sudo tee -a /etc/lldpq.conf > /dev/null
    fi
    
    # Add default Prometheus URL if not present
    if ! grep -q "^PROMETHEUS_URL=" /etc/lldpq.conf 2>/dev/null; then
        echo "PROMETHEUS_URL=http://localhost:9090" | sudo tee -a /etc/lldpq.conf > /dev/null
    fi
    
    echo ""
    echo "   Telemetry support enabled!"
    echo ""
    
    # Configure Docker storage driver if needed (for VMs without overlay support)
    if [[ ! -f /etc/docker/daemon.json ]]; then
        echo "   Configuring Docker storage driver..."
        sudo mkdir -p /etc/docker
        echo '{"storage-driver": "vfs"}' | sudo tee /etc/docker/daemon.json > /dev/null
        sudo systemctl restart docker
    fi
    
    # Start the telemetry stack automatically
    if [[ -f "$LLDPQ_INSTALL_DIR/telemetry/docker-compose.yaml" ]]; then
        echo ""
        echo "   Starting telemetry stack..."
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
            echo "   [!] Could not start stack. Try manually:"
            echo "       cd $LLDPQ_INSTALL_DIR/telemetry && sudo docker compose up -d"
        fi
        cd - > /dev/null
        
        # Wait a moment and check status
        sleep 3
        if docker ps --filter "name=lldpq-prometheus" --format "{{.Status}}" 2>/dev/null | grep -q "Up"; then
            echo ""
            echo "   Telemetry stack is running:"
            echo "     - OTEL Collector: http://localhost:4317"
            echo "     - Prometheus:     http://localhost:9090"
            echo "     - Alertmanager:   http://localhost:9093"
        fi
    fi
    
    echo ""
    echo "   Next step: Enable telemetry on switches from web UI:"
    echo "     Telemetry → Configuration → Enable Telemetry"
else
    echo "   Telemetry skipped. Enable later with: ./update.sh --enable-telemetry"
    
    # Mark telemetry as disabled in config
    if grep -q "^TELEMETRY_ENABLED=" /etc/lldpq.conf 2>/dev/null; then
        sudo sed -i 's/^TELEMETRY_ENABLED=.*/TELEMETRY_ENABLED=false/' /etc/lldpq.conf
    else
        echo "TELEMETRY_ENABLED=false" | sudo tee -a /etc/lldpq.conf > /dev/null
    fi
fi

echo ""
echo "[08] SSH Key Setup Required"
echo "   Before using LLDPq, you must setup SSH key authentication:"
echo ""
echo "   For each device in your network:"
echo "   ssh-copy-id username@device_ip"
echo ""
echo "   And ensure sudo works without password on each device:"
echo "   sudo visudo  # Add: username ALL=(ALL) NOPASSWD:ALL"

echo ""
echo "[09] Initializing local git repository in $LLDPQ_INSTALL_DIR..."
cd "$LLDPQ_INSTALL_DIR"

# Create .gitignore
cat > .gitignore << 'EOF'
# Output directories (dynamic, changes frequently)
lldp-results/
monitor-results/

# Temporary and backup files
*.log
*.tmp
*.pid
*.bak

# Python cache
__pycache__/
*.pyc
EOF

# Configure git user if not set (required for commits)
if ! git config --global user.name >/dev/null 2>&1; then
    git config --global user.name "$(whoami)"
fi
if ! git config --global user.email >/dev/null 2>&1; then
    git config --global user.email "$(whoami)@$(hostname)"
fi

# Initialize git repo with main branch (modern Git convention)
git init -q -b main
git add -A
git commit -q -m "Initial LLDPq configuration"

# Configure git for group permissions
git config core.sharedRepository group

# Add git hooks to preserve permissions after git operations (pull, checkout, etc)
echo "   - Setting up git hooks for permission preservation..."
cat > .git/hooks/post-merge << 'HOOKEOF'
#!/bin/bash
# Fix permissions after git pull/merge (preserve group read access for www-data)
chmod 750 "$(git rev-parse --show-toplevel)" 2>/dev/null || true
chmod 664 "$(git rev-parse --show-toplevel)/devices.yaml" 2>/dev/null || true
if [ -d "$(git rev-parse --show-toplevel)/monitor-results" ]; then
    chmod -R 750 "$(git rev-parse --show-toplevel)/monitor-results" 2>/dev/null || true
fi
HOOKEOF
chmod +x .git/hooks/post-merge

# Create post-checkout hook (for git checkout, git reset)
cp .git/hooks/post-merge .git/hooks/post-checkout

echo "Git repository initialized with initial commit"
echo "   - Git hooks created (permissions preserved after git operations)"
echo "   - Use 'cd $LLDPQ_INSTALL_DIR && git diff' to see changes"
echo "   - Use 'cd $LLDPQ_INSTALL_DIR && git log' to see history"

echo ""
echo "[10] Installation Complete!"
echo "   Next steps:"
echo "   1. Edit the 4 configuration files mentioned above"
echo "   2. Setup SSH keys for all devices"
echo "   3. Test the tools manually:"
echo "      - lldpq"
echo "      - get-conf"
echo "      - zzh"
echo "      - pping"
echo ""
echo "   Web interface will be available at: http://$(hostname -I | awk '{print $1}')"
echo ""
echo "   Default login credentials:"
echo "     admin / admin       (full access)"
echo "     operator / operator (no Ansible access)"
echo "   [!] Change these passwords after first login!"
echo ""
echo "   For detailed configuration examples, see README.md"
echo ""
echo "LLDPq installation completed successfully!"
echo ""