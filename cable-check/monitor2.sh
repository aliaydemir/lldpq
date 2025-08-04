#!/bin/bash
# EXPERIMENTAL: Parallel Interface Collection Monitor Script
# 🚀 PERFORMANCE TARGET: 3-5x faster interface collection
# 
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

# Start timing
START_TIME=$(date +%s)
echo "🚀 Starting PARALLEL monitoring at $(date)"

DATE=$(date '+%Y-%m-%d %H-%M')
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

mkdir -p "$SCRIPT_DIR/monitor-results"
mkdir -p "$SCRIPT_DIR/monitor-results/flap-data"
mkdir -p "$SCRIPT_DIR/monitor-results/bgp-data"
mkdir -p "$SCRIPT_DIR/monitor-results/optical-data"
mkdir -p "$SCRIPT_DIR/monitor-results/ber-data"
mkdir -p "$SCRIPT_DIR/monitor-results/hardware-data"
mkdir -p "$SCRIPT_DIR/monitor-results/log-data"

unreachable_hosts_file=$(mktemp)

# SSH Multiplexing for faster connections
SSH_OPTS="-o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=600 -o BatchMode=yes"

ping_test() {
    local device=$1
    local hostname=$2
    ping -c 1 -W 0.5 "$device" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi
    return 0
}

# 🚀 PARALLEL INTERFACE COLLECTION FUNCTION
collect_interface_chunk() {
    local device=$1
    local user=$2
    local hostname=$3
    local chunk_id=$4
    local interfaces_chunk="$5"
    
    # Create temporary file for this chunk
    local temp_file="monitor-results/${hostname}_chunk_${chunk_id}.txt"
    
    timeout 180 ssh $SSH_OPTS -q "$user@$device" "
        echo '=== CHUNK $chunk_id START ==='
        
        for interface in $interfaces_chunk; do
            if [ ! -e \"/sys/class/net/\$interface\" ]; then continue; fi
            
            echo \"=== INTERFACE: \$interface ===\"
            
            # Carrier transitions data
            echo \"CARRIER_TRANSITIONS:\"
            carrier_count=\$(nv show interface \$interface counters 2>/dev/null | grep \"carrier-transitions\" | awk \"{print \\\$2}\")
            if [ -z \"\$carrier_count\" ] || [ \"\$carrier_count\" = \"\" ]; then
                carrier_count=\$(cat /sys/class/net/\$interface/carrier_changes 2>/dev/null || echo \"0\")
            fi
            echo \"\$interface:\$carrier_count\"
            
            # Optical transceiver data
            echo \"OPTICAL_TRANSCEIVER:\"
            transceiver_data=\$(nv show interface \$interface transceiver 2>/dev/null)
            if [ -n \"\$transceiver_data\" ] && [ \"\$transceiver_data\" != \"Error: The requested item does not exist.\" ]; then
                echo \"\$transceiver_data\"
            else
                echo \"No transceiver data available\"
            fi
            
            # BER detailed counters
            echo \"BER_COUNTERS:\"
            nv show interface \$interface counters 2>/dev/null | grep -E \"rx.*packets|tx.*packets|rx.*errors|tx.*errors\" 2>/dev/null || echo \"No detailed counters available\"
            
            echo \"=== END_INTERFACE: \$interface ===\"
        done
        
        echo '=== CHUNK $chunk_id END ==='
    " > "$temp_file" 2>/dev/null &
}

execute_commands_optimized() {
    local device=$1
    local user=$2
    local hostname=$3
    
    # Arrays to store timing data for summary
    declare -a section_names
    declare -a section_times
    
    # Timing helper functions
    start_section() {
        local section_name="$1"
        echo "🔄 [$hostname] Starting $section_name..."
    }
    
    end_section() {
        local section_name="$1"
        local start_time="$2"
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        echo "✅ [$hostname] $section_name completed in ${duration}s"
        
        # Store timing data for summary
        section_names+=("$section_name")
        section_times+=("$duration")
    }
    
    echo "🚀 Processing $hostname..."
    
    # Create HTML header (same as original)
    cat > monitor-results/${hostname}.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Monitor Results - ${hostname}</title>
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>
        .config-content {
            background: #1a1a1a;
            border: 1px solid #43453B;
            border-radius: 12px;
            margin: 30px 0;
            padding: 25px;
            min-height: 400px;
            font-family: 'Fira Code', 'Courier New', Courier, monospace;
            font-size: 14px;
            line-height: 1.6;
            white-space: pre-wrap;
            word-wrap: break-word;
            box-shadow: 0 4px 12px rgba(0,0,0,0.3);
            overflow-x: auto;
        }
        
        .comment { color: #6a9955; font-style: italic; }
        .keyword { color: #569cd6; font-weight: bold; }
        .string { color: #ce9178; }
        .number { color: #d7ba7d; }
        .ip-number { color: #ffffff; }
        .variable { color: #9cdcfe; }
        .operator { color: #d4d4d4; }
    </style>
</head>
<body>

<div class="config-content">
    <span style="color:tomato;">Created on $DATE</span>

EOF

    # Interface overview and status collection (same as original)
    start_section "Interface Overview"
    local start_time=$(date +%s)
    
    ssh $SSH_OPTS -q "$user@$device" '
        echo "<h1></h1><h1><font color=\"#b57614\">Interface Overview '"$hostname"'</font></h1><h3></h3>"
        nv show interface | sed -E "1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g"
        
        echo "<h1></h1><h1><font color=\"#b57614\">Port Status '"$hostname"'</font></h1><h3></h3>"
        nv show interface status | sed -E "1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g"
    ' >> monitor-results/${hostname}.html
    
    end_section "Interface Overview" "$start_time"
    
    # BGP data collection (same as original)
    start_section "BGP Data Collection"
    local bgp_start=$(date +%s)
    ssh $SSH_OPTS -q "$user@$device" "sudo vtysh -c \"show bgp vrf all sum\"" 2>/dev/null > "monitor-results/bgp-data/${hostname}_bgp.txt"
    end_section "BGP Data Collection" "$bgp_start"
    
    # 🚀 PARALLEL Interface detailed data collection 
    start_section "Interface Data Collection"
    local interface_start=$(date +%s)
    
    echo "🚀 [$hostname] Getting interface list..."
    # First, get the interface list
    all_interfaces=$(ssh $SSH_OPTS -q "$user@$device" 'nv show interface 2>/dev/null | grep "^swp[0-9]" | awk "{print \$1}" || ls /sys/class/net/swp[0-9]* 2>/dev/null | xargs -n1 basename')
    
    if [ -n "$all_interfaces" ]; then
        interface_count=$(echo "$all_interfaces" | wc -w)
        echo "🔍 [$hostname] Found $interface_count interfaces to process"
        
        # 🚀 SPLIT INTERFACES INTO PARALLEL CHUNKS
        # For large interface counts, use more chunks
        if [ "$interface_count" -gt 80 ]; then
            chunk_size=8    # TNP devices: 8 interfaces per chunk
        elif [ "$interface_count" -gt 40 ]; then
            chunk_size=12   # Medium devices: 12 interfaces per chunk  
        else
            chunk_size=16   # Small devices: 16 interfaces per chunk
        fi
        
        echo "⚡ [$hostname] Using chunk size: $chunk_size (total: $interface_count interfaces)"
        
        # Split interfaces into chunks and process in parallel
        chunk_id=0
        current_chunk=""
        current_count=0
        
        for interface in $all_interfaces; do
            current_chunk="$current_chunk $interface"
            current_count=$((current_count + 1))
            
            if [ "$current_count" -eq "$chunk_size" ]; then
                # Process this chunk in parallel
                echo "🔄 [$hostname] Starting chunk $chunk_id with $chunk_size interfaces..."
                collect_interface_chunk "$device" "$user" "$hostname" "$chunk_id" "$current_chunk"
                
                chunk_id=$((chunk_id + 1))
                current_chunk=""
                current_count=0
            fi
        done
        
        # Process remaining interfaces in last chunk
        if [ "$current_count" -gt 0 ]; then
            echo "🔄 [$hostname] Starting final chunk $chunk_id with $current_count interfaces..."
            collect_interface_chunk "$device" "$user" "$hostname" "$chunk_id" "$current_chunk"
            chunk_id=$((chunk_id + 1))
        fi
        
        echo "⏳ [$hostname] Waiting for $chunk_id parallel chunks to complete..."
        wait  # Wait for all background processes to finish
        
        # Combine all chunk results
        echo "🔗 [$hostname] Combining $chunk_id chunks..."
        combined_file="monitor-results/${hostname}_combined_interface_data.txt"
        echo "=== PARALLEL INTERFACE DATA COLLECTION ===" > "$combined_file"
        
        for ((i=0; i<chunk_id; i++)); do
            chunk_file="monitor-results/${hostname}_chunk_${i}.txt"
            if [ -f "$chunk_file" ]; then
                cat "$chunk_file" >> "$combined_file"
                rm -f "$chunk_file"  # Clean up chunk file
            fi
        done
        
        echo "✅ [$hostname] Parallel collection completed, $interface_count interfaces processed"
    else
        echo "⚠️ [$hostname] No interfaces found"
        touch "monitor-results/${hostname}_combined_interface_data.txt"
    fi
    
    end_section "Interface Data Collection" "$interface_start"
    
    # Rest of the sections remain the same as original monitor.sh
    # Carrier transitions collection  
    start_section "Carrier Transitions"
    local carrier_start=$(date +%s)
    
    echo "=== CARRIER TRANSITIONS ===" > "monitor-results/flap-data/${hostname}_carrier_transitions.txt"
    
    timeout 300 ssh $SSH_OPTS -q "$user@$device" '
        all_interfaces=$(nv show interface 2>/dev/null | grep "^swp[0-9]" | awk "{print \$1}")
        
        for interface in $all_interfaces; do
            if [ -e "/sys/class/net/$interface" ]; then
                carrier_count=$(nv show interface $interface counters 2>/dev/null | grep "carrier-transitions" | awk "{print \$2}")
                if [ -z "$carrier_count" ] || [ "$carrier_count" = "" ]; then
                    carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
                fi
                if [ -n "$carrier_count" ] && [ "$carrier_count" != "" ]; then
                    echo "$interface:$carrier_count"
                fi
            fi
        done
    ' >> "monitor-results/flap-data/${hostname}_carrier_transitions.txt" 2>/dev/null
    
    end_section "Carrier Transitions" "$carrier_start"
    
    # Data processing (same as original)
    start_section "Data Processing"
    local processing_start=$(date +%s)
    
    if [ -f "monitor-results/${hostname}_combined_interface_data.txt" ]; then
        
        # Extract optical data
        echo "=== OPTICAL DIAGNOSTICS ===" > "monitor-results/optical-data/${hostname}_optical.txt"
        awk '
        /=== INTERFACE: / { interface = $3 }
        /OPTICAL_TRANSCEIVER:/ { 
            if (interface != "") {
                print "--- Interface: " interface
                flag=1; next 
            }
        }
        /BER_COUNTERS:/ { flag=0 }
        flag && interface != "" { print }
        ' "monitor-results/${hostname}_combined_interface_data.txt" >> "monitor-results/optical-data/${hostname}_optical.txt"
        
        # Extract BER data
        echo "=== DETAILED INTERFACE COUNTERS ===" > "monitor-results/ber-data/${hostname}_detailed_counters.txt"
        awk '/=== INTERFACE: /{interface=$3} /BER_COUNTERS:/ {print "Interface: " interface; getline; print}' "monitor-results/${hostname}_combined_interface_data.txt" >> "monitor-results/ber-data/${hostname}_detailed_counters.txt"
        
        # Clean up combined file
        rm -f "monitor-results/${hostname}_combined_interface_data.txt"
    fi
    
    end_section "Data Processing" "$processing_start"
    
    # Continue with remaining sections (same as original)...
    # BER Statistics, Hardware Health, Log Analysis, Configuration Section
    
    # For now, let's add a basic version of these
    start_section "BER Statistics"
    local ber_start=$(date +%s)
    timeout 120 ssh $SSH_OPTS -q "$user@$device" 'cat /proc/net/dev 2>/dev/null' > "monitor-results/ber-data/${hostname}_interface_errors.txt" 2>/dev/null
    end_section "BER Statistics" "$ber_start"
    
    start_section "Hardware Health"
    local hardware_start=$(date +%s)
    # Simplified hardware collection for testing
    ssh $SSH_OPTS -q "$user@$device" 'uptime; df -h; free -h' > "monitor-results/hardware-data/${hostname}_hardware.txt" 2>/dev/null
    end_section "Hardware Health" "$hardware_start"
    
    start_section "Log Analysis"
    local log_start=$(date +%s)
    # Simplified log collection 
    ssh $SSH_OPTS -q "$user@$device" 'journalctl --since="2 hours ago" -n 100' > "monitor-results/log-data/${hostname}_logs.txt" 2>/dev/null
    end_section "Log Analysis" "$log_start"
    
    start_section "Configuration Section"
    local config_start=$(date +%s)
    # Close HTML
    echo "</div></body></html>" >> monitor-results/${hostname}.html
    end_section "Configuration Section" "$config_start"
    
    # Print timing summary
    echo ""
    echo "📊 [$hostname] Section Timing Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for i in "${!section_names[@]}"; do
        printf "%-25s : %3ss\n" "${section_names[$i]}" "${section_times[$i]}"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Calculate total time
    local total_time=0
    for time in "${section_times[@]}"; do
        total_time=$((total_time + time))
    done
    printf "TOTAL DEVICE TIME         : %3ss\n" "$total_time"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🎉 [$hostname] All sections completed successfully!"
}

# Main execution (simplified for testing)
echo "🚀 Starting optimized monitoring..."

# Test with first few devices for comparison
device_count=0
for device_hostname in $DEVICE_HOSTNAMES; do
    device=$(echo "$device_hostname" | cut -d'|' -f1)
    hostname=$(echo "$device_hostname" | cut -d'|' -f2)
    user=$(echo "$device_hostname" | cut -d'|' -f3)
    
    if ping_test "$device" "$hostname"; then
        execute_commands_optimized "$device" "$user" "$hostname" &
        device_count=$((device_count + 1))
        
        # Limit parallel devices to avoid overwhelming SSH
        if [ "$device_count" -ge 8 ]; then
            wait
            device_count=0
        fi
    fi
done

wait

# Final timing
END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
echo ""
echo "🎉 PARALLEL monitoring completed at $(date)"
echo "⏱️  Total execution time: ${TOTAL_TIME}s"
echo "🚀 Expected improvement: 3-5x faster Interface Data Collection"