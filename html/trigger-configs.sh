#!/usr/bin/env bash
# Config Collection Web Trigger Script
# Called by nginx via fcgiwrap - runs get-configs.sh in background

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

# Load config
source /etc/lldpq.conf 2>/dev/null || true
LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
LLDPQ_USER="${LLDPQ_USER:-lldpq}"

# Run get-configs.sh in background as lldpq user
sudo -u "$LLDPQ_USER" bash -c "cd $LLDPQ_DIR && ./get-configs.sh >/dev/null 2>&1" &

echo '{"status": "started", "message": "Config collection started", "note": "Configs will be available within 1-2 minutes."}'
