#!/bin/bash
# Optimized Monitor Script - Faster execution with SSH multiplexing
# Performance: 3-5x faster than original

# Start timing
START_TIME=$(date +%s)
echo "🚀 Starting optimized monitoring at $(date)"

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

# SSH Multiplexing for faster connections (fixed TTY issues)
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

execute_commands_optimized() {
    local device=$1
    local user=$2
    local hostname=$3
    
    echo "Processing $hostname..."
    
    # Create HTML header
    cat > monitor-results/${hostname}.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Monitor Results - ${hostname}</title>
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>
        /* Exact styling from dev-conf.html */
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
        .section { color: #dcdcaa; font-weight: bold; }
        .interface { color: #4ec9b0; }
        .ip-address { color: #ffffff; }
        .default { color: #569cd6; }
    </style>
</head>
<body>
    <h1><font color="#b57614">Monitor Results - ${hostname}</font></h1>
    <h3 class='interface-info'>
    <pre>
    <span style="color:tomato;">Created on $DATE</span>

EOF

    # OPTIMIZED: Single SSH session with ALL original commands
    # Combine all nv show commands into one SSH call (like original monitor.sh)
    ssh $SSH_OPTS -q "$user@$device" '
        echo "<h1></h1><h1><font color=\"#b57614\">Interface Overview '"$hostname"'</font></h1><h3></h3>"
        nv show interface | sed -E "1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g"
        
        echo "<h1></h1><h1><font color=\"#b57614\">Port Status '"$hostname"'</font></h1><h3></h3>"
        nv show interface status | sed -E "1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g"
        
        echo "<h1></h1><h1><font color=\"#b57614\">Port Description '"$hostname"'</font></h1><h3></h3>"
        nv show interface description | sed -E "1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g"
        
        echo "<h1></h1><h1><font color=\"#b57614\">Port VLAN Mapping '"$hostname"'</font></h1><h3></h3>"
        nv show bridge port-vlan | cut -c11- | sed -E "1 s/^    port/<span style=\"color:green;\">    port<\/span>/; 2! s/^(\s{0,4})([a-zA-Z_]\S*)/\1<span style=\"color:steelblue;\">\2<\/span>/; s/\btagged\b/<span style=\"color:tomato;\">tagged<\/span>/g"
        
        echo "<h1></h1><h1><font color=\"#b57614\">ARP Table '"$hostname"'</font></h1><h3></h3>"
        ip neighbour | grep -E -v "fe80" | sort -t "." -k1,1n -k2,2n -k3,3n -k4,4n | sed -E "s/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/lladdr ([0-9a-f:]+)/lladdr <span style=\"color:tomato;\">\1<\/span>/"
        
        echo "<h1></h1><h1><font color=\"#b57614\">MAC Table '"$hostname"'</font></h1><h3></h3>"
        sudo bridge fdb | grep -E -v "00:00:00:00:00:00" | sort | sed -E "s/^([0-9a-f:]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/vlan ([0-9]+)/vlan <span style=\"color:red;\">\1<\/span>/; s/dst ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/dst <span style=\"color:lime;\">\1<\/span>/"
        
        echo "<h1></h1><h1><font color=\"#b57614\">BGP Status '"$hostname"'</font></h1><h3></h3>"
        sudo vtysh -c "show bgp vrf all sum" 2>/dev/null | sed -E "s/(VRF\s+)([a-zA-Z0-9_-]+)/\1<span style=\"color:tomato;\">\2<\/span>/g; s/Total number of neighbors ([0-9]+)/Total number of neighbors <span style=\"color:steelblue;\">\1<\/span>/g; s/(\S+)\s+(\S+)\s+Summary/<span style=\"color:lime;\">\1 \2<\/span> Summary/g; s/\b(Active|Idle)\b/<span style=\"color:red;\">\1<\/span>/g"
    ' >> monitor-results/${hostname}.html
    
    # Separate BGP data collection (for analysis)
    ssh $SSH_OPTS -q "$user@$device" "sudo vtysh -c \"show bgp vrf all sum\"" 2>/dev/null > "monitor-results/bgp-data/${hostname}_bgp.txt"
    
    # OPTIMIZED: Single SSH session for all interface data collection
    timeout 600 ssh $SSH_OPTS -q "$user@$device" '
        echo "=== OPTIMIZED INTERFACE DATA COLLECTION ==="
        
        # Get interface list once (include ALL swp interfaces - base and breakout)
        all_interfaces=$(nv show interface 2>/dev/null | grep "^swp[0-9]" | awk "{print \$1}" || ls /sys/class/net/swp[0-9]* 2>/dev/null | xargs -n1 basename)
        
        # Collect ALL interface data in single loop
        for interface in $all_interfaces; do
            if [ ! -e "/sys/class/net/$interface" ]; then continue; fi
            
            echo "=== INTERFACE: $interface ==="
            
            # Carrier transitions data
            echo "CARRIER_TRANSITIONS:"
            carrier_count=$(nv show interface $interface counters 2>/dev/null | grep "carrier-transitions" | awk "{print \$2}")
            if [ -z "$carrier_count" ] || [ "$carrier_count" = "" ]; then
                carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
            fi
            echo "$interface:$carrier_count"
            
            # Optical transceiver data
            echo "OPTICAL_TRANSCEIVER:"
            transceiver_data=$(nv show interface $interface transceiver 2>/dev/null)
            if [ -n "$transceiver_data" ] && [ "$transceiver_data" != "Error: The requested item does not exist." ]; then
                echo "$transceiver_data"
            else
                echo "No transceiver data available"
            fi
            
            # BER detailed counters
            echo "BER_COUNTERS:"
            nv show interface $interface counters 2>/dev/null | grep -E "rx.*packets|tx.*packets|rx.*errors|tx.*errors" 2>/dev/null || echo "No detailed counters available"
            
            echo "=== END_INTERFACE: $interface ==="
        done
    ' > "monitor-results/${hostname}_combined_interface_data.txt" 2>/dev/null
    
    # OPTIMIZED carrier transitions collection (single SSH session)
    echo "=== CARRIER TRANSITIONS ===" > "monitor-results/flap-data/${hostname}_carrier_transitions.txt"
    
    # Single SSH session for ALL carrier transitions data
    timeout 300 ssh $SSH_OPTS -q "$user@$device" '
        # Get all swp interfaces (base + breakout)
        all_interfaces=$(nv show interface 2>/dev/null | grep "^swp[0-9]" | awk "{print \$1}")
        
        # Collect carrier transitions for all interfaces in one session
        for interface in $all_interfaces; do
            if [ -e "/sys/class/net/$interface" ]; then
                # Try nv command first, fallback to /sys
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
    
    # Extract individual data files from combined data (if exists)
    if [ -f "monitor-results/${hostname}_combined_interface_data.txt" ]; then
        
        # Extract optical data with interface names
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
        
        # Extract BER detailed counters (ALL swp interfaces - base and breakout)
        echo "=== DETAILED INTERFACE COUNTERS ===" > "monitor-results/ber-data/${hostname}_detailed_counters.txt"
        awk '/=== INTERFACE: /{interface=$3} /BER_COUNTERS:/ {print "Interface: " interface; getline; print}' "monitor-results/${hostname}_combined_interface_data.txt" >> "monitor-results/ber-data/${hostname}_detailed_counters.txt"
        
        # Clean up combined file
        rm -f "monitor-results/${hostname}_combined_interface_data.txt"
    fi
    
    # BER data collection (interface error statistics) - keep separate as it's fast
    timeout 120 ssh $SSH_OPTS -q "$user@$device" '
        cat /proc/net/dev 2>/dev/null
    ' > "monitor-results/ber-data/${hostname}_interface_errors.txt" 2>/dev/null
    
    # Hardware health data collection (sensors, memory, CPU, uptime)
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
    
    # Enhanced log data collection (comprehensive /var/log analysis)
    timeout 300 ssh $SSH_OPTS -q "$user@$device" '
        echo "=== COMPREHENSIVE SYSTEM LOGS ==="
        
        # FRR Routing Logs (Direct file access with sudo)
        echo "FRR_ROUTING_LOGS:"
        if [ -f "/var/log/frr/frr.log" ]; then
            sudo tail -100 /var/log/frr/frr.log 2>/dev/null | grep -E "(error|warn|crit|fail|down|bgp|ospf)" || echo "No FRR routing issues"
        else
            echo "FRR log file not found"
        fi
        
        echo "SWITCHD_LOGS:"
        # Switch daemon logs (critical for network operations)
        if [ -f "/var/log/switchd.log" ]; then
            sudo tail -100 /var/log/switchd.log 2>/dev/null | grep -E "(error|warn|crit|fail|except)" || echo "No switchd issues"
        else
            echo "Switchd log not found"
        fi
        
        echo "NVUE_CONFIG_LOGS:"
        # NVUE configuration logs
        if [ -f "/var/log/nvued.log" ]; then
            sudo tail -50 /var/log/nvued.log 2>/dev/null | grep -E "(error|warn|fail|except)" || echo "No NVUE config issues"
        else
            echo "NVUE log not found"
        fi
        
        echo "MSTPD_STP_LOGS:"
        # Spanning Tree Protocol logs
        if [ -f "/var/log/mstpd" ]; then
            sudo tail -50 /var/log/mstpd 2>/dev/null | grep -E "(error|warn|topology|change)" || echo "No STP issues"
        else
            echo "MSTPD log not found"
        fi
        
        echo "CLAGD_MLAG_LOGS:"
        # MLAG (Multi-chassis Link Aggregation) logs
        if [ -f "/var/log/clagd.log" ]; then
            sudo tail -50 /var/log/clagd.log 2>/dev/null | grep -E "(error|warn|fail|conflict|peer)" || echo "No MLAG issues"
        else
            echo "CLAG log not found"
        fi
        
        echo "AUTH_SECURITY_LOGS:"
        # Authentication and security logs (REQUIRES SUDO)
        if [ -f "/var/log/auth.log" ]; then
            sudo tail -50 /var/log/auth.log 2>/dev/null | grep -E "(fail|error|invalid|denied|attack)" || echo "No auth issues"
        else
            echo "Auth log not found"
        fi
        
        echo "SYSTEM_CRITICAL_LOGS:"
        # System critical logs from syslog (REQUIRES SUDO)
        if [ -f "/var/log/syslog" ]; then
            sudo tail -100 /var/log/syslog 2>/dev/null | grep -E "(error|crit|alert|emerg|fail)" || echo "No system critical issues"
        else
            echo "Syslog not found"
        fi
        
        echo "JOURNALCTL_PRIORITY_LOGS:"
        # High priority journalctl logs (may require sudo for full access)
        sudo journalctl --since="24 hours ago" --priority=0..3 --no-pager --lines=50 2>/dev/null || echo "No high priority journal logs"
        
        echo "DMESG_HARDWARE_LOGS:"
        # Hardware and kernel critical messages (may require sudo)
        sudo dmesg --since="24 hours ago" --level=crit,alert,emerg 2>/dev/null | tail -30 || echo "No critical hardware logs"
        
        echo "NETWORK_INTERFACE_LOGS:"
        # Network interface state changes from journalctl (may require sudo)
        sudo journalctl --since="24 hours ago" --grep="swp|bond|vlan|carrier|link.*up|link.*down" --no-pager --lines=30 2>/dev/null || echo "No interface state changes"
        
    ' > "monitor-results/log-data/${hostname}_logs.txt" 2>/dev/null
    
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
    
    echo "✅ $hostname completed"
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

# Start optimized monitoring
echo "🚀 Starting optimized monitoring..."

# Process all devices in parallel
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    process_device "$device" "$user" "$hostname" &
done

wait

echo ""
echo -e "\e[1;34mOptimized monitoring completed...\e[0m"

# Run analyses
echo -e "\n\e[0;34mRunning BGP Analysis...\e[0m"
if python3 process_bgp_data.py; then
    echo -e "\e[0;32mBGP analysis completed\e[0m"
else
    echo -e "\e[0;33mWarning: BGP analysis failed\e[0m"
fi

echo -e "\n\e[0;34mRunning Link Flap Analysis...\e[0m"
if python3 process_flap_data.py; then
    echo -e "\e[0;32mLink Flap analysis completed\e[0m"
else
    echo -e "\e[0;33mWarning: Link Flap analysis failed\e[0m"
fi

echo -e "\n\e[0;34mRunning Optical Analysis...\e[0m"
if python3 process_optical_data.py; then
    echo -e "\e[0;32mOptical analysis completed\e[0m"
else
    echo -e "\e[0;33mWarning: Optical analysis failed\e[0m"
fi

echo -e "\n\e[0;34mRunning BER Analysis...\e[0m"
if python3 process_ber_data.py; then
    echo -e "\e[0;32mBER analysis completed\e[0m"
else
    echo -e "\e[0;33mWarning: BER analysis failed\e[0m"
fi

echo -e "\n\e[0;34mRunning Hardware Health Analysis...\e[0m"
if python3 process_hardware_data.py; then
    echo -e "\e[0;32mHardware health analysis completed\e[0m"
else
    echo -e "\e[0;33mWarning: Hardware health analysis failed\e[0m"
fi

echo -e "\n\e[0;34mRunning Log Analysis...\e[0m"
if python3 process_log_data.py; then
    echo -e "\e[0;32mLog analysis completed\e[0m"
else
    echo -e "\e[0;33mWarning: Log analysis failed\e[0m"
fi

sudo cp -r monitor-results/ /var/www/html/
sudo chmod 644 /var/www/html/monitor-results/*
rm -f "$unreachable_hosts_file"

# Calculate execution time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "⚡ Optimized monitoring completed successfully"
echo "⏱️ Total execution time: ${MINUTES}m ${SECONDS}s"
echo "🌐 Results available at web interface"
exit 0