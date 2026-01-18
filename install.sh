#!/usr/bin/env bash
# LLDPq Installation Script
# 
# Copyright (c) 2024 LLDPq Project  
# Licensed under MIT License - see LICENSE file for details

set -e

echo "🚀 LLDPq Installation Script"
echo "=================================="

# Check if running via sudo from non-root user (causes $HOME issues)
if [[ $EUID -eq 0 ]] && [[ -n "$SUDO_USER" ]] && [[ "$SUDO_USER" != "root" ]]; then
    echo "❌ Please run without sudo: ./install.sh"
    echo "   The script will ask for sudo when needed"
    exit 1
fi

# Running as root is OK (for dedicated servers)
if [[ $EUID -eq 0 ]]; then
    echo "Running as root - files will be installed in /root/lldpq"
fi

# Check if we're in the lldpq-src directory
if [[ ! -f "README.md" ]] || [[ ! -d "lldpq" ]]; then
    echo "❌ Please run this script from the lldpq-src directory"
    echo "   Make sure you're in the directory containing README.md and lldpq/"
    exit 1
fi

# Web root directory (default for Linux, can be changed in /etc/lldpq.conf for macOS etc.)
WEB_ROOT="/var/www/html"

echo ""
echo "[01] Checking for conflicting services..."

# Check if Apache2 is running (would conflict with nginx on port 80)
if systemctl is-active --quiet apache2 2>/dev/null; then
    echo "⚠️  Apache2 is running on port 80!"
    echo "   LLDPq uses nginx as web server."
    echo ""
    echo "   Options:"
    echo "   1. Stop Apache2 (recommended for LLDPq)"
    echo "   2. Exit and resolve manually"
    echo ""
    read -p "   Stop and disable Apache2? [Y/n]: " response
    if [[ ! "$response" =~ ^[Nn]$ ]]; then
        sudo systemctl stop apache2
        sudo systemctl disable apache2
        echo "   ✅ Apache2 stopped and disabled"
    else
        echo "   ❌ Please stop Apache2 or configure nginx to use a different port"
        echo "   Edit /etc/nginx/sites-available/lldpq to change the port"
        exit 1
    fi
fi

echo ""
echo "[02] Installing required packages..."
sudo apt update
sudo apt install -y nginx fcgiwrap python3 python3-pip python3-yaml util-linux bsdextrautils sshpass
sudo systemctl enable --now nginx
sudo systemctl enable --now fcgiwrap

# Install Python packages for alert system
echo "   - Installing Python packages for alerts..."
pip3 install --user requests >/dev/null 2>&1 || echo "   ⚠️  requests already installed"
echo "Required packages installed"

echo ""
echo "[03] Copying files to system directories..."
echo "   - Copying etc/* to /etc/"
sudo cp -r etc/* /etc/

echo "   - Copying html/* to $WEB_ROOT/"
sudo cp -r html/* "$WEB_ROOT/"
sudo chmod +x "$WEB_ROOT/trigger-lldp.sh"
sudo chmod +x "$WEB_ROOT/trigger-monitor.sh"
sudo chmod +x "$WEB_ROOT/edit-topology.sh"
sudo chmod +x "$WEB_ROOT/edit-config.sh"

echo "   - Setting permissions on web directories"
# Ensure /var/www is traversable (some systems restrict it)
sudo chmod o+rx /var/www 2>/dev/null || true
# Ensure all files/dirs in web root are readable/traversable by nginx (www-data)
# X = adds execute to directories and already-executable files only
sudo chmod -R o+rX "$WEB_ROOT/"
# hstr, configs, monitor-results directories need write access for scripts
sudo mkdir -p "$WEB_ROOT/hstr" "$WEB_ROOT/configs" "$WEB_ROOT/monitor-results"
sudo chown -R $USER:$USER "$WEB_ROOT/hstr" "$WEB_ROOT/configs" "$WEB_ROOT/monitor-results"
sudo chmod -R o+rX "$WEB_ROOT/hstr" "$WEB_ROOT/configs" "$WEB_ROOT/monitor-results"

echo "   - Copying bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*

echo "   - Copying lldpq to ~/lldpq"
cp -r lldpq ~/lldpq

echo "   - Setting up topology.dot for web editing"
# Move topology.dot to web root for www-data access (if it exists)
if [[ -f ~/lldpq/topology.dot ]]; then
    sudo mv ~/lldpq/topology.dot "$WEB_ROOT/topology.dot"
    # www-data owns it (for web editing), user's group has access too
    sudo chown www-data:$USER "$WEB_ROOT/topology.dot"
    sudo chmod 664 "$WEB_ROOT/topology.dot"
    # Create symlink so lldpq scripts can access it
    ln -sf "$WEB_ROOT/topology.dot" ~/lldpq/topology.dot
else
    echo "  topology.dot not found in lldpq/, will be created on first use"
    # Create empty topology.dot in web root for web editing
    echo "# LLDPq Topology Definition" | sudo tee "$WEB_ROOT/topology.dot" > /dev/null
    sudo chown www-data:$USER "$WEB_ROOT/topology.dot"
    sudo chmod 664 "$WEB_ROOT/topology.dot"
    ln -sf "$WEB_ROOT/topology.dot" ~/lldpq/topology.dot
fi

echo "   - Setting up topology_config.yaml for web editing"
# Move topology_config.yaml to web root for www-data access
if [[ -f ~/lldpq/topology_config.yaml ]]; then
    sudo mv ~/lldpq/topology_config.yaml "$WEB_ROOT/topology_config.yaml"
    sudo chown www-data:$USER "$WEB_ROOT/topology_config.yaml"
    sudo chmod 664 "$WEB_ROOT/topology_config.yaml"
    ln -sf "$WEB_ROOT/topology_config.yaml" ~/lldpq/topology_config.yaml
fi

echo "   - Creating /etc/lldpq.conf"
echo "# LLDPq Configuration" | sudo tee /etc/lldpq.conf > /dev/null
echo "LLDPQ_DIR=$HOME/lldpq" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "WEB_ROOT=$WEB_ROOT" | sudo tee -a /etc/lldpq.conf > /dev/null
echo "Files copied successfully"

echo ""
echo "[04] Configuration files to edit:"
echo "   You need to manually edit these files with your network details:"
echo ""
echo "   1. sudo nano /etc/ip_list              # Add your device IP addresses"
echo "   2. sudo nano /etc/nccm.yml             # Configure SSH connection details"
echo "   3. nano ~/lldpq/devices.yaml           # Define your network devices"
echo "   4. nano ~/lldpq/topology.dot           # Define your network topology"
echo ""
echo "   See README.md for examples of each file format"

echo ""
echo "[05] Configuring nginx..."

# Enable LLDPq site
sudo ln -sf /etc/nginx/sites-available/lldpq /etc/nginx/sites-enabled/lldpq

# Disable Default site (if exists)
[ -L /etc/nginx/sites-enabled/default ] && sudo unlink /etc/nginx/sites-enabled/default || true

# Test and restart nginx
sudo nginx -t
sudo systemctl restart nginx
echo "nginx configured and restarted"

echo ""
echo "[06] Adding cron jobs..."
# Remove existing LLDPq cron jobs if they exist
sudo sed -i '/lldpq\|monitor\|get-conf/d' /etc/crontab

# Add new cron jobs
echo "*/5 * * * * $(whoami) /usr/local/bin/lldpq" | sudo tee -a /etc/crontab
echo "0 */12 * * * $(whoami) /usr/local/bin/get-conf" | sudo tee -a /etc/crontab
echo "* * * * * $(whoami) /usr/local/bin/lldpq-trigger" | sudo tee -a /etc/crontab
echo "0 0 * * * $(whoami) cp /var/www/html/topology.dot $HOME/lldpq/topology.dot.bkp 2>/dev/null; cp /var/www/html/topology_config.yaml $HOME/lldpq/topology_config.yaml.bkp 2>/dev/null; cd $HOME/lldpq && git add -A && git diff --cached --quiet || git commit -m 'auto: \$(date +\%Y-\%m-\%d)'" | sudo tee -a /etc/crontab

echo "Cron jobs added:"
echo "   - lldpq:           every 5 minutes (system monitoring)"  
echo "   - get-conf:        every 12 hours"
echo "   - web triggers:    daemon (checks every 5 seconds, enables Run LLDP Check button)"
echo "   - git auto-commit: daily at midnight (tracks config changes)"

echo ""
echo "[07] SSH Key Setup Required"
echo "   Before using LLDPq, you must setup SSH key authentication:"
echo ""
echo "   For each device in your network:"
echo "   ssh-copy-id username@device_ip"
echo ""
echo "   And ensure sudo works without password on each device:"
echo "   sudo visudo  # Add: username ALL=(ALL) NOPASSWD:ALL"

echo ""
echo "[08] Initializing local git repository in ~/lldpq..."
cd ~/lldpq

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

# Initialize git repo
git init -q
git add -A
git commit -q -m "Initial LLDPq configuration"
echo "Git repository initialized with initial commit"
echo "   - Use 'cd ~/lldpq && git diff' to see changes"
echo "   - Use 'cd ~/lldpq && git log' to see history"

echo ""
echo "[09] Installation Complete!"
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
echo "   For detailed configuration examples, see README.md"
echo ""
echo "✅ LLDPq installation completed successfully!"
echo ""