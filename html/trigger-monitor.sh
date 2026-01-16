#!/usr/bin/env bash

# Trigger script for monitor.sh
# This script is called by Nginx to trigger a monitor analysis

# Set content type for JSON response
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: POST, OPTIONS"
echo "Access-Control-Allow-Headers: Content-Type"
echo ""

# Handle OPTIONS request (preflight)
if [ "$REQUEST_METHOD" = "OPTIONS" ]; then
    echo ""
    exit 0
fi

# Only allow POST requests
if [ "$REQUEST_METHOD" != "POST" ]; then
    echo '{"status": "error", "message": "Only POST method is allowed"}'
    exit 1
fi

# Create trigger file for monitor.sh
TRIGGER_FILE="/tmp/.monitor_web_trigger"

# Try to create the trigger file
if echo "$(date +%s)" | sudo tee "$TRIGGER_FILE" >/dev/null 2>&1 || echo "$(date +%s)" > "$TRIGGER_FILE" 2>/dev/null; then
    echo '{"status": "success", "message": "Monitor analysis triggered successfully"}'
else
    echo '{"status": "error", "message": "Failed to create trigger file"}'
    exit 1
fi 