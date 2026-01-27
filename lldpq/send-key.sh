#!/usr/bin/env bash
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

# Default values
DEFAULT_SSH_KEY="$HOME/.ssh/id_rsa.pub"
SSH_KEY=""
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
        -k|--key)
            SSH_KEY="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [-p password] [-k ssh_key_path]"
            echo "  -p, --password    SSH password for initial authentication"
            echo "  -k, --key         Path to SSH public key (default: ~/.ssh/id_rsa.pub)"
            echo ""
            echo "Distributes SSH keys to all devices defined in devices.yaml"
            echo ""
            echo "Examples:"
            echo "  $0                                    # Interactive mode"
            echo "  $0 -p 'mypassword'                    # Use default key with password"
            echo "  $0 -k ~/.ssh/custom_key.pub           # Use custom key"
            echo "  $0 -p 'mypassword' -k ~/.ssh/custom_key.pub  # Both specified"
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
    # SSH Key Selection (skip if already provided via command line)
    if [ -z "$SSH_KEY" ]; then
        echo -e "${BLUE}🔑 SSH Key Selection${NC}"
        echo "=================================="
        
        # Check if default key exists
        if [ -f "$DEFAULT_SSH_KEY" ]; then
            echo -e "${GREEN}Default SSH key found: ${DEFAULT_SSH_KEY}${NC}"
            echo -n -e "${YELLOW}Use this key? [Y/n]: ${NC}"
            read -r USE_DEFAULT
            
            if [[ "$USE_DEFAULT" =~ ^[Nn]$ ]]; then
                # User wants to specify custom key
                echo -e "${YELLOW}Enter path to your SSH public key:${NC}"
                read -r CUSTOM_KEY_PATH
                
                # Expand ~ to home directory
                CUSTOM_KEY_PATH="${CUSTOM_KEY_PATH/#\~/$HOME}"
                
                if [ -f "$CUSTOM_KEY_PATH" ]; then
                    SSH_KEY="$CUSTOM_KEY_PATH"
                    echo -e "${GREEN}✅ Using custom key: ${SSH_KEY}${NC}"
                else
                    echo -e "${RED}❌ Key file not found: ${CUSTOM_KEY_PATH}${NC}"
                    exit 1
                fi
            else
                # Use default key
                SSH_KEY="$DEFAULT_SSH_KEY"
                echo -e "${GREEN}✅ Using default key: ${SSH_KEY}${NC}"
            fi
        else
            # Default key doesn't exist
            echo -e "${YELLOW}Default SSH key not found: ${DEFAULT_SSH_KEY}${NC}"
            echo -n -e "${YELLOW}Generate new SSH key? [Y/n]: ${NC}"
            read -r GENERATE_KEY
            
            if [[ "$GENERATE_KEY" =~ ^[Nn]$ ]]; then
                # User doesn't want to generate, ask for custom path
                echo -e "${YELLOW}Enter path to your SSH public key:${NC}"
                read -r CUSTOM_KEY_PATH
                CUSTOM_KEY_PATH="${CUSTOM_KEY_PATH/#\~/$HOME}"
                
                if [ -f "$CUSTOM_KEY_PATH" ]; then
                    SSH_KEY="$CUSTOM_KEY_PATH"
                    echo -e "${GREEN}✅ Using custom key: ${SSH_KEY}${NC}"
                else
                    echo -e "${RED}❌ Key file not found: ${CUSTOM_KEY_PATH}${NC}"
                    exit 1
                fi
            else
                # Generate new key
                echo -e "${YELLOW}Generating new SSH key...${NC}"
                ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
                if [ $? -eq 0 ]; then
                    SSH_KEY="$DEFAULT_SSH_KEY"
                    echo -e "${GREEN}✅ SSH key generated successfully: ${SSH_KEY}${NC}"
                else
                    echo -e "${RED}❌ Failed to generate SSH key${NC}"
                    exit 1
                fi
            fi
        fi
        
        echo ""
    else
        # SSH_KEY provided via command line - validate it
        SSH_KEY="${SSH_KEY/#\~/$HOME}"
        if [ -f "$SSH_KEY" ]; then
            echo -e "${GREEN}✅ Using SSH key from command line: ${SSH_KEY}${NC}"
            echo ""
        else
            echo -e "${RED}❌ SSH key not found: ${SSH_KEY}${NC}"
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