#!/bin/bash
# LLDPq Update Script
# Updates system files while preserving configuration
# 
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

set -e

echo "🔄 LLDPq Update Script"
echo "======================"

# Check if running as root
if [[ $EUID -eq 0 ]]; then
   echo "❌ Please do not run this script as root (use your regular user account)"
   echo "   The script will ask for sudo when needed"
   #exit 1
fi

# Check if we're in the lldpq directory
if [[ ! -f "README.md" ]] || [[ ! -d "monitor" ]]; then
    echo "❌ Please run this script from the lldpq directory"
    echo "   Make sure you're in the directory containing README.md and monitor/"
    exit 1
fi

echo ""
echo "[01] Backup existing monitor directory?"
if [[ -d "$HOME/monitor" ]]; then
    read -p "Create backup of existing monitor? [y/N]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        backup_dir="$HOME/monitor.backup.$(date +%Y%m%d_%H%M%S)"
        echo "   Backing up $HOME/monitor to $backup_dir"
        cp -r "$HOME/monitor" "$backup_dir"
        echo "Backup created: $backup_dir"
    else
        echo "   Skipping backup as requested"
    fi
else
    echo "   No existing monitor directory found, skipping backup"
fi

echo ""
echo "[02] Updating system files..."

# Backup user's system config files before overwriting
echo "   - Backing up user system configs..."
system_config_backup=$(mktemp -d)
[[ -f "/etc/ip_list" ]] && cp "/etc/ip_list" "$system_config_backup/" && echo "     • /etc/ip_list backed up"
[[ -f "/etc/nccm.yml" ]] && cp "/etc/nccm.yml" "$system_config_backup/" && echo "     • /etc/nccm.yml backed up"

echo "   - Updating etc/* to /etc/"
sudo cp -r etc/* /etc/

# Restore user's system config files
echo "   - Restoring user system configs..."
[[ -f "$system_config_backup/ip_list" ]] && sudo cp "$system_config_backup/ip_list" "/etc/" && echo "     • /etc/ip_list restored"
[[ -f "$system_config_backup/nccm.yml" ]] && sudo cp "$system_config_backup/nccm.yml" "/etc/" && echo "     • /etc/nccm.yml restored"

# Clean up backup
rm -rf "$system_config_backup"

echo "   - Updating html/* to /var/www/html/"
sudo cp -r html/* /var/www/html/

echo "   - Updating bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*
echo "System files updated"

echo ""
echo "[03] Backup monitoring data?"
backup_data_dir=""
if [[ -d "$HOME/monitor/monitor-results" ]] || [[ -d "$HOME/monitor/lldp-results" ]] || [[ -d "$HOME/monitor/alert-states" ]]; then
    echo "   Found existing monitoring data directories:"
    [[ -d "$HOME/monitor/monitor-results" ]] && echo "     • monitor-results/ (contains all analysis results)"
    [[ -d "$HOME/monitor/lldp-results" ]] && echo "     • lldp-results/ (contains LLDP topology data)"
    [[ -d "$HOME/monitor/alert-states" ]] && echo "     • alert-states/ (contains alert history and state tracking)"
    echo ""
    read -p "Backup and preserve monitoring data? [Y/n]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "   ⚠️  Monitoring data will be LOST during update!"
    else
        backup_data_dir=$(mktemp -d)
        echo "   📦 Backing up monitoring data..."
        [[ -d "$HOME/monitor/monitor-results" ]] && cp -r "$HOME/monitor/monitor-results" "$backup_data_dir/"
        [[ -d "$HOME/monitor/lldp-results" ]] && cp -r "$HOME/monitor/lldp-results" "$backup_data_dir/"
        [[ -d "$HOME/monitor/alert-states" ]] && cp -r "$HOME/monitor/alert-states" "$backup_data_dir/"
        echo "   ✅ Monitoring data backed up to temporary location"
    fi
else
    echo "   No existing monitoring data found"
fi

echo ""
echo "[04] Updating monitor directory (preserving configs)..."
# Create temp directory for selective copy
temp_dir=$(mktemp -d)
cp -r monitor/* "$temp_dir/"

# If monitor exists, preserve config files
if [[ -d "$HOME/monitor" ]]; then
    echo "   - Preserving configuration files:"
    
    if [[ -f "$HOME/monitor/devices.yaml" ]]; then
        echo "     • devices.yaml"
        cp "$HOME/monitor/devices.yaml" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/monitor/hosts.ini" ]]; then
        echo "     • hosts.ini"
        cp "$HOME/monitor/hosts.ini" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/monitor/topology.dot" ]]; then
        echo "     • topology.dot"
        cp "$HOME/monitor/topology.dot" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/monitor/topology_config.yaml" ]]; then
        echo "     • topology_config.yaml"
        cp "$HOME/monitor/topology_config.yaml" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/monitor/notifications.yaml" ]]; then
        echo "     • notifications.yaml"
        cp "$HOME/monitor/notifications.yaml" "$temp_dir/"
    fi
    
    # Remove old monitor
    rm -rf "$HOME/monitor"
fi

# Copy updated files with preserved configs
mv "$temp_dir" "$HOME/monitor"
echo "monitor directory updated with preserved configs"

# Restore monitoring data if backed up
if [[ -n "$backup_data_dir" ]] && [[ -d "$backup_data_dir" ]]; then
    echo ""
    echo "   📁 Restoring monitoring data..."
    [[ -d "$backup_data_dir/monitor-results" ]] && cp -r "$backup_data_dir/monitor-results" "$HOME/monitor/"
    [[ -d "$backup_data_dir/lldp-results" ]] && cp -r "$backup_data_dir/lldp-results" "$HOME/monitor/"
    [[ -d "$backup_data_dir/alert-states" ]] && cp -r "$backup_data_dir/alert-states" "$HOME/monitor/"
    echo "   ✅ Monitoring data restored successfully"
    # Clean up temporary backup
    rm -rf "$backup_data_dir"
fi

echo ""
echo "[05] Restarting nginx service..."
sudo systemctl restart nginx
echo "nginx restarted"

echo ""
echo "[06] Data preservation summary:"
echo "   The following files/directories were preserved:"
echo "   Configuration files:"
echo "     • /etc/ip_list"
echo "     • /etc/nccm.yml"
echo "     • ~/monitor/devices.yaml"
echo "     • ~/monitor/hosts.ini"
echo "     • ~/monitor/topology.dot"
echo "     • ~/monitor/topology_config.yaml"
echo "     • ~/monitor/notifications.yaml"
if [[ -n "$backup_data_dir" ]] || [[ -d "$HOME/monitor/monitor-results" ]] || [[ -d "$HOME/monitor/lldp-results" ]] || [[ -d "$HOME/monitor/alert-states" ]]; then
    echo "   Monitoring data directories:"
    [[ -d "$HOME/monitor/monitor-results" ]] && echo "     • monitor-results/ (all analysis results preserved)"
    [[ -d "$HOME/monitor/lldp-results" ]] && echo "     • lldp-results/ (LLDP topology data preserved)"
    [[ -d "$HOME/monitor/alert-states" ]] && echo "     • alert-states/ (alert history and state tracking preserved)"
fi

echo ""
echo "[07] Testing updated tools..."
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
echo "✅ LLDPq update completed successfully!"
echo ""