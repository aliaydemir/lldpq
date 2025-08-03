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
   exit 1
fi

# Check if we're in the lldpq directory
if [[ ! -f "README.md" ]] || [[ ! -d "cable-check" ]]; then
    echo "❌ Please run this script from the lldpq directory"
    echo "   Make sure you're in the directory containing README.md and cable-check/"
    exit 1
fi

echo ""
echo "[01] Backup existing cable-check directory?"
if [[ -d "$HOME/cable-check" ]]; then
    read -p "Create backup of existing cable-check? [y/N]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        backup_dir="$HOME/cable-check.backup.$(date +%Y%m%d_%H%M%S)"
        echo "   Backing up $HOME/cable-check to $backup_dir"
        cp -r "$HOME/cable-check" "$backup_dir"
        echo "Backup created: $backup_dir"
    else
        echo "   Skipping backup as requested"
    fi
else
    echo "   No existing cable-check directory found, skipping backup"
fi

echo ""
echo "[02] Updating system files..."
echo "   - Updating html/* to /var/www/html/"
sudo cp -r html/* /var/www/html/

echo "   - Updating bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*
echo "System files updated"

echo ""
echo "[03] Backup monitoring data?"
backup_data_dir=""
if [[ -d "$HOME/cable-check/monitor-results" ]] || [[ -d "$HOME/cable-check/lldp-results" ]]; then
    echo "   Found existing monitoring data directories:"
    [[ -d "$HOME/cable-check/monitor-results" ]] && echo "     • monitor-results/ (contains all analysis results)"
    [[ -d "$HOME/cable-check/lldp-results" ]] && echo "     • lldp-results/ (contains LLDP topology data)"
    echo ""
    read -p "Backup and preserve monitoring data? [Y/n]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "   ⚠️  Monitoring data will be LOST during update!"
    else
        backup_data_dir=$(mktemp -d)
        echo "   📦 Backing up monitoring data..."
        [[ -d "$HOME/cable-check/monitor-results" ]] && cp -r "$HOME/cable-check/monitor-results" "$backup_data_dir/"
        [[ -d "$HOME/cable-check/lldp-results" ]] && cp -r "$HOME/cable-check/lldp-results" "$backup_data_dir/"
        echo "   ✅ Monitoring data backed up to temporary location"
    fi
else
    echo "   No existing monitoring data found"
fi

echo ""
echo "[04] Updating cable-check directory (preserving configs)..."
# Create temp directory for selective copy
temp_dir=$(mktemp -d)
cp -r cable-check/* "$temp_dir/"

# If cable-check exists, preserve config files
if [[ -d "$HOME/cable-check" ]]; then
    echo "   - Preserving configuration files:"
    
    if [[ -f "$HOME/cable-check/devices.yaml" ]]; then
        echo "     • devices.yaml"
        cp "$HOME/cable-check/devices.yaml" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/cable-check/hosts.ini" ]]; then
        echo "     • hosts.ini"
        cp "$HOME/cable-check/hosts.ini" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/cable-check/topology.dot" ]]; then
        echo "     • topology.dot"
        cp "$HOME/cable-check/topology.dot" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/cable-check/topology_config.yaml" ]]; then
        echo "     • topology_config.yaml"
        cp "$HOME/cable-check/topology_config.yaml" "$temp_dir/"
    fi
    
    # Remove old cable-check
    rm -rf "$HOME/cable-check"
fi

# Copy updated files with preserved configs
mv "$temp_dir" "$HOME/cable-check"
echo "cable-check directory updated with preserved configs"

# Restore monitoring data if backed up
if [[ -n "$backup_data_dir" ]] && [[ -d "$backup_data_dir" ]]; then
    echo ""
    echo "   📁 Restoring monitoring data..."
    [[ -d "$backup_data_dir/monitor-results" ]] && cp -r "$backup_data_dir/monitor-results" "$HOME/cable-check/"
    [[ -d "$backup_data_dir/lldp-results" ]] && cp -r "$backup_data_dir/lldp-results" "$HOME/cable-check/"
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
echo "     • ~/cable-check/devices.yaml"
echo "     • ~/cable-check/hosts.ini"
echo "     • ~/cable-check/topology.dot"
echo "     • ~/cable-check/topology_config.yaml"
if [[ -n "$backup_data_dir" ]] || [[ -d "$HOME/cable-check/monitor-results" ]] || [[ -d "$HOME/cable-check/lldp-results" ]]; then
    echo "   Monitoring data directories:"
    [[ -d "$HOME/cable-check/monitor-results" ]] && echo "     • monitor-results/ (all analysis results preserved)"
    [[ -d "$HOME/cable-check/lldp-results" ]] && echo "     • lldp-results/ (LLDP topology data preserved)"
fi

echo ""
echo "[07] Testing updated tools..."
echo "   You can test the updated tools:"
echo "   - lldpq"
echo "   - monitor"
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