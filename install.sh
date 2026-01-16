#!/usr/bin/env bash
# LLDPq Installation Script
# 
# Copyright (c) 2024 LLDPq Project  
# Licensed under MIT License - see LICENSE file for details

set -e

echo "🚀 LLDPq Installation Script"
echo "=================================="

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo "❌ Please do not run this script as root (use your regular user account)"
   echo "   The script will ask for sudo when needed"
   #exit 1
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
echo "[01] Installing required packages..."
sudo apt update
sudo apt install -y nginx fcgiwrap python3 python3-pip python3-yaml util-linux bsdextrautils sshpass
sudo systemctl enable --now nginx
sudo systemctl enable --now fcgiwrap

# Install Python packages for alert system
echo "   - Installing Python packages for alerts..."
pip3 install --user requests >/dev/null 2>&1 || echo "   ⚠️  requests already installed"
echo "Required packages installed"

echo ""
echo "[02] Copying files to system directories..."
echo "   - Copying etc/* to /etc/"
sudo cp -r etc/* /etc/

echo "   - Copying html/* to $WEB_ROOT/"
sudo cp -r html/* "$WEB_ROOT/"
sudo chmod +x "$WEB_ROOT/trigger-lldp.sh"
sudo chmod +x "$WEB_ROOT/trigger-monitor.sh"
sudo chmod +x "$WEB_ROOT/edit-topology.sh"
sudo chmod +x "$WEB_ROOT/edit-config.sh"

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
echo "[03] Configuration files to edit:"
echo "   You need to manually edit these files with your network details:"
echo ""
echo "   1. sudo nano /etc/ip_list              # Add your device IP addresses"
echo "   2. sudo nano /etc/nccm.yml             # Configure SSH connection details"
echo "   3. nano ~/lldpq/devices.yaml           # Define your network devices"
echo "   4. nano ~/lldpq/topology.dot           # Define your network topology"
echo ""
echo "   See README.md for examples of each file format"

echo ""
echo "[04] Configuring nginx..."

# Enable LLDPq site
sudo ln -sf /etc/nginx/sites-available/lldpq /etc/nginx/sites-enabled/lldpq

# Disable Default site (if exists)
[ -L /etc/nginx/sites-enabled/default ] && sudo unlink /etc/nginx/sites-enabled/default || true

# Test and restart nginx
sudo nginx -t
sudo systemctl restart nginx
echo "nginx configured and restarted"

echo ""
echo "[05] Adding cron jobs..."
# Remove existing LLDPq cron jobs if they exist
sudo sed -i '/lldpq\|monitor\|get-conf/d' /etc/crontab

# Add new cron jobs
echo "*/5 * * * * $(whoami) /usr/local/bin/lldpq" | sudo tee -a /etc/crontab
echo "0 */12 * * * $(whoami) /usr/local/bin/get-conf" | sudo tee -a /etc/crontab
echo "* * * * * $(whoami) $HOME/lldpq/lldp-trigger-monitor.sh" | sudo tee -a /etc/crontab

echo "Cron jobs added:"
echo "   - lldpq:           every 5 minutes (system monitoring)"  
echo "   - get-conf:        every 12 hours"
echo "   - web triggers:    daemon (checks every 5 seconds, enables Run LLDP Check button)"

echo ""
echo "[06] SSH Key Setup Required"
echo "   Before using LLDPq, you must setup SSH key authentication:"
echo ""
echo "   For each device in your network:"
echo "   ssh-copy-id username@device_ip"
echo ""
echo "   And ensure sudo works without password on each device:"
echo "   sudo visudo  # Add: username ALL=(ALL) NOPASSWD:ALL"

echo ""
echo "[07] Installation Complete!"
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