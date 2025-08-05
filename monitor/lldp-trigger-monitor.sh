#!/bin/bash

# LLDP Trigger Monitor - Check for web interface triggers
# Add to crontab: * * * * * /path/to/lldp_trigger_monitor.sh

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIGGER_FILE="/tmp/lldp_trigger"
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

# Check for trigger via nginx access log (alternative method)
if [ -f "/var/log/nginx/access.log" ]; then
    # Check last 2 minutes for trigger-lldp requests
    RECENT_TRIGGER=$(tail -100 /var/log/nginx/access.log | grep -c "POST /trigger-lldp" | head -1)
    if [ "$RECENT_TRIGGER" -gt 0 ]; then
        # Find the timestamp of last request
        LAST_REQUEST=$(tail -100 /var/log/nginx/access.log | grep "POST /trigger-lldp" | tail -1 | awk '{print $4}' | tr -d '[')
        if [ -n "$LAST_REQUEST" ]; then
            # Convert to epoch time and compare (simplified check)
            CURRENT_TIME=$(date +%s)
            # If we detect a request in logs, proceed with LLDP check
            # (This is a simplified approach - could be improved with proper time parsing)
        fi
    fi
fi

# Simple file-based trigger (user creates trigger file manually)
TRIGGER_FILE="$MONITOR_DIR/.web_trigger"

if [ -f "$TRIGGER_FILE" ]; then
    {
        echo "$(date): Web trigger found, starting LLDP check..."
        
        # Create lock file with PID
        echo $$ > "$LOCK_FILE"
        
        # Remove trigger file
        rm -f "$TRIGGER_FILE"
        
        cd "$MONITOR_DIR"

        # Run asset discovery and LLDP checks
        /bin/bash ./assets.sh >/dev/null 2>&1
        /bin/bash ./check-lldp.sh >/dev/null 2>&1
        
        echo "$(date): LLDP check completed"
        
        # Remove lock file
        rm -f "$LOCK_FILE"
    } >> "$LOG_FILE" 2>&1
fi