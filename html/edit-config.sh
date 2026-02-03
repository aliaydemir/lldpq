#!/usr/bin/env bash
# edit-config.sh - Read/Write topology_config.yaml via CGI
# Called by nginx fcgiwrap

# Load config with fallback
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"
LLDPQ_DIR="${LLDPQ_DIR:-/opt/lldpq}"

# topology_config.yaml is in web root
CONFIG_FILE="$WEB_ROOT/topology_config.yaml"

# Read request method and query string
METHOD="${REQUEST_METHOD:-GET}"
QUERY="${QUERY_STRING:-}"

# Parse action from query string
ACTION=""
if [[ "$QUERY" =~ action=([^&]+) ]]; then
    ACTION="${BASH_REMATCH[1]}"
fi

# Output headers
echo "Content-Type: application/json"
echo ""

# Handle get-inventory action - return device groups from Ansible inventory
if [ "$ACTION" = "get-inventory" ]; then
    # Fallback: try inventory.ini first, then hosts
    if [ -f "$ANSIBLE_DIR/inventory/inventory.ini" ]; then
        INVENTORY_FILE="$ANSIBLE_DIR/inventory/inventory.ini"
    elif [ -f "$ANSIBLE_DIR/inventory/hosts" ]; then
        INVENTORY_FILE="$ANSIBLE_DIR/inventory/hosts"
    else
        echo '{"success": false, "error": "Inventory file not found"}'
        exit 0
    fi
    
    # Parse inventory file and output as JSON
    export INVENTORY_FILE
    python3 << 'PYEOF'
import json
import re
import os

# Use INVENTORY_FILE from environment, fallback to checking both files
inventory_file = os.environ.get('INVENTORY_FILE')
if not inventory_file:
    ansible_dir = os.environ.get('ANSIBLE_DIR', '/home/nvidia/dt-mvp')
    for name in ['inventory.ini', 'hosts']:
        path = f"{ansible_dir}/inventory/{name}"
        if os.path.exists(path):
            inventory_file = path
            break

groups = {}
current_group = None

try:
    with open(inventory_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            
            # Check for group header
            group_match = re.match(r'^\[([^\]:]+)\]', line)
            if group_match:
                group_name = group_match.group(1)
                # Skip :children and :vars groups
                if ':' not in group_name:
                    current_group = group_name
                    if current_group not in groups:
                        groups[current_group] = []
                else:
                    current_group = None
                continue
            
            # Parse host entry
            if current_group:
                host_match = re.match(r'^(\S+)', line)
                if host_match:
                    hostname = host_match.group(1)
                    if hostname not in groups[current_group]:
                        groups[current_group].append(hostname)
    
    print(json.dumps({'success': True, 'groups': groups}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYEOF
    exit 0
fi

# Handle validate action
if [ "$ACTION" = "validate" ]; then
    VALIDATE_SCRIPT="$LLDPQ_DIR/nv-validate.py"
    CONFIG_DIR="$ANSIBLE_DIR/files/generated_config_folder"
    
    # Parse devices parameter (comma-separated list)
    DEVICES=""
    if [[ "$QUERY" =~ devices=([^&]+) ]]; then
        DEVICES="${BASH_REMATCH[1]}"
        # URL decode
        DEVICES=$(echo "$DEVICES" | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))')
    fi
    
    if [ ! -f "$VALIDATE_SCRIPT" ]; then
        echo '{"success": false, "error": "Validator script not found"}'
        exit 0
    fi
    
    if [ ! -d "$CONFIG_DIR" ]; then
        echo '{"success": false, "error": "Config directory not found: '"$CONFIG_DIR"'"}'
        exit 0
    fi
    
    # If specific devices requested, create temp dir with symlinks
    if [ -n "$DEVICES" ]; then
        TEMP_DIR=$(mktemp -d)
        IFS=',' read -ra DEVICE_ARRAY <<< "$DEVICES"
        for device in "${DEVICE_ARRAY[@]}"; do
            device=$(echo "$device" | xargs)  # trim whitespace
            if [ -f "$CONFIG_DIR/${device}.yaml" ]; then
                ln -s "$CONFIG_DIR/${device}.yaml" "$TEMP_DIR/${device}.yaml"
            elif [ -f "$CONFIG_DIR/${device}.yml" ]; then
                ln -s "$CONFIG_DIR/${device}.yml" "$TEMP_DIR/${device}.yml"
            fi
        done
        RESULT=$(python3 "$VALIDATE_SCRIPT" --dir "$TEMP_DIR" --json --no-topology 2>&1)
        rm -rf "$TEMP_DIR"
    else
        # Run validator on all configs
        RESULT=$(python3 "$VALIDATE_SCRIPT" --dir "$CONFIG_DIR" --json 2>&1)
    fi
    
    if [ $? -eq 0 ]; then
        echo '{"success": true, "valid": true, "result": '"$RESULT"'}'
    else
        # Check if it's JSON output (validation found errors)
        if echo "$RESULT" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
            echo '{"success": true, "valid": false, "result": '"$RESULT"'}'
        else
            # Script error
            ERROR=$(echo "$RESULT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
            echo '{"success": false, "error": '"$ERROR"'}'
        fi
    fi
    exit 0
fi

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
