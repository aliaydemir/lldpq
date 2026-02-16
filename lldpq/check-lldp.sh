#!/usr/bin/env bash
# LLDPq Topology Check Script - OPTIMIZED VERSION
# Single SSH session per device + Parallel limits
#
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

# Start timing
START_TIME=$(date +%s)
echo "Starting LLDP check at $(date)"

DATE=$(date '+%Y-%m-%d--%H-%M')

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

# Load config with fallback
source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

# === TUNING PARAMETERS ===
MAX_PARALLEL=300  # Maximum parallel SSH connections
SSH_TIMEOUT=30    # SSH connection timeout in seconds

mkdir -p "$SCRIPT_DIR/lldp-results"

unreachable_hosts_file=$(mktemp)
active_jobs_file=$(mktemp)
completed_count_file=$(mktemp)
echo "0" > "$completed_count_file"

# Total device count for progress
TOTAL_DEVICES=${#devices[@]}

# SSH options with multiplexing
SSH_OPTS="-o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=60 -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT"

# Ping command - on Cumulus switches with Docker --privileged, the entrypoint
# adds 'ip rule' for mgmt VRF so plain ping works. No ip vrf exec needed.
PING="ping"

ping_test() {
    local device=$1
    local hostname=$2
    $PING -c 1 -W 0.5 "$device" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi
    return 0
}

# ============================================================================
# OPTIMIZED: Single SSH session collects ALL LLDP data
# ============================================================================
execute_commands_optimized() {
    local device=$1
    local user=$2
    local hostname=$3
    
    # Single SSH connection collects everything
    ssh $SSH_OPTS -T -q "$user@$device" "
        echo '=========================================${hostname}========================================='
        echo ''
        
        # LLDP data
        sudo lldpctl 2>/dev/null
        
        # Port status
        echo ''
        echo '===PORT_STATUS_START==='
        for port in /sys/class/net/swp*; do
            [ -d \"\$port\" ] || continue
            port_name=\$(basename \"\$port\")
            oper_state=\$(cat \"\$port/operstate\" 2>/dev/null || echo 'unknown')
            carrier=\$(cat \"\$port/carrier\" 2>/dev/null || echo '0')
            
            if [ \"\$oper_state\" = 'up' ] && [ \"\$carrier\" = '1' ]; then
                echo \"\$port_name UP\"
            elif [ \"\$oper_state\" = 'down' ] || [ \"\$carrier\" = '0' ]; then
                echo \"\$port_name DOWN\"
            else
                echo \"\$port_name UNKNOWN\"
            fi
        done | sort -V
        echo '===PORT_STATUS_END==='
        
        # Port speed
        echo ''
        echo '===PORT_SPEED_START==='
        for port in /sys/class/net/swp*; do
            [ -d \"\$port\" ] || continue
            port_name=\$(basename \"\$port\")
            speed=\$(cat \"\$port/speed\" 2>/dev/null || echo '0')
            if [ \"\$speed\" -gt 0 ] 2>/dev/null; then
                echo \"\$port_name \$speed\"
            fi
        done | sort -V
        echo '===PORT_SPEED_END==='
        echo ''
    " > "lldp-results/${hostname}_lldp_result.ini" 2>/dev/null
}

process_device() {
    local device=$1
    local user=$2
    local hostname=$3
    
    ping_test "$device" "$hostname"
    if [ $? -eq 0 ]; then
        execute_commands_optimized "$device" "$user" "$hostname"
    fi
    
    # Update progress counter (thread-safe with flock)
    (
        flock -x 200
        count=$(cat "$completed_count_file")
        count=$((count + 1))
        echo "$count" > "$completed_count_file"
        printf "\rCollecting [%d/%d]" "$count" "$TOTAL_DEVICES"
    ) 200>"$completed_count_file.lock"
}

# ============================================================================
# PARALLEL EXECUTION WITH LIMITS
# ============================================================================
echo "Devices: $TOTAL_DEVICES"

job_count=0
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    
    # Start job in background
    process_device "$device" "$user" "$hostname" &
    
    job_count=$((job_count + 1))
    
    # Limit parallel jobs
    if [ $job_count -ge $MAX_PARALLEL ]; then
        wait -n 2>/dev/null || wait
        job_count=$((job_count - 1))
    fi
done

# Wait for all remaining jobs
wait

echo ""
echo ""

# Show unreachable hosts
if [ -s "$unreachable_hosts_file" ]; then
    echo -e "\e[0;36mUnreachable hosts:\e[0m"
    echo ""
    while IFS= read -r host; do
        IFS=' ' read -r ip hostname <<< "$host"
        printf "\e[31m[%-14s]\t\e[0;31m[%-1s]\e[0m\n" "$ip" "$hostname"
    done < "$unreachable_hosts_file"
    echo ""
fi

# Run validation
echo "Validating..."
/usr/bin/python3 ./lldp-validate.py

# Process results
grep -v Pass lldp-results/lldp_results.ini > lldp-results/raw-problems-lldp_results.ini

awk 'NF' RS='\n\n' lldp-results/raw-problems-lldp_results.ini | awk '/No-Info/ || /Fail/' RS= | sed '/^================================/i\\' > lldp-results/problems-lldp_results.ini
if [ ! -s lldp-results/problems-lldp_results.ini ]; then
    head -n 1 lldp-results/raw-problems-lldp_results.ini >> lldp-results/problems-lldp_results.ini
    echo -e "\nGood news, there are no problematic ports..." >> lldp-results/problems-lldp_results.ini
fi
if ! grep -q "Created on" lldp-results/problems-lldp_results.ini; then
    header=$(head -n 1 lldp-results/raw-problems-lldp_results.ini)
    echo "$header" | cat - lldp-results/problems-lldp_results.ini > temp && mv temp lldp-results/problems-lldp_results.ini
fi

awk 'BEGIN{RS="\n\n"; ORS="\n\n"} /No-Info/' lldp-results/problems-lldp_results.ini | grep -v Fail > lldp-results/down-lldp_results.ini
if [ ! -s lldp-results/down-lldp_results.ini ]; then
    head -n 1 lldp-results/raw-problems-lldp_results.ini >> lldp-results/down-lldp_results.ini
    echo -e "\nGood news, there are no DOWN ports..." >> lldp-results/down-lldp_results.ini
fi
if ! grep -q "Created on" lldp-results/down-lldp_results.ini; then
    header=$(head -n 1 lldp-results/raw-problems-lldp_results.ini)
    echo "$header" | cat - lldp-results/down-lldp_results.ini > temp && mv temp lldp-results/down-lldp_results.ini
fi

# Copy results to web server
echo "Copying to web..."
sudo cp lldp-results/lldp_results.ini "$WEB_ROOT/"
sudo chown "${LLDPQ_USER:-$(whoami)}:www-data" "$WEB_ROOT/lldp_results.ini"
sudo chmod 664 "$WEB_ROOT/lldp_results.ini"
sudo mv "$WEB_ROOT/problems-lldp_results.ini" "$WEB_ROOT/hstr/Problems-${DATE}.ini" 2>/dev/null
sudo chown "${LLDPQ_USER:-$(whoami)}:www-data" "$WEB_ROOT/hstr/Problems-${DATE}.ini" 2>/dev/null
sudo chmod 664 "$WEB_ROOT/hstr/Problems-${DATE}.ini" 2>/dev/null
sudo cp lldp-results/problems-lldp_results.ini "$WEB_ROOT/"
sudo chown "${LLDPQ_USER:-$(whoami)}:www-data" "$WEB_ROOT/problems-lldp_results.ini"
sudo chmod 664 "$WEB_ROOT/problems-lldp_results.ini"

# Cleanup old history files (keep 1 per day for last 30 days)
folder_path="$WEB_ROOT/hstr"
cd "$folder_path" || exit 1
declare -a keep_files
for i in {1..30}; do
    start_date=$(date -d "$i days ago" '+%Y-%m-%d 00:00:00')
    end_date=$(date -d "$((i - 1)) days ago" '+%Y-%m-%d 00:00:00')
    file=$(find . -type f -name "*.ini" -newermt "$start_date" ! -newermt "$end_date" | sort | head -n 1)
    if [ -n "$file" ]; then
        keep_files+=("$file")
    fi
done
recent_files=$(find . -type f -name "*.ini" -mtime -1)
for file in $recent_files; do
    keep_files+=("$file")
done
find . -type f -name "*.ini" | while read file; do
    if [[ ! " ${keep_files[@]} " =~ " ${file} " ]]; then
        sudo rm "$file"
    fi
done

# Cleanup temp files
rm -f "$unreachable_hosts_file" "$active_jobs_file" "$completed_count_file" "$completed_count_file.lock"

# Show timing
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo ""
echo "Done: ${DURATION}s"
exit 0
