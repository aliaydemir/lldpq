#!/bin/bash
# LLDPq Migration Script
# Migrates from ~/monitor to ~/lldpq
# 
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

set -e

echo "🔄 LLDPq Migration Script"
echo "========================="
echo ""
echo "This script migrates your installation from ~/monitor to ~/lldpq"
echo ""

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

echo "[01] Pre-flight checks..."

# Check if ~/monitor exists
if [[ ! -d "$HOME/monitor" ]]; then
    echo "   ℹ️  ~/monitor not found - nothing to migrate"
    echo ""
    echo "   If this is a fresh installation, just run:"
    echo "   ./install.sh"
    echo ""
    exit 0
fi

# Check if ~/lldpq already exists
if [[ -d "$HOME/lldpq" ]]; then
    echo "   ⚠️  ~/lldpq already exists!"
    echo ""
    echo "   Options:"
    echo "   1. Remove ~/lldpq and re-run this script"
    echo "   2. Manually merge the directories"
    echo ""
    read -p "   Remove existing ~/lldpq and proceed? [y/N]: " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "   Migration cancelled."
        exit 1
    fi
    echo "   Removing existing ~/lldpq..."
    rm -rf "$HOME/lldpq"
fi

# Check for running processes
echo "   - Checking for running processes..."
if pgrep -f "monitor\.sh" >/dev/null 2>&1 || pgrep -f "lldp-trigger-monitor" >/dev/null 2>&1; then
    echo ""
    echo "   ⚠️  LLDPq processes are currently running!"
    echo "   Please wait for them to finish or stop them manually:"
    echo "   pkill -f monitor.sh"
    echo "   pkill -f lldp-trigger-monitor"
    echo ""
    read -p "   Wait and retry? [Y/n]: " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo "   Migration cancelled."
        exit 1
    fi
    
    echo "   Waiting for processes to finish (max 30 seconds)..."
    for i in {1..30}; do
        if ! pgrep -f "monitor\.sh" >/dev/null 2>&1 && ! pgrep -f "lldp-trigger-monitor" >/dev/null 2>&1; then
            echo "   ✅ Processes finished"
            break
        fi
        sleep 1
        echo -n "."
    done
    echo ""
    
    if pgrep -f "monitor\.sh" >/dev/null 2>&1 || pgrep -f "lldp-trigger-monitor" >/dev/null 2>&1; then
        echo "   ❌ Processes still running. Please stop them manually and retry."
        exit 1
    fi
fi

echo "   ✅ Pre-flight checks passed"

# ============================================================================
# USER CONFIRMATION
# ============================================================================

echo ""
echo "[02] Migration summary:"
echo "   From: ~/monitor"
echo "   To:   ~/lldpq"
echo ""
echo "   The following will be migrated:"
echo "   - All scripts and configuration files"
echo "   - devices.yaml, hosts.ini, topology_config.yaml"
echo "   - monitor-results/, lldp-results/, alert-states/"
echo ""
echo "   The following will be updated:"
echo "   - /etc/lldpq.conf (LLDPQ_DIR path)"
echo "   - Cron jobs in /etc/crontab"
echo "   - topology.dot symlink"
echo ""

read -p "Proceed with migration? [y/N]: " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Migration cancelled."
    exit 0
fi

# ============================================================================
# MIGRATION
# ============================================================================

echo ""
echo "[03] Migrating ~/monitor to ~/lldpq..."

# Move the directory
mv "$HOME/monitor" "$HOME/lldpq"
echo "   ✅ Directory moved"

# ============================================================================
# UPDATE CONFIGURATION
# ============================================================================

echo ""
echo "[04] Updating configuration..."

# Update /etc/lldpq.conf
echo "   - Updating /etc/lldpq.conf..."
if [[ -f /etc/lldpq.conf ]]; then
    sudo sed -i 's|MONITOR_DIR=.*|LLDPQ_DIR='"$HOME"'/lldpq|g' /etc/lldpq.conf
    # Also update variable name if it was MONITOR_DIR
    sudo sed -i 's|MONITOR_DIR=|LLDPQ_DIR=|g' /etc/lldpq.conf
else
    echo "# LLDPq Configuration" | sudo tee /etc/lldpq.conf > /dev/null
    echo "LLDPQ_DIR=$HOME/lldpq" | sudo tee -a /etc/lldpq.conf > /dev/null
fi
echo "   ✅ /etc/lldpq.conf updated"

# Update cron jobs
echo "   - Updating cron jobs..."
if grep -q "\$HOME/monitor" /etc/crontab 2>/dev/null; then
    sudo sed -i 's|\$HOME/monitor|\$HOME/lldpq|g' /etc/crontab
    echo "   ✅ Cron jobs updated"
elif grep -q "$HOME/monitor" /etc/crontab 2>/dev/null; then
    sudo sed -i "s|$HOME/monitor|$HOME/lldpq|g" /etc/crontab
    echo "   ✅ Cron jobs updated"
else
    echo "   ℹ️  No cron jobs found to update"
fi

# Fix topology.dot symlink
echo "   - Fixing topology.dot symlink..."
if [[ -L "$HOME/lldpq/topology.dot" ]]; then
    # Already a symlink, just verify it points to the right place
    if [[ "$(readlink "$HOME/lldpq/topology.dot")" == "/var/www/html/topology.dot" ]]; then
        echo "   ✅ topology.dot symlink is correct"
    else
        rm -f "$HOME/lldpq/topology.dot"
        ln -sf /var/www/html/topology.dot "$HOME/lldpq/topology.dot"
        echo "   ✅ topology.dot symlink fixed"
    fi
elif [[ -f "$HOME/lldpq/topology.dot" ]]; then
    # It's a real file, need to migrate it
    if [[ -f /var/www/html/topology.dot ]]; then
        # Web version exists, backup local and create symlink
        mv "$HOME/lldpq/topology.dot" "$HOME/lldpq/topology.dot.local.backup"
        ln -sf /var/www/html/topology.dot "$HOME/lldpq/topology.dot"
        echo "   ✅ topology.dot migrated (backup: topology.dot.local.backup)"
    else
        # Move to web location
        sudo mv "$HOME/lldpq/topology.dot" /var/www/html/topology.dot
        sudo chown www-data:$USER /var/www/html/topology.dot
        sudo chmod 664 /var/www/html/topology.dot
        ln -sf /var/www/html/topology.dot "$HOME/lldpq/topology.dot"
        echo "   ✅ topology.dot moved to /var/www/html and symlinked"
    fi
fi

# ============================================================================
# VERIFICATION
# ============================================================================

echo ""
echo "[05] Verifying migration..."

errors=0

# Check directory exists
if [[ -d "$HOME/lldpq" ]]; then
    echo "   ✅ ~/lldpq exists"
else
    echo "   ❌ ~/lldpq not found!"
    ((errors++))
fi

# Check key files
for file in monitor.sh devices.yaml check-lldp.sh lldp-trigger-monitor.sh; do
    if [[ -f "$HOME/lldpq/$file" ]]; then
        echo "   ✅ $file exists"
    else
        echo "   ⚠️  $file not found (may be optional)"
    fi
done

# Check old directory is gone
if [[ -d "$HOME/monitor" ]]; then
    echo "   ⚠️  ~/monitor still exists (should have been moved)"
    ((errors++))
else
    echo "   ✅ ~/monitor removed"
fi

# Check config
if grep -q "lldpq" /etc/lldpq.conf 2>/dev/null; then
    echo "   ✅ /etc/lldpq.conf updated"
else
    echo "   ⚠️  /etc/lldpq.conf may need manual update"
fi

# ============================================================================
# SUMMARY
# ============================================================================

echo ""
echo "=============================================="
if [[ $errors -eq 0 ]]; then
    echo "✅ Migration completed successfully!"
else
    echo "⚠️  Migration completed with warnings"
fi
echo "=============================================="
echo ""
echo "New location: ~/lldpq"
echo ""
echo "Next steps:"
echo "1. Test the installation:"
echo "   cd ~/lldpq && ./monitor.sh"
echo ""
echo "2. If you need to update to latest version:"
echo "   cd lldpq-src && git pull && ./update.sh"
echo ""
echo "3. Verify web interface is working:"
echo "   http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'your-server-ip')"
echo ""
