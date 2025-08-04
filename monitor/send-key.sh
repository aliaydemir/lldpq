#!/bin/bash
# send-key.sh - LLDPq SSH Key Distribution Script
#
# Purpose:
#   Distributes SSH public keys to all devices defined in devices.yaml
#   Uses sshpass for initial password authentication, then enables passwordless SSH
#
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details
#
# =============================================================================
# SEND-KEY.SH - LLDPq SSH Key Distribution Script  
# =============================================================================
#
# PURPOSE:
#   Distributes SSH public keys to all devices defined in devices.yaml
#   Uses sshpass for initial password authentication, then enables passwordless SSH
#
# USAGE:
#   ./send-key.sh                              # Send key to all devices (prompt for password)
#   ./send-key.sh -p "YourPassword"            # Send key with password parameter
#
# REQUIREMENTS:
#   - SSH public key (auto-generated if missing)
#   - sshpass package (auto-installed if missing)  
#   - Initial password access to all target devices
#   - devices.yaml configured with all target devices
#
# =============================================================================

SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

# Default values
SSH_KEY="$HOME/.ssh/id_rsa.pub"
PASSWORD=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-p password]"
            echo "  -p, --password    SSH password for initial authentication"
            echo ""
            echo "Distributes SSH keys to all devices defined in devices.yaml"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h for help"
            exit 1
            ;;
    esac
done

# Check and setup dependencies
check_dependencies() {
    # Check and generate SSH key if needed
    if [ ! -f "$SSH_KEY" ]; then
        echo -e "${YELLOW}SSH key not found. Generating new key...${NC}"
        ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✅ SSH key generated successfully${NC}"
        else
            echo -e "${RED}❌ Failed to generate SSH key${NC}"
            exit 1
        fi
    fi
    
    # Check and install sshpass if needed
    if ! command -v sshpass &> /dev/null; then
        echo -e "${YELLOW}sshpass not found. Installing...${NC}"
        if sudo apt update && sudo apt install -y sshpass; then
            echo -e "${GREEN}✅ sshpass installed successfully${NC}"
        else
            echo -e "${RED}❌ Failed to install sshpass${NC}"
            echo "Please install manually: sudo apt install sshpass"
            exit 1
        fi
    fi
}

# Get password if not provided
get_password() {
    if [ -z "$PASSWORD" ]; then
        echo -e "${YELLOW}This script will distribute SSH keys to all devices in devices.yaml${NC}"
        echo -e "${YELLOW}Enter SSH password (will be used for all switches):${NC}"
        read -s PASSWORD
        echo ""
        
        if [ -z "$PASSWORD" ]; then
            echo -e "${RED}Error: Password cannot be empty${NC}"
            exit 1
        fi
        
        echo -e "${GREEN}✅ Password received, starting key distribution...${NC}"
        echo ""
    fi
}

# Send key to a single device
send_key_to_device() {
    local device=$1
    local user=$2
    local hostname=$3
    
    echo "KEY sending: $user@$device ($hostname)"
    
    # Test if already configured
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -q "$user@$device" exit 2>/dev/null; then
        echo -e "${GREEN}------------------------------------${NC}"
        echo -e "${GREEN}KEY already configured: $device${NC}"
        echo -e "${GREEN}------------------------------------${NC}"
        return 0
    fi
    
    # Send the key using sshpass
    if sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "$SSH_KEY" "$user@$device" 2>/dev/null; then
        echo -e "${GREEN}------------------------------------${NC}"
        echo -e "${GREEN}KEY sent Successfully: $device${NC}"
        echo -e "${GREEN}------------------------------------${NC}"
        return 0
    else
        echo -e "${RED}------------------------------------${NC}"
        echo -e "${RED}KEY didnt Sent: $device${NC}"
        echo -e "${RED}------------------------------------${NC}"
        return 1
    fi
}

# Main function
main() {
    echo -e "${BLUE}🔑 LLDPq SSH Key Distribution${NC}"
    echo "=================================="
    
    check_dependencies
    get_password
    
    # Send to all devices (parallel execution)
    local success_count=0
    local total_count=${#devices[@]}
    local pids=()
    
    echo -e "${BLUE}Starting parallel key distribution to $total_count devices...${NC}"
    
    for device in "${!devices[@]}"; do
        IFS=' ' read -r user hostname <<< "${devices[$device]}"
        send_key_to_device "$device" "$user" "$hostname" &
        pids+=($!)
    done
    
    # Wait for all background processes and count successes
    for pid in "${pids[@]}"; do
        if wait $pid; then
            ((success_count++))
        fi
    done
    
    echo ""
    echo "=================================="
    echo -e "${BLUE}Summary: ${success_count}/${total_count} devices configured${NC}"
    
    if [ $success_count -eq $total_count ]; then
        echo -e "${GREEN}🎉 All devices configured successfully!${NC}"
        echo "You can now run: ./monitor.sh"
    else
        echo -e "${YELLOW}⚠️  Some devices need manual configuration${NC}"
    fi
}

main "$@"