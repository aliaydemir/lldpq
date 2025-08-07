#!/bin/bash
# LLDP & Monitor Trigger Monitor - Self-loop daemon for web interface triggers
# Add to crontab: * * * * * /path/to/lldp_trigger_monitor.sh
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

MONITOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLDP_TRIGGER_FILE="/tmp/.lldp_web_trigger"
MONITOR_TRIGGER_FILE="/tmp/.monitor_web_trigger"
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

# Wait function to prevent conflicts
wait_until_not_running() {
    local script_name="$1"
    while pgrep -f "$script_name" >/dev/null; do
        sleep 2
    done
}

# Main daemon loop - check every 5 seconds
LLDP_LAST_CHECK_FILE="$MONITOR_DIR/.last_lldp_trigger_check"
MONITOR_LAST_CHECK_FILE="$MONITOR_DIR/.last_monitor_trigger_check"

while true; do
    # Check LLDP trigger
    LLDP_LAST_CHECK=0
    if [ -f "$LLDP_LAST_CHECK_FILE" ]; then
        LLDP_LAST_CHECK=$(cat "$LLDP_LAST_CHECK_FILE")
    fi

    if [ -f "$LLDP_TRIGGER_FILE" ]; then
        LLDP_TRIGGER_TIME=$(stat -c %Y "$LLDP_TRIGGER_FILE" 2>/dev/null || stat -f %m "$LLDP_TRIGGER_FILE" 2>/dev/null || echo 0)
        
        if [ "$LLDP_TRIGGER_TIME" -gt "$LLDP_LAST_CHECK" ]; then
            if [ -f "$LLDP_LOCK_FILE" ] && kill -0 "$(cat "$LLDP_LOCK_FILE")" 2>/dev/null; then
                : # LLDP check already running, skipping trigger
            else
                {                    
                    echo $$ > "$LLDP_LOCK_FILE"
                    echo "$LLDP_TRIGGER_TIME" > "$LLDP_LAST_CHECK_FILE"
                    cd "$MONITOR_DIR"

                    wait_until_not_running "./assets.sh"
                    /bin/bash ./assets.sh >/dev/null 2>&1
                    wait_until_not_running "./check-lldp.sh"
                    /bin/bash ./check-lldp.sh >/dev/null 2>&1
                    
                    rm -f "$LLDP_LOCK_FILE"
                }
            fi
        fi
    fi

    # Check Monitor trigger
    MONITOR_LAST_CHECK=0
    if [ -f "$MONITOR_LAST_CHECK_FILE" ]; then
        MONITOR_LAST_CHECK=$(cat "$MONITOR_LAST_CHECK_FILE")
    fi

    if [ -f "$MONITOR_TRIGGER_FILE" ]; then
        MONITOR_TRIGGER_TIME=$(stat -c %Y "$MONITOR_TRIGGER_FILE" 2>/dev/null || stat -f %m "$MONITOR_TRIGGER_FILE" 2>/dev/null || echo 0)
        
        # Debug: Log to temporary file
        echo "$(date): Monitor check - Trigger: $MONITOR_TRIGGER_TIME, Last: $MONITOR_LAST_CHECK" >> /tmp/monitor_debug.log
        
        if [ "$MONITOR_TRIGGER_TIME" -gt "$MONITOR_LAST_CHECK" ]; then
            echo "$(date): Monitor trigger activated, running monitor.sh" >> /tmp/monitor_debug.log
            echo "$(date): Writing timestamp $MONITOR_TRIGGER_TIME to $MONITOR_LAST_CHECK_FILE" >> /tmp/monitor_debug.log
            echo "$MONITOR_TRIGGER_TIME" > "$MONITOR_LAST_CHECK_FILE"
            echo "$(date): Timestamp written, changing to $MONITOR_DIR" >> /tmp/monitor_debug.log
            cd "$MONITOR_DIR"
            echo "$(date): Changed directory, checking if monitor.sh is running..." >> /tmp/monitor_debug.log
            while pgrep -f "./monitor\.sh" >/dev/null; do
                echo "$(date): monitor.sh is running, waiting..." >> /tmp/monitor_debug.log
                sleep 2
            done
            echo "$(date): Starting monitor.sh..." >> /tmp/monitor_debug.log
            /bin/bash ./monitor.sh >/dev/null 2>&1
            echo "$(date): Monitor.sh completed" >> /tmp/monitor_debug.log
        else
            echo "$(date): Monitor trigger not newer than last check" >> /tmp/monitor_debug.log
        fi
    else
        echo "$(date): Monitor trigger file not found" >> /tmp/monitor_debug.log
    fi
    
    # Sleep for 5 seconds before next check
    sleep 5
done