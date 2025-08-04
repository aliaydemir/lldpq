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
    
    # BER interface statistics collection (EXACTLY SAME AS ORIGINAL)
    start_section "BER Statistics"
    local ber_start=$(date +%s)
    timeout 120 ssh $SSH_OPTS -q "$user@$device" '
        cat /proc/net/dev 2>/dev/null
    ' > "monitor-results/ber-data/${hostname}_interface_errors.txt" 2>/dev/null
    end_section "BER Statistics" "$ber_start"
    
    # Hardware health data collection (EXACTLY SAME AS ORIGINAL)
    start_section "Hardware Health"
    local hardware_start=$(date +%s)
    timeout 180 ssh $SSH_OPTS -q "$user@$device" '
        echo "HARDWARE_HEALTH:"
        sensors 2>/dev/null || echo "No sensors available"
        echo "MEMORY_INFO:"  
        free -h 2>/dev/null || echo "No memory info available"
        echo "CPU_INFO:"
        cat /proc/loadavg 2>/dev/null || echo "No CPU info available"
        echo "UPTIME_INFO:"
        uptime 2>/dev/null || echo "No uptime info available"
    ' > "monitor-results/hardware-data/${hostname}_hardware.txt" 2>/dev/null
    
    end_section "Hardware Health" "$hardware_start"
    
    # Enhanced log data collection (EXACTLY SAME AS ORIGINAL)
    start_section "Log Analysis"
    local log_start=$(date +%s)
    timeout 300 ssh $SSH_OPTS -q "$user@$device" '
        echo "=== COMPREHENSIVE SYSTEM LOGS ==="
        
        # FRR Routing Logs (HYBRID: TIME + SEVERITY - Critical Network Service)
        echo "FRR_ROUTING_LOGS:"
        if systemctl is-active --quiet frr 2>/dev/null; then
            # Use journalctl for time-based + severity filtering (more reliable for critical services)
            sudo journalctl -u frr --since="2 hours ago" --no-pager --lines=200 2>/dev/null | grep -E "(ERROR|WARN|CRIT|FAIL|DOWN|BGP|neighbor|peer)" || echo "No recent FRR routing issues"
        elif [ -f "/var/log/frr/frr.log" ]; then
            # Fallback to file-based but with date filtering
            sudo grep "$(date '\''+%b %d'\'')" /var/log/frr/frr.log 2>/dev/null | tail -30 | grep -E "(error|warn|crit|fail|down|bgp)" || echo "No recent FRR routing issues"
        else
            echo "FRR service/log not available"
        fi
        
        echo "SWITCHD_LOGS:"
        # Switch daemon logs (TIME-BASED: Last 2 hours only)
        if systemctl is-active --quiet switchd 2>/dev/null; then
            sudo journalctl -u switchd --since="2 hours ago" --no-pager --lines=50 2>/dev/null | grep -E "(ERROR|WARN|CRIT|FAIL|EXCEPT|port|link|vlan)" || echo "No recent switchd issues"
        elif [ -f "/var/log/switchd.log" ]; then
            # Fallback to file-based but with date filtering
            sudo grep "$(date '\''+%b %d'\'')" /var/log/switchd.log 2>/dev/null | tail -30 | grep -E "(error|warn|crit|fail|except)" || echo "No recent switchd issues"
        else
            echo "Switchd service/log not available"
        fi
        
        echo "NVUE_CONFIG_LOGS:"
        # NVUE configuration logs (TIME-BASED: Last 2 hours only)
        if systemctl is-active --quiet nvued 2>/dev/null; then
            sudo journalctl -u nvued --since="2 hours ago" --no-pager --lines=50 2>/dev/null | grep -E "(ERROR|WARN|FAIL|EXCEPT|config|commit|rollback)" || echo "No recent NVUE config issues"
        elif [ -f "/var/log/nvued.log" ]; then
            # Fallback to file-based but with date filtering
            sudo grep "$(date '\''+%b %d'\'')" /var/log/nvued.log 2>/dev/null | tail -30 | grep -E "(ERROR|WARN|FAIL|EXCEPT|config|commit|rollback)" || echo "No recent NVUE config issues"
        else
            echo "NVUE log not found"
        fi
        
        echo "MSTPD_STP_LOGS:"
        # Spanning Tree Protocol logs (TIME-BASED: Last 2 hours only)
        if systemctl is-active --quiet mstpd 2>/dev/null; then
            sudo journalctl -u mstpd --since="2 hours ago" --no-pager --lines=50 2>/dev/null | grep -E "(ERROR|WARN|TOPOLOGY|CHANGE|port|state|bridge)" || echo "No recent STP issues"
        elif [ -f "/var/log/mstpd" ]; then
            # Fallback to file-based but with date filtering
            sudo grep "$(date '\''+%b %d'\'')" /var/log/mstpd 2>/dev/null | tail -30 | grep -E "(ERROR|WARN|TOPOLOGY|CHANGE|port|state|bridge)" || echo "No recent STP issues"
        else
            echo "MSTPD log not found"
        fi
        
        echo "CLAGD_MLAG_LOGS:"
        # MLAG coordination logs (TIME-BASED: Last 2 hours only)
        if systemctl is-active --quiet clagd 2>/dev/null; then
            sudo journalctl -u clagd --since="2 hours ago" --no-pager --lines=50 2>/dev/null | grep -E "(ERROR|WARN|FAIL|CONFLICT|PEER|bond|backup|primary)" || echo "No recent MLAG issues"
        elif [ -f "/var/log/clagd.log" ]; then
            # Fallback to file-based but with date filtering
            sudo grep "$(date '\''+%b %d'\'')" /var/log/clagd.log 2>/dev/null | tail -30 | grep -E "(ERROR|WARN|FAIL|CONFLICT|PEER|bond|backup|primary)" || echo "No recent MLAG issues"
        else
            echo "CLAG log not found"
        fi
        
        echo "AUTH_SECURITY_LOGS:"
        # Authentication and security logs (TIME-BASED: Last 2 hours only, excluding monitoring activities)
        if systemctl is-active --quiet systemd-journald 2>/dev/null; then
            sudo journalctl --since="2 hours ago" --grep="FAIL|ERROR|INVALID|DENIED|ATTACK|authentication|unauthorized" --no-pager --lines=50 2>/dev/null | grep -v -E "(journalctl|monitor\.sh|--since|--grep)" || echo "No recent auth issues"
        elif [ -f "/var/log/auth.log" ]; then
            # Fallback to file-based but with date filtering (exclude monitoring activities)
            sudo grep "$(date '\''+%b %d'\'')" /var/log/auth.log 2>/dev/null | tail -30 | grep -E "(FAIL|ERROR|INVALID|DENIED|ATTACK|authentication|unauthorized)" | grep -v -E "(journalctl|monitor\.sh|--since)" || echo "No recent auth issues"
        else
            echo "Auth log not found"
        fi
        
        echo "SYSTEM_CRITICAL_LOGS:"
        # System critical logs from syslog (TIME-BASED: Last 2 hours only)
        if systemctl is-active --quiet systemd-journald 2>/dev/null; then
            sudo journalctl --since="2 hours ago" --priority=0..3 --grep="ERROR|CRIT|ALERT|EMERG|FAIL|kernel|oom|segfault" --no-pager --lines=50 2>/dev/null || echo "No recent system critical issues"
        elif [ -f "/var/log/syslog" ]; then
            # Fallback to file-based but with date filtering
            sudo grep "$(date '\''+%b %d'\'')" /var/log/syslog 2>/dev/null | tail -50 | grep -E "(ERROR|CRIT|ALERT|EMERG|FAIL|kernel|oom|segfault)" || echo "No recent system critical issues"
        else
            echo "Syslog not found"
        fi
        
        echo "JOURNALCTL_PRIORITY_LOGS:"
        # High priority journalctl logs (HYBRID: TIME + SEVERITY - System Wide)
        sudo journalctl --since="3 hours ago" --priority=0..3 --no-pager --lines=75 2>/dev/null | grep -E "(CRIT|ALERT|EMERG|ERROR|fail|crash|panic)" || echo "No high priority journal logs"
        
        echo "DMESG_HARDWARE_LOGS:"
        # Hardware and kernel critical messages (HYBRID: TIME + SEVERITY - Hardware Critical)
        sudo dmesg --since="3 hours ago" --level=crit,alert,emerg 2>/dev/null | tail -40 || echo "No critical hardware logs"
        
        echo "NETWORK_INTERFACE_LOGS:"
        # Network interface state changes (HYBRID: TIME + SEVERITY - Network Events)
        sudo journalctl --since="3 hours ago" --grep="swp|bond|vlan|carrier|link.*up|link.*down|port.*up|port.*down" --no-pager --lines=40 2>/dev/null || echo "No interface state changes"
        
    ' > "monitor-results/log-data/${hostname}_logs.txt" 2>/dev/null
    
    end_section "Log Analysis" "$log_start"
    
    # Device configuration section (EXACTLY SAME AS ORIGINAL)
    start_section "Configuration Section"
    local config_start=$(date +%s)
    
    # Add Device Configuration section to HTML
    cat >> monitor-results/${hostname}.html << EOF

<h1></h1><h1><font color="#b57614">Device Configuration - ${hostname}</font></h1><h3></h3>
EOF

    # Check if nv-set config exists and add it with syntax highlighting
    if [ -f "/var/www/html/configs/${hostname}.txt" ]; then
        echo "<h2><font color='steelblue'>NV Set Commands</font></h2>" >> monitor-results/${hostname}.html
        echo "<div class='config-content' id='config-content'>" >> monitor-results/${hostname}.html
        
        # Apply syntax highlighting with improved spacing
        cat "/var/www/html/configs/${hostname}.txt" | sed '
            # Escape HTML characters first
            s/</\&lt;/g; s/>/\&gt;/g;
            
            # Handle full-line comments first  
            s/^#.*/<span class="comment">&<\/span>/;
            
            # Handle description lines: highlight everything before description normally, then description content as comment
            /description/ {
                # First highlight interfaces in the command part (comprehensive pattern)
                #s/\b\(swp[0-9]\+\(s[0-9]\+\)\?\(-[0-9]\+\)\?\|bond[0-9_a-zA-Z-]\+\|vlan[0-9]\+\|eth[0-9]\+\|lo[0-9]*\|br[0-9]\+\|peerlink\)\b/<span class="interface">\1<\/span>/g;
                
                # Then split at description and make the content after it a comment (capture everything after description)
                s/\(.*\)\(description\s\+\)\(.*\)$/\1\2<span class="comment">\3<\/span>/;
            }
            
            # For non-description lines
            /description/! {
                # Highlight nv set commands
                #s/^\(\s*\)\(nv\s\+set\)\b/\1<span class="keyword">\2<\/span>/;
                
                # Highlight interfaces (comprehensive pattern)
                #s/\b\(swp[0-9]\+\(s[0-9]\+\)\?\(-[0-9]\+\)\?\|bond[0-9_a-zA-Z-]\+\|vlan[0-9]\+\|eth[0-9]\+\|lo[0-9]*\|br[0-9]\+\|peerlink\)\b/<span class="interface">\1<\/span>/g;
                
                # Highlight IP addresses
                #s/\b\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)\.\([0-9]\{1,3\}\)/<span class="ip-number">\1<\/span>.<span class="ip-number">\2<\/span>.<span class="ip-number">\3<\/span>.<span class="ip-number">\4<\/span>/g;
                
                # Highlight numbers  
                #s/\b\([0-9]\+\)\b/<span class="number">\1<\/span>/g;
            }
        ' >> monitor-results/${hostname}.html
        
        echo "</div>" >> monitor-results/${hostname}.html
    else
        echo "<p><span style='color: orange;'>⚠️  NV Set configuration not available for ${hostname}</span></p>" >> monitor-results/${hostname}.html
    fi
    
    # Close HTML
    cat >> monitor-results/${hostname}.html << EOF
    </pre>
    </h3>
    <span style="color:tomato;">Created on $DATE</span>
</body>
</html>
EOF
    
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

process_device() {
    local device=$1
    local user=$2
    local hostname=$3
    ping_test "$device" "$hostname"
    if [ $? -eq 0 ]; then
        execute_commands_optimized "$device" "$user" "$hostname"
    fi
}

# Start optimized monitoring (EXACTLY SAME AS ORIGINAL)
echo "🚀 Starting optimized monitoring..."

# Process all devices in parallel
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    process_device "$device" "$user" "$hostname" &
done

wait

echo ""
echo -e "\e[1;34mOptimized monitoring completed...\e[0m"

# Run analyses with timing (EXACTLY SAME AS ORIGINAL)
echo -e "\n🔬 \e[1;34mStarting Analysis Phase...\e[0m"

# Arrays to store analysis timing data
declare -a analysis_names
declare -a analysis_times

echo -e "🔄 Running BGP Analysis..."
bgp_start=$(date +%s)
if python3 process_bgp_data.py; then
    bgp_end=$(date +%s)
    bgp_duration=$((bgp_end - bgp_start))
    echo -e "✅ BGP analysis completed in ${bgp_duration}s"
    analysis_names+=("BGP Analysis")
    analysis_times+=("$bgp_duration")
else
    echo -e "⚠️  Warning: BGP analysis failed"
    analysis_names+=("BGP Analysis")
    analysis_times+=("FAILED")
fi

echo -e "🔄 Running Link Flap Analysis..."
flap_start=$(date +%s)
if python3 process_flap_data.py; then
    flap_end=$(date +%s)
    flap_duration=$((flap_end - flap_start))
    echo -e "✅ Link Flap analysis completed in ${flap_duration}s"
    analysis_names+=("Link Flap Analysis")
    analysis_times+=("$flap_duration")
else
    echo -e "⚠️  Warning: Link Flap analysis failed"
    analysis_names+=("Link Flap Analysis")
    analysis_times+=("FAILED")
fi

echo -e "🔄 Running Optical Analysis..."
optical_start=$(date +%s)
if python3 process_optical_data.py; then
    optical_end=$(date +%s)
    optical_duration=$((optical_end - optical_start))
    echo -e "✅ Optical analysis completed in ${optical_duration}s"
    analysis_names+=("Optical Analysis")
    analysis_times+=("$optical_duration")
else
    echo -e "⚠️  Warning: Optical analysis failed"
    analysis_names+=("Optical Analysis")
    analysis_times+=("FAILED")
fi

echo -e "🔄 Running BER Analysis..."
ber_start=$(date +%s)
if python3 process_ber_data.py; then
    ber_end=$(date +%s)
    ber_duration=$((ber_end - ber_start))
    echo -e "✅ BER analysis completed in ${ber_duration}s"
    analysis_names+=("BER Analysis")
    analysis_times+=("$ber_duration")
else
    echo -e "⚠️  Warning: BER analysis failed"
    analysis_names+=("BER Analysis")
    analysis_times+=("FAILED")
fi

echo -e "🔄 Running Hardware Health Analysis..."
hardware_start=$(date +%s)
if python3 process_hardware_data.py; then
    hardware_end=$(date +%s)
    hardware_duration=$((hardware_end - hardware_start))
    echo -e "✅ Hardware health analysis completed in ${hardware_duration}s"
    analysis_names+=("Hardware Analysis")
    analysis_times+=("$hardware_duration")
else
    echo -e "⚠️  Warning: Hardware health analysis failed"
    analysis_names+=("Hardware Analysis")
    analysis_times+=("FAILED")
fi

echo -e "🔄 Running Log Analysis..."
log_analysis_start=$(date +%s)
if python3 process_log_data.py; then
    log_analysis_end=$(date +%s)
    log_analysis_duration=$((log_analysis_end - log_analysis_start))
    echo -e "✅ Log analysis completed in ${log_analysis_duration}s"
    analysis_names+=("Log Analysis")
    analysis_times+=("$log_analysis_duration")
else
    echo -e "⚠️  Warning: Log analysis failed"
    analysis_names+=("Log Analysis")
    analysis_times+=("FAILED")
fi

# Display analysis timing summary (EXACTLY SAME AS ORIGINAL)
echo ""
echo "🔬 Analysis Phase Timing Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

total_analysis_time=0
for i in "${!analysis_names[@]}"; do
    analysis="${analysis_names[i]}"
    time="${analysis_times[i]}"
    if [ "$time" != "FAILED" ]; then
        total_analysis_time=$((total_analysis_time + time))
        printf "%-25s : %3ds\n" "$analysis" "$time"
    else
        printf "%-25s : %s\n" "$analysis" "FAILED"
    fi
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-25s : %3ds\n" "TOTAL ANALYSIS TIME" "$total_analysis_time"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sudo cp -r monitor-results/ /var/www/html/
sudo chmod 644 /var/www/html/monitor-results/*
rm -f "$unreachable_hosts_file"

# Calculate execution time (EXACTLY SAME AS ORIGINAL)
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "🎉 ==============================================="
echo "⚡ PARALLEL Enhanced monitoring completed successfully!"
echo "⏱️ Total execution time: ${MINUTES}m ${SECONDS}s"
echo "📊 All device sections completed with timing"
echo "🔬 All analysis phases completed with timing"  
echo "🌐 Results available at web interface"
echo "🚀 ONLY Interface Data Collection was parallelized!"
echo "=================================================="
exit 0