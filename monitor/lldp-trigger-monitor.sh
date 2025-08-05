#!/bin/bash
# LLDP Trigger Monitor - Self-loop daemon for web interface triggers
# Add to crontab: * * * * * /path/to/lldp_trigger_monitor.sh
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRIGGER_FILE="/tmp/.lldp_web_trigger"
DAEMON_PID_FILE="/tmp/lldp_trigger_daemon.pid"
LLDP_LOCK_FILE="/tmp/lldp_running.lock"

# Exit if daemon already running
if [ -f "$DAEMON_PID_FILE" ]; then
    # Check if process is actually running
    if kill -0 "$(cat "$DAEMON_PID_FILE")" 2>/dev/null; then
        exit 0
    else
        # Stale PID file, remove it
        rm -f "$DAEMON_PID_FILE"
    fi
fi

# Create PID file for daemon
echo $$ > "$DAEMON_PID_FILE"

# Cleanup function
cleanup() {
    rm -f "$DAEMON_PID_FILE"
    exit 0
}

# Set trap for cleanup on exit
trap cleanup SIGTERM SIGINT EXIT

# Main daemon loop - check every 5 seconds
LAST_CHECK_FILE="$MONITOR_DIR/.last_trigger_check"

while true; do
    # Read last check timestamp
    LAST_CHECK=0
    if [ -f "$LAST_CHECK_FILE" ]; then
        LAST_CHECK=$(cat "$LAST_CHECK_FILE")
    fi

    # Check for trigger file
    if [ -f "$TRIGGER_FILE" ]; then
        TRIGGER_TIME=$(stat -c %Y "$TRIGGER_FILE" 2>/dev/null || stat -f %m "$TRIGGER_FILE" 2>/dev/null || echo 0)
        
        # Process trigger if timestamp is newer
        if [ "$TRIGGER_TIME" -gt "$LAST_CHECK" ]; then
            # Check if LLDP is already running
            if [ -f "$LLDP_LOCK_FILE" ] && kill -0 "$(cat "$LLDP_LOCK_FILE")" 2>/dev/null; then
                echo "$(date): LLDP check already running, skipping trigger" >> "$LOG_FILE"
            else
                {                    
                    # Create lock file with PID
                    echo $$ > "$LLDP_LOCK_FILE"
                    
                    # Update last check timestamp
                    echo "$TRIGGER_TIME" > "$LAST_CHECK_FILE"
                    
                    cd "$MONITOR_DIR"

                    # Wait function to prevent conflicts
                    wait_until_not_running() {
                        local script_name="$1"
                        while pgrep -f "$script_name" >/dev/null; do
                            sleep 2
                        done
                    }

                    # Run asset discovery and LLDP checks (sequential with conflict prevention)
                    wait_until_not_running "assets.sh"
                    /bin/bash ./assets.sh >/dev/null 2>&1
                    wait_until_not_running "check-lldp.sh"
                    /bin/bash ./check-lldp.sh >/dev/null 2>&1
                    
                    # Remove LLDP lock file
                    rm -f "$LLDP_LOCK_FILE"
                }
            fi
        fi
    fi
    
    # Sleep for 5 seconds before next check
    sleep 5
done