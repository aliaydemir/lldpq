#!/usr/bin/env bash
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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
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

# Get password if not provided
get_password() {
    if [ -z "$PASSWORD" ]; then
        echo -e "${BLUE}🔐 Sudo Passwordless Setup${NC}"
        echo "=================================="
        echo -e "${YELLOW}This script will configure passwordless sudo for $USERNAME${NC}"
        echo -e "${YELLOW}on all ${#devices[@]} devices in devices.yaml${NC}"
        echo ""
        echo -e "${YELLOW}Enter SSH password for $USERNAME:${NC}"
        read -s PASSWORD
        echo ""
        
        if [ -z "$PASSWORD" ]; then
            echo -e "${RED}❌ Error: Password cannot be empty${NC}"
            exit 1
        fi
        
        # Confirm password
        echo -e "${YELLOW}Confirm password:${NC}"
        read -s PASSWORD_CONFIRM
        echo ""
        
        if [ "$PASSWORD" != "$PASSWORD_CONFIRM" ]; then
            echo -e "${RED}❌ Error: Passwords do not match${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}✅ Password confirmed, starting sudo setup...${NC}"
        echo ""
    fi
}

get_password

# Check if sshpass is available
if ! command -v sshpass >/dev/null 2>&1; then
    echo -e "${RED}❌ ERROR: sshpass is required but not installed${NC}"
    echo -e "${YELLOW}Install with:${NC}"
    echo -e "${GREEN}  - Ubuntu/Debian: sudo apt-get install sshpass${NC}"
    echo -e "${GREEN}  - macOS: brew install sshpass${NC}"
    exit 1
fi

echo -e "${BLUE}Configuration Summary${NC}"
echo "=================================="
echo -e "${GREEN}Username: ${USERNAME}${NC}"
echo -e "${GREEN}Devices: ${#devices[@]}${NC}"
echo -e "${GREEN}Timeout: ${TIMEOUT}s${NC}"
echo ""

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=$TIMEOUT -o BatchMode=no"

# Function to setup sudo on a device
setup_sudo() {
    local device=$1
    local user=$2
    local hostname=$3
    
    echo -e "${YELLOW}Setting up $hostname...${NC}"
    
    # Setup passwordless sudo
    result=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS -q "$user@$device" \
        "echo '$PASSWORD' | sudo -S bash -c 'echo \"$USERNAME ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/10_$USERNAME && chmod 440 /etc/sudoers.d/10_$USERNAME'" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}------------------------------------${NC}"
        echo -e "${GREEN}✅ SUCCESS: $hostname${NC}"
        echo -e "${GREEN}------------------------------------${NC}"
        return 0
    else
        echo -e "${RED}------------------------------------${NC}"
        echo -e "${RED}❌ FAILED: $hostname${NC}"
        echo -e "${RED}Error: $result${NC}"
        echo -e "${RED}------------------------------------${NC}"
        return 1
    fi
}

# Check if sshpass is available
if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass is required but not installed"
    echo "Install with: sudo apt-get install sshpass (Ubuntu/Debian) or brew install sshpass (macOS)"
    exit 1
fi

echo -e "${BLUE}🚀 Starting parallel sudo setup...${NC}"
echo ""

# Process all devices in parallel
pids=()
success_count=0
total_count=${#devices[@]}

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    setup_sudo "$device" "$user" "$hostname" &
    pids+=($!)
done

# Wait for all to complete and count successes
echo -e "${YELLOW}⏳ Waiting for all devices to complete...${NC}"
for pid in "${pids[@]}"; do
    if wait $pid; then
        ((success_count++))
    fi
done

echo ""
echo "=================================="
echo -e "${BLUE}📊 Summary: ${success_count}/${total_count} devices configured${NC}"
echo ""

if [ $success_count -eq $total_count ]; then
    echo -e "${GREEN}🎉 All devices configured successfully!${NC}"
    echo -e "${GREEN}✅ Passwordless sudo is now enabled${NC}"
else
    echo -e "${YELLOW}⚠️  ${success_count} succeeded, $((total_count - success_count)) failed${NC}"
    echo -e "${YELLOW}💡 Check error messages above for failed devices${NC}"
fi

echo ""
echo -e "${BLUE}🧪 Test with:${NC}"
echo -e "${GREEN}   ssh $USERNAME@device 'sudo whoami'${NC}"
echo ""