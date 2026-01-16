#!/usr/bin/env bash
# edit-config.sh - Read/Write topology_config.yaml via CGI
# Called by nginx fcgiwrap

# Load config with fallback
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

# topology_config.yaml is in web root
CONFIG_FILE="$WEB_ROOT/topology_config.yaml"

# Read request method
METHOD="${REQUEST_METHOD:-GET}"

# Output headers
echo "Content-Type: application/json"
echo ""

if [ "$METHOD" = "GET" ]; then
    # Read and return topology_config.yaml content
    if [ -f "$CONFIG_FILE" ]; then
        # Escape content for JSON
        CONTENT=$(cat "$CONFIG_FILE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
        echo "{\"success\": true, \"content\": $CONTENT}"
    else
        echo "{\"success\": false, \"error\": \"File not found\"}"
    fi
    
elif [ "$METHOD" = "POST" ]; then
    # Read POST data from stdin
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    else
        POST_DATA=$(cat)
    fi
    
    # Extract content from JSON using Python
    CONTENT=$(echo "$POST_DATA" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get("content", ""))
except:
    print("")
' 2>/dev/null)
    
    if [ -n "$CONTENT" ]; then
        # Backup existing file
        if [ -f "$CONFIG_FILE" ]; then
            cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
        fi
        
        # Write new content
        echo "$CONTENT" > "$CONFIG_FILE"
        
        if [ $? -eq 0 ]; then
            echo "{\"success\": true, \"message\": \"Config saved successfully\"}"
        else
            echo "{\"success\": false, \"error\": \"Failed to write file\"}"
        fi
    else
        echo "{\"success\": false, \"error\": \"No content provided\"}"
    fi
else
    echo "{\"success\": false, \"error\": \"Invalid method\"}"
fi
