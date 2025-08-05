#!/bin/bash
# LLDP Trigger Monitor - Check for web interface triggers
# Add to crontab: * * * * * /path/to/lldp_trigger_monitor.sh
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIGGER_FILE="/var/www/html/.web_trigger"
LOCK_FILE="/tmp/lldp_running.lock"  
LOG_FILE="$MONITOR_DIR/trigger_monitor.log"

# Exit if already running
if [ -f "$LOCK_FILE" ]; then
    # Check if process is actually running
    if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
        exit 0
    else
        # Stale lock file, remove it
        rm -f "$LOCK_FILE"
    fi
fi

# Simple file-based trigger (user creates trigger file manually)
if [ -f "$TRIGGER_FILE" ]; then
    {
        echo "$(date): Web trigger found, starting LLDP check..."
        
        # Create lock file with PID
        echo $$ > "$LOCK_FILE"
        
        # Remove trigger file
        rm -f "$TRIGGER_FILE"
        
        cd "$MONITOR_DIR"

        # Wait function to prevent conflicts
        wait_until_not_running() {
            local script_name="$1"
            while pgrep -f "$script_name" >/dev/null; do
                sleep 10
            done
        }

        # Run asset discovery and LLDP checks (sequential with conflict prevention)
        wait_until_not_running "assets.sh"
        /bin/bash ./assets.sh >/dev/null 2>&1
        wait_until_not_running "check-lldp.sh"
        /bin/bash ./check-lldp.sh >/dev/null 2>&1
        
        echo "$(date): LLDP check completed"
        
        # Remove lock file
        rm -f "$LOCK_FILE"
    } >> "$LOG_FILE" 2>&1
fi