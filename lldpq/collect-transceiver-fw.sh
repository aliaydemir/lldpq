#!/usr/bin/env bash
# collect-transceiver-fw.sh - Collect transceiver firmware versions via mlxlink
# Runs independently from monitor.sh, CLI only (not triggered from web UI)
# Skips OOB switches (SN2210) where mlxlink can cause ASIC reset
#
# Copyright (c) 2024-2026 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

# Build model map (hostname -> model) from assets.ini
declare -A device_models
if [ -f "$SCRIPT_DIR/assets.ini" ]; then
    while IFS= read -r line; do
        hostname=$(echo "$line" | awk '{print $1}')
        model=$(echo "$line" | awk '{print $5}')
        [ -n "$hostname" ] && [ -n "$model" ] && device_models["$hostname"]="$model"
    done < <(grep -v "^DEVICE-NAME\|^Created\|^$" "$SCRIPT_DIR/assets.ini")
fi

# Models to skip (mlxlink can cause ASIC reset on these platforms)
SKIP_MODELS="2210 2201 2010"

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR"
MAX_PARALLEL=10

mkdir -p "$SCRIPT_DIR/monitor-results/transceiver-data"

collect_fw() {
    local device=$1
    local user=$2
    local hostname=$3
    
    local output=$(timeout 120 ssh $SSH_OPTS -q "$user@$device" '
        all_interfaces=$(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}")
        MST_DEV=$(ls /dev/mst/ 2>/dev/null | grep pciconf0 | head -1)
        if [ -n "$MST_DEV" ]; then
            done_ports=""
            for iface in $all_interfaces; do
                port_num=$(echo "$iface" | sed "s/swp//" | sed "s/s.*//")
                case " $done_ports " in *" $port_num "*) continue ;; esac
                done_ports="$done_ports $port_num"
                FW=$(timeout 5 sudo mlxlink -d /dev/mst/$MST_DEV -m -p $port_num 2>/dev/null | grep "FW Version" | grep -v "N/A")
                if [ -n "$FW" ]; then
                    echo "swp${port_num}|${FW}"
                fi
            done
        fi
    ' 2>/dev/null)
    
    if [ -n "$output" ]; then
        echo "$output" > "monitor-results/transceiver-data/${hostname}_transceiver.txt"
        echo "  $hostname: $(echo "$output" | wc -l) modules"
    fi
}

echo "Collecting transceiver firmware versions..."
skipped=0
queued=0
pids=()
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    
    model="${device_models[$hostname]:-}"
    skip=false
    for sm in $SKIP_MODELS; do
        [[ "$model" == *"$sm"* ]] && skip=true && break
    done
    if $skip; then
        ((skipped++))
        continue
    fi
    
    ((queued++))
    collect_fw "$device" "$user" "$hostname" &
    pids+=($!)
    
    if [ ${#pids[@]} -ge $MAX_PARALLEL ]; then
        wait "${pids[0]}"
        pids=("${pids[@]:1}")
    fi
done
wait

echo "Queried: $queued devices (skipped $skipped SN2210/SN2201 switches)"
echo "Processing inventory..."
python3 process_transceiver_data.py 2>/dev/null
chown "$(whoami):www-data" monitor-results/transceiver_inventory.json 2>/dev/null
chmod 664 monitor-results/transceiver_inventory.json 2>/dev/null
echo "Done"
