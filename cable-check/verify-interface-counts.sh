#!/bin/bash
# Verify interface counts across all devices

echo "🔍 Interface Count Verification Script"
echo "======================================"

# Load devices
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
source "$SCRIPT_DIR/devices.sh"

# Results file
RESULTS_FILE="interface_count_results.txt"
> "$RESULTS_FILE"

# SSH options
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

verify_device() {
    local device=$1
    local user=$2
    local hostname=$3
    
    echo "📡 Checking $hostname..."
    
    # Get interface list first
    interface_list=$(ssh $SSH_OPTS -q "$user@$device" 'nv show interface 2>/dev/null' 2>/dev/null)
    
    if [[ -z "$interface_list" ]]; then
        echo "$hostname: ERROR - Could not connect or get interface list" >> "$RESULTS_FILE"
        return
    fi
    
    # Process locally to avoid complex SSH
    {
        echo "=== INTERFACE COUNTS FOR $hostname ==="
        
        # Total SWP interfaces
        total_swp=$(echo "$interface_list" | grep -c "swp" || echo "0")
        echo "TOTAL_SWP: $total_swp"
        
        # Base interfaces only (swp1, swp2, swp32 - no breakouts)
        base_only=$(echo "$interface_list" | grep -E "swp[0-9]+\s" | grep -vE "swp[0-9]+s[0-9]+" | wc -l || echo "0")
        echo "BASE_ONLY: $base_only"
        
        # Breakout sub-interfaces (swp1s0, swp1s1, etc)  
        breakout_subs=$(echo "$interface_list" | grep -cE "swp[0-9]+s[0-9]+" || echo "0")
        echo "BREAKOUT_SUBS: $breakout_subs"
        
        # Admin up interfaces
        admin_up=$(echo "$interface_list" | grep -E "swp[0-9]+" | grep -c "up" || echo "0")
        echo "ADMIN_UP: $admin_up"
        
        # Quick sample check for transceivers (check first 5 interfaces)
        sample_interfaces=$(echo "$interface_list" | grep -E "swp[0-9]+\s" | head -5 | awk '{print $1}')
        sample_transceivers=0
        for iface in $sample_interfaces; do
            transceiver_check=$(ssh $SSH_OPTS -q "$user@$device" "nv show interface $iface transceiver 2>/dev/null" 2>/dev/null)
            if [[ -n "$transceiver_check" ]] && [[ "$transceiver_check" != *"does not exist"* ]]; then
                ((sample_transceivers++))
            fi
        done
        
        # Estimate total transceivers
        if [[ $sample_transceivers -gt 0 && $base_only -gt 0 ]]; then
            estimated_transceivers=$((sample_transceivers * base_only / 5))
        else
            estimated_transceivers=0
        fi
        echo "ESTIMATED_TRANSCEIVERS: $estimated_transceivers"
        
        echo "=== END_COUNTS ==="
    } >> "$RESULTS_FILE" 2>/dev/null &
}

echo "🚀 Starting parallel verification..."
echo ""

# Process all devices in parallel
pids=()
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    verify_device "$device" "$user" "$hostname" &
    pids+=($!)
done

# Wait for all to complete
echo "⏳ Waiting for all devices to respond..."
for pid in "${pids[@]}"; do
    wait $pid
done

echo ""
echo "✅ Verification completed! Processing results..."
echo ""

# Analyze results
echo "📊 INTERFACE COUNT SUMMARY"
echo "=========================="

total_devices=0
total_swp_sum=0
base_only_sum=0
breakout_subs_sum=0
transceivers_sum=0
traffic_sum=0
admin_up_sum=0

while IFS= read -r line; do
    if [[ $line == *"INTERFACE COUNTS FOR"* ]]; then
        hostname=$(echo "$line" | sed 's/.*FOR //' | sed 's/ ===$//')
        ((total_devices++))
        echo "📍 Device: $hostname"
    elif [[ $line == TOTAL_SWP:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        total_swp_sum=$((total_swp_sum + count))
        echo "  Total SWP interfaces: $count"
    elif [[ $line == BASE_ONLY:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        base_only_sum=$((base_only_sum + count))
        echo "  Base interfaces only: $count"
    elif [[ $line == BREAKOUT_SUBS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        breakout_subs_sum=$((breakout_subs_sum + count))
        echo "  Breakout sub-interfaces: $count"
    elif [[ $line == WITH_TRANSCEIVERS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        transceivers_sum=$((transceivers_sum + count))
        echo "  With transceivers: $count"
    elif [[ $line == WITH_TRAFFIC:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        traffic_sum=$((traffic_sum + count))
        echo "  With traffic: $count"
    elif [[ $line == ADMIN_UP:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        admin_up_sum=$((admin_up_sum + count))
        echo "  Admin up: $count"
        echo ""
    fi
done < "$RESULTS_FILE"

echo "🎯 NETWORK TOTALS"
echo "================="
echo "Total devices checked: $total_devices"
echo "Total SWP interfaces: $total_swp_sum"
echo "Base interfaces only: $base_only_sum" 
echo "Breakout sub-interfaces: $breakout_subs_sum"
echo "Interfaces with transceivers: $transceivers_sum"
echo "Interfaces with traffic: $traffic_sum"
echo "Admin up interfaces: $admin_up_sum"
echo ""

echo "🔍 ANALYSIS"
echo "==========="
if [[ $total_devices -gt 0 ]]; then
    avg_base=$((base_only_sum / total_devices))
    avg_transceivers=$((transceivers_sum / total_devices))
    avg_traffic=$((traffic_sum / total_devices))
    
    echo "Average base interfaces per device: $avg_base"
    echo "Average transceivers per device: $avg_transceivers"
    echo "Average traffic interfaces per device: $avg_traffic"
    echo ""
    
    echo "📈 EXPECTED DASHBOARD COUNTS"
    echo "============================"
    echo "Link Flap Total Ports: $base_only_sum (base interfaces)"
    echo "BER Total Ports: $traffic_sum (interfaces with traffic)"
    echo "Optical Total Ports: $transceivers_sum (interfaces with transceivers)"
    echo ""
    
    if [[ $breakout_subs_sum -gt $base_only_sum ]]; then
        echo "⚠️  WARNING: More breakout sub-interfaces than base interfaces!"
        echo "   This suggests monitor.sh was including breakouts before fix."
        echo "   Old total would have been: $total_swp_sum"
    fi
fi

echo "📄 Raw results saved to: $RESULTS_FILE"
echo "🎉 Verification complete!"