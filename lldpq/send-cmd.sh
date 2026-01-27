#!/usr/bin/env bash
# LLDPq Send Commands - Execute commands on network devices
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")

show_help() {
    cat << EOF
LLDPq Send Commands - Execute commands on network devices

Usage: send-cmd [options]

Options:
  -c <cmd>   Execute command (can use multiple times)
  -r <role>  Filter devices by role (e.g., spine, leaf, border)
  -h         Show this help message
  -l         List available commands (from commands file)
  -e         Edit commands file
  --roles    List available roles from devices.yaml

Description:
  Reads commands from '$SCRIPT_DIR/commands' file.
  Lines starting with # are ignored (commented out).
  Executes uncommented commands on all (or filtered) devices.

Roles:
  Add @role to devices.yaml:  10.10.100.10: Spine1 @spine
  Then filter:                send-cmd -r spine -c "uptime"

Examples:
  send-cmd                             # Run commands from file on all devices
  send-cmd -c "nv show system"         # Run command on all devices
  send-cmd -r spine -c "uptime"        # Run command only on @spine devices
  send-cmd -r leaf -c "nv show bgp"    # Run command only on @leaf devices
  send-cmd --roles                     # Show available roles
  send-cmd -l                          # List commands in file
  send-cmd -e                          # Edit commands file

EOF
    exit 0
}

# Parse arguments
cli_commands=()
role_filter=""

# Check for --roles first
if [[ "$1" == "--roles" ]]; then
    python3 "$SCRIPT_DIR/parse_devices.py" --list-roles
    exit 0
fi

while getopts "hlec:r:" opt; do
    case $opt in
        h) show_help ;;
        c) cli_commands+=("$OPTARG") ;;
        r) role_filter="$OPTARG" ;;
        l) 
            echo "Commands file: $SCRIPT_DIR/commands"
            echo ""
            cat "$SCRIPT_DIR/commands"
            exit 0
            ;;
        e)
            ${EDITOR:-nano} "$SCRIPT_DIR/commands"
            exit 0
            ;;
        *) show_help ;;
    esac
done

# Parse devices.yaml using Python parser (same as other lldpq scripts)
if [[ -n "$role_filter" ]]; then
    echo -e "\e[0;35mFiltering by role: @$role_filter\e[0m"
    eval "$(python3 "$SCRIPT_DIR/parse_devices.py" -r "$role_filter")" || exit 1
else
    eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"
fi

# Check if devices array is populated
if [[ ${#devices[@]} -eq 0 ]]; then
    echo "ERROR: No devices found. Check devices.yaml configuration."
    exit 1
fi

# Use CLI commands if provided, otherwise read from file
commands=()
if [[ ${#cli_commands[@]} -gt 0 ]]; then
    commands=("${cli_commands[@]}")
    echo -e "\e[0;36mUsing command-line arguments\e[0m"
else
    # Read commands from file (skip comments and empty lines)
    COMMANDS_FILE="$SCRIPT_DIR/commands"
    if [[ ! -f "$COMMANDS_FILE" ]]; then
        echo "ERROR: Commands file not found: $COMMANDS_FILE"
        exit 1
    fi

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        commands+=("$line")
    done < "$COMMANDS_FILE"

    if [[ ${#commands[@]} -eq 0 ]]; then
        echo "No commands to execute. Edit $COMMANDS_FILE and uncomment commands."
        echo "Or use: send-cmd -c \"your command\""
        exit 0
    fi
fi

echo ""
echo -e "\e[1;34mExecuting ${#commands[@]} command(s) on ${#devices[@]} device(s)...\e[0m"
echo ""

unreachable_hosts=()

ping_test() {
    local device=$1
    local hostname=$2
    ping -c 1 -W 1 "$device" >/dev/null 2>&1 || { unreachable_hosts+=("$device $hostname"); return 1; }
    return 0
}

TMPDIR=$(mktemp -d)
cleanup(){ rm -rf "$TMPDIR"; }
trap cleanup EXIT

execute_commands() {
    local device=$1
    local user=$2
    local hostname=$3
    local out="$TMPDIR/${hostname}.out"

    for command in "${commands[@]}"; do
        ssh_output=$(ssh -T -q -o StrictHostKeyChecking=no "$user@$device" "$command" 2>/dev/null)
        if [ -n "$ssh_output" ]; then
            {
                echo ""
                echo -e "\e[0;31m----------------------------------------------------------\e[0m"
                echo ""
                printf "\e[1;34m[ %-1s ] \e[1;33m%-1s\e[0m\n" "$hostname" "ssh $user@${device}"
                echo -e "\e[0;36mCommand: $command\e[0m"
                echo ""
                echo -e "\e[0;32m$ssh_output\e[0m"
                echo ""
                echo -e "\e[0;31m----------------------------------------------------------\e[0m"
            } >>"$out"
        fi
    done
}

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    ping_test "$device" "$hostname" && { execute_commands "$device" "$user" "$hostname" & sleep 0.1; }
done

wait

if compgen -G "$TMPDIR"/* >/dev/null; then
    while IFS= read -r f; do cat "$f"; done < <(printf "%s\n" "$TMPDIR"/* | sort)
fi

echo ""
echo -e "\e[1;34mAll commands have been executed.\e[0m"
echo ""

if [ ${#unreachable_hosts[@]} -ne 0 ]; then
    echo -e "\e[0;36mUnreachable hosts:\e[0m"
    echo ""
    printf "%s\n" "${unreachable_hosts[@]}" | sort -k2,2 | while IFS=' ' read -r ip hostname; do
        printf "\e[31m[%-14s]\t\e[0;31m[%-1s]\e[0m\n" "$ip" "$hostname"
    done
    echo ""
else
    echo -e "\e[0;32mAll hosts are reachable.\e[0m"
    echo ""
fi

exit 0
