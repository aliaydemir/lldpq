#!/bin/bash
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
   exit 1
fi

# Check if we're in the lldpq directory
if [[ ! -f "README.md" ]] || [[ ! -d "cable-check" ]]; then
    echo "❌ Please run this script from the lldpq directory"
    echo "   Make sure you're in the directory containing README.md and cable-check/"
    exit 1
fi

echo ""
echo "[01] Installing and enabling nginx..."
sudo apt update
sudo apt install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
echo "nginx installed and started"

echo ""
echo "[02] Copying files to system directories..."
echo "   - Copying etc/* to /etc/"
sudo cp -r etc/* /etc/

echo "   - Copying html/* to /var/www/html/"
sudo cp -r html/* /var/www/html/

echo "   - Copying bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*

echo "   - Copying cable-check to ~/cable-check"
cp -r cable-check ~/cable-check
echo "Files copied successfully"

echo ""
echo "[03] Configuration files to edit:"
echo "   You need to manually edit these files with your network details:"
echo ""
echo "   1. sudo nano /etc/ip_list           # Add your device IP addresses"
echo "   2. sudo nano /etc/nccm.yml          # Configure SSH connection details"
echo "   3. nano ~/cable-check/devices.yaml  # Define your network devices"
echo "   4. nano ~/cable-check/topology.dot  # Define your network topology"
echo ""
echo "   See README.md for examples of each file format"

echo ""
echo "[04] Restarting nginx service..."
sudo systemctl restart nginx
echo "nginx restarted"

echo ""
echo "[05] Adding cron jobs..."
# Remove existing LLDPq cron jobs if they exist
sudo sed -i '/lldpq\|monitor\|get-conf/d' /etc/crontab

# Add new cron jobs
echo "*/10 * * * * $(whoami) /usr/local/bin/lldpq" | sudo tee -a /etc/crontab
echo "15,45 * * * * $(whoami) /usr/local/bin/monitor" | sudo tee -a /etc/crontab  
echo "0 */12 * * * $(whoami) /usr/local/bin/get-conf" | sudo tee -a /etc/crontab
echo "Cron jobs added:"
echo "   - lldpq:    every 10 minutes"
echo "   - monitor:  every 30 minutes (15,45)"  
echo "   - get-conf: every 12 hours"

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
echo "      - monitor" 
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