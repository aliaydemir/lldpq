#!/bin/bash
# sudo-fix.sh - Sudo Passwordless Setup Tool
#
# Purpose:
#   Sets up passwordless sudo for cumulus user on all network devices
#
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

show_usage() {
    echo "Sudo Passwordless Setup Tool"
    echo "============================"
    echo ""
    echo "USAGE:"
    echo "  sudo-fix.sh [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help         Show this help message"
    echo "  -p PASSWORD        Specify password (otherwise will prompt)"
    echo "  -u USER            Specify username (default: cumulus)"
    echo "  -t TIMEOUT         SSH timeout in seconds (default: 10)"
    echo ""
    echo "DESCRIPTION:"
    echo "  This tool configures passwordless sudo for the specified user"
    echo "  on all devices listed in devices.yaml"
    echo ""
}

# Default values
USERNAME="cumulus"
PASSWORD=""
TIMEOUT=10

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -p)
            PASSWORD="$2"
            shift 2
            ;;
        -u)
            USERNAME="$2"
            shift 2
            ;;
        -t)
            TIMEOUT="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Load devices
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
if [[ ! -f "$SCRIPT_DIR/devices.yaml" ]]; then
    echo "ERROR: devices.yaml not found in $SCRIPT_DIR"
    exit 1
fi

eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

# Check if devices are available
if [[ ${#devices[@]} -eq 0 ]]; then
    echo "ERROR: No devices found in devices.yaml"
    exit 1
fi

# Prompt for password if not provided
if [[ -z "$PASSWORD" ]]; then
    echo -n "Enter password for $USERNAME: "
    read -s PASSWORD
    echo ""
fi

if [[ -z "$PASSWORD" ]]; then
    echo "ERROR: Password is required"
    exit 1
fi

echo "Sudo Passwordless Setup"
echo "======================"
echo "Username: $USERNAME"
echo "Devices: ${#devices[@]}"
echo "Timeout: ${TIMEOUT}s"
echo ""

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=$TIMEOUT -o BatchMode=no"

# Function to setup sudo on a device
setup_sudo() {
    local device=$1
    local user=$2
    local hostname=$3
    
    echo "Setting up $hostname..."
    
    # Setup passwordless sudo
    result=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS -q "$user@$device" \
        "echo '$PASSWORD' | sudo -S bash -c 'echo \"$USERNAME ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/10_$USERNAME && chmod 440 /etc/sudoers.d/10_$USERNAME'" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo "SUCCESS: $hostname - Passwordless sudo configured"
    else
        echo "FAILED: $hostname - $result"
    fi
}

# Check if sshpass is available
if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required but not installed"
    echo "Install with: sudo apt-get install sshpass (Ubuntu/Debian) or brew install sshpass (macOS)"
    exit 1
fi

echo "Starting parallel sudo setup..."
echo ""

# Process all devices in parallel
pids=()
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    setup_sudo "$device" "$user" "$hostname" &
    pids+=($!)
done

# Wait for all to complete
echo "Waiting for all devices to complete..."
for pid in "${pids[@]}"; do
    wait $pid
done

echo ""
echo "Sudo setup completed!"
echo ""
echo "Test with: ssh user@device 'sudo whoami'"
echo ""