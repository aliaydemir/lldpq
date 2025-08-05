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

# Check if LLDP check is needed via access log monitoring
ACCESS_LOG="/var/log/nginx/access.log"
LAST_CHECK_FILE="$MONITOR_DIR/.last_trigger_check"

if [ -f "$ACCESS_LOG" ]; then
    # Get last modification time of access log
    LOG_MODIFIED=$(stat -c %Y "$ACCESS_LOG" 2>/dev/null || echo 0)
    LAST_CHECK=$(cat "$LAST_CHECK_FILE" 2>/dev/null || echo 0)
    
    # If log was modified since last check, look for trigger requests
    if [ "$LOG_MODIFIED" -gt "$LAST_CHECK" ]; then
        # Check for trigger-lldp requests in last 2 minutes
        TRIGGER_FOUND=$(tail -50 "$ACCESS_LOG" | grep -c "POST /trigger-lldp")
        
        if [ "$TRIGGER_FOUND" -gt 0 ]; then
            # Update last check timestamp
            echo "$LOG_MODIFIED" > "$LAST_CHECK_FILE"
            
            # Create lock file with PID
            echo $$ > "$LOCK_FILE"
            
            {
                echo "$(date): Web trigger detected, starting LLDP check..."
                cd "$MONITOR_DIR"
                
                # Run the LLDP check
                ./check-lldp.sh
                
                echo "$(date): LLDP check completed"
            } >> "$LOG_FILE" 2>&1
            
            # Remove lock file
            rm -f "$LOCK_FILE"
        else
            # Update last check even if no trigger found
            echo "$LOG_MODIFIED" > "$LAST_CHECK_FILE"
        fi
    fi
fi