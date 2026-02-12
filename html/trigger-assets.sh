#!/usr/bin/env bash
# Assets Web Trigger Script
# Called by nginx via fcgiwrap

# Set HTTP headers
echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: POST, OPTIONS"
echo "Access-Control-Allow-Headers: Content-Type"
echo ""

# Handle CORS preflight
if [[ "$REQUEST_METHOD" == "OPTIONS" ]]; then
    echo '{"status": "ok", "message": "CORS preflight"}'
    exit 0
fi

# Create trigger file
TRIGGER_FILE="/tmp/.assets_web_trigger"
echo "$(date +%s)" | sudo tee "$TRIGGER_FILE" >/dev/null 2>&1 || echo "$(date +%s)" > "$TRIGGER_FILE" 2>/dev/null

# Return JSON response
if [ -f "$TRIGGER_FILE" ]; then
    echo '{"status": "started", "message": "Assets refresh triggered", "note": "Refresh will complete within 30 seconds."}'
else
    echo '{"status": "error", "message": "Failed to create trigger file"}'
fi
