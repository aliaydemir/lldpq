#!/bin/bash
# LLDPq Update Script
# Updates system files while preserving configuration

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
echo "💾 [01] Creating backup of existing cable-check..."
if [[ -d "$HOME/cable-check" ]]; then
    backup_dir="$HOME/cable-check.backup.$(date +%Y%m%d_%H%M%S)"
    echo "   Backing up $HOME/cable-check to $backup_dir"
    cp -r "$HOME/cable-check" "$backup_dir"
    echo "✅ Backup created: $backup_dir"
else
    echo "   No existing cable-check directory found, skipping backup"
fi

echo ""
echo "📁 [02] Updating system files..."
echo "   - Updating html/* to /var/www/html/"
sudo cp -r html/* /var/www/html/

echo "   - Updating bin/* to /usr/local/bin/"
sudo cp bin/* /usr/local/bin/
sudo chmod +x /usr/local/bin/*
echo "✅ System files updated"

echo ""
echo "📝 [03] Updating cable-check directory (preserving configs)..."
# Create temp directory for selective copy
temp_dir=$(mktemp -d)
cp -r cable-check/* "$temp_dir/"

# If cable-check exists, preserve config files
if [[ -d "$HOME/cable-check" ]]; then
    echo "   - Preserving configuration files:"
    
    if [[ -f "$HOME/cable-check/devices.sh" ]]; then
        echo "     • devices.sh"
        cp "$HOME/cable-check/devices.sh" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/cable-check/hosts.ini" ]]; then
        echo "     • hosts.ini"
        cp "$HOME/cable-check/hosts.ini" "$temp_dir/"
    fi
    
    if [[ -f "$HOME/cable-check/topology.dot" ]]; then
        echo "     • topology.dot"
        cp "$HOME/cable-check/topology.dot" "$temp_dir/"
    fi
    
    # Remove old cable-check
    rm -rf "$HOME/cable-check"
fi

# Copy updated files with preserved configs
mv "$temp_dir" "$HOME/cable-check"
echo "✅ cable-check directory updated with preserved configs"

echo ""
echo "🔄 [04] Restarting nginx service..."
sudo systemctl restart nginx
echo "✅ nginx restarted"

echo ""
echo "⚙️  [05] Configuration files preserved:"
echo "   The following files were NOT updated (your settings preserved):"
echo "   - /etc/ip_list"
echo "   - /etc/nccm.yml"
echo "   - ~/cable-check/devices.sh"
echo "   - ~/cable-check/hosts.ini"
echo "   - ~/cable-check/topology.dot"

echo ""
echo "🧪 [06] Testing updated tools..."
echo "   You can test the updated tools:"
echo "   - lldpq"
echo "   - monitor"
echo "   - get-conf"
echo "   - zzh"
echo "   - pping"

echo ""
echo "🎯 Update Complete!"
echo "   📊 New features:"
echo "   - BGP Neighbor Analysis"
echo "   - Link Flap Detection" 
echo "   - Enhanced monitoring capabilities"
echo ""
echo "   🌐 Web interface: http://$(hostname -I | awk '{print $1}')"
echo ""
echo "   🔍 If you encounter issues, your backup is available at:"
if [[ -n "$backup_dir" ]]; then
    echo "      $backup_dir"
fi
echo ""
echo "✅ LLDPq update completed successfully!"