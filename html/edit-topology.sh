#!/bin/bash
# edit-topology.sh - Read/Write topology.dot via CGI
# Called by nginx fcgiwrap

# Load config from /etc/lldpq.conf (created by install.sh)
if [ -f /etc/lldpq.conf ]; then
    source /etc/lldpq.conf
fi

# Default to /home directory scan if not configured
if [ -z "$MONITOR_DIR" ]; then
    # Try common locations
    for dir in /home/*/monitor; do
        if [ -d "$dir" ] && [ -f "$dir/topology.dot" ]; then
            MONITOR_DIR="$dir"
            break
        fi
    done
fi

TOPOLOGY_FILE="${MONITOR_DIR}/topology.dot"

# Read request method
METHOD="${REQUEST_METHOD:-GET}"

# Output headers
echo "Content-Type: application/json"
echo ""

if [ "$METHOD" = "GET" ]; then
    # Read and return topology.dot content
    if [ -f "$TOPOLOGY_FILE" ]; then
        # Escape content for JSON
        CONTENT=$(cat "$TOPOLOGY_FILE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
        echo "{\"success\": true, \"content\": $CONTENT}"
    else
        echo "{\"success\": false, \"error\": \"File not found\"}"
    fi
    
elif [ "$METHOD" = "POST" ]; then
    # Read POST data (content to save)
    read -n "$CONTENT_LENGTH" POST_DATA
    
    # Extract content from JSON
    CONTENT=$(echo "$POST_DATA" | python3 -c 'import sys,json; data=json.load(sys.stdin); print(data.get("content", ""))')
    
    if [ -n "$CONTENT" ]; then
        # Backup existing file
        if [ -f "$TOPOLOGY_FILE" ]; then
            cp "$TOPOLOGY_FILE" "${TOPOLOGY_FILE}.bak"
        fi
        
        # Write new content
        echo "$CONTENT" > "$TOPOLOGY_FILE"
        
        if [ $? -eq 0 ]; then
            echo "{\"success\": true, \"message\": \"Topology saved successfully\"}"
        else
            echo "{\"success\": false, \"error\": \"Failed to write file\"}"
        fi
    else
        echo "{\"success\": false, \"error\": \"No content provided\"}"
    fi
else
    echo "{\"success\": false, \"error\": \"Invalid method\"}"
fi
