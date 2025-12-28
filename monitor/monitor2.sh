#!/bin/bash
# Monitor Script - OPTIMIZED VERSION
# Single SSH session per device + Parallel limits + Parallel analysis
#
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

# Start timing
START_TIME=$(date +%s)
echo "🚀 Starting OPTIMIZED monitoring at $(date)"

DATE=$(date '+%Y-%m-%d %H-%M-%S')
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

# === TUNING PARAMETERS ===
MAX_PARALLEL=30  # Maximum parallel SSH connections (adjust based on your server)
SSH_TIMEOUT=60   # SSH connection timeout in seconds

mkdir -p "$SCRIPT_DIR/monitor-results"
mkdir -p "$SCRIPT_DIR/monitor-results/flap-data"
mkdir -p "$SCRIPT_DIR/monitor-results/bgp-data"
mkdir -p "$SCRIPT_DIR/monitor-results/optical-data"
mkdir -p "$SCRIPT_DIR/monitor-results/ber-data"
mkdir -p "$SCRIPT_DIR/monitor-results/hardware-data"
mkdir -p "$SCRIPT_DIR/monitor-results/log-data"

unreachable_hosts_file=$(mktemp)
active_jobs_file=$(mktemp)

# SSH options with multiplexing
SSH_OPTS="-o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPath=~/.ssh/cm-%r@%h:%p -o ControlPersist=60 -o BatchMode=yes -o ConnectTimeout=$SSH_TIMEOUT"

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

# ============================================================================
# OPTIMIZED: Single SSH session collects ALL data
# ============================================================================
execute_commands_optimized() {
    local device=$1
    local user=$2
    local hostname=$3
    local device_start=$(date +%s)
    
    echo "🔄 [$hostname] Starting data collection..."
    
    # Create HTML header
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

    # =========================================================================
    # SINGLE SSH SESSION - Collect ALL data at once
    # =========================================================================
    timeout 120 ssh $SSH_OPTS -q "$user@$device" '
        HOSTNAME_VAR="'"$hostname"'"
        
        # =====================================================================
        # SECTION 1: Interface Overview (for HTML)
        # =====================================================================
        echo "===HTML_OUTPUT_START==="
        
        echo "<h1></h1><h1><font color=\"#b57614\">Port Status '"$hostname"'</font></h1><h3></h3>"
        printf "<span style=\"color:green;\">%-14s %-12s %-12s %s</span>\n" "Interface" "State" "Link" "Description"
        
        for interface in $(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}" | sort -V); do
            if [ -e "/sys/class/net/$interface" ]; then
                state=$(cat /sys/class/net/$interface/operstate 2>/dev/null || echo "unknown")
                link_status=$([ "$state" = "up" ] && echo "up" || echo "down")
                color=$([ "$link_status" = "up" ] && echo "lime" || echo "red")
                description=$(ip link show "$interface" | grep -o "alias.*" | sed "s/alias //")
                [ -z "$description" ] && description="No description"
                printf "<span style=\"color:steelblue;\">%-14s</span> <span style=\"color:%s;\">%-12s</span> <span style=\"color:%s;\">%-12s</span> %s\n" "$interface" "$color" "$state" "$color" "$link_status" "$description"
            fi
        done

        echo "<h1></h1><h1><font color=\"#b57614\">Interface IP Addresses '"$hostname"'</font></h1><h3></h3>"
        printf "<span style=\"color:green;\">%-20s %-18s %s</span>\n" "Interface" "IPv4" "IPv6 Global"
        
        for interface in $(ip addr show | grep "^[0-9]*:" | cut -d: -f2 | cut -d@ -f1); do
            interface=$(echo "$interface" | xargs)
            ipv4=$(ip addr show "$interface" 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/[0-9]\+" | head -1)
            ipv6=$(ip addr show "$interface" 2>/dev/null | grep "inet6.*scope global" | grep -o "[0-9a-f:]\+/[0-9]\+" | head -1)
            if [ -n "$ipv4" ] || [ -n "$ipv6" ]; then
                [ -z "$ipv4" ] && ipv4="-"
                [ -z "$ipv6" ] && ipv6="-"
                printf "<span style=\"color:steelblue;\">%-20s</span> <span style=\"color:orange;\">%-18s</span> <span style=\"color:cyan;\">%s</span>\n" "$interface" "$ipv4" "$ipv6"
            fi
        done

        echo "<h1></h1><h1><font color=\"#b57614\">VLAN Configuration Table '"$hostname"'</font></h1><h3></h3>"
        echo "<pre style=\"font-family:monospace;\">"
        printf "<span style=\"color:green;\">%-20s %-12s %s</span>\n" "PORT" "PVID" "VLANs"
        sudo /usr/sbin/bridge vlan 2>/dev/null | \
          awk '\''BEGIN{cp=""}
               NR==1||NF==0{next}
               NF>=2{
                 if(cp!="") print cp "|" p "|" v
                 cp=$1; p=""; v=$2
                 if($3=="PVID") p=$2
                 next
               }
               NF==1{ v=v"," $1 }
               NF>2&&$3=="PVID"{ p=$2; v=v"," $2 }
               END{ if(cp!="") print cp "|" p "|" v }'\'' | \
          awk -F"|" '\''{
                if($1~/^vxlan/) { n="9999" } else { n="5000" }
                printf "%s|%s|%s|%s\n", n, $1, $2, $3
           }'\'' | sort -t"|" -k1,1n -k2,2V | \
          awk -F"|" '\''{
               port_colored = "<span style=\"color:steelblue;\">" $2 "</span>"
               if($3 != "") { pvid_colored = "PVID=<span style=\"color:lime;\">" $3 "</span>" }
               else { pvid_colored = "PVID=<span style=\"color:gray;\">N/A</span>" }
               vlan_colored = $4
               gsub(/([0-9]+)/, "<span style=\"color:tomato;\">&</span>", vlan_colored)
               port_pad = 20 - length($2)
               if($3 != "") { pvid_text_len = length("PVID=" $3) } else { pvid_text_len = length("PVID=N/A") }
               pvid_pad = 12 - pvid_text_len
               printf "%s%*s %s%*s VLANs=%s\n", port_colored, port_pad, "", pvid_colored, pvid_pad, "", vlan_colored
          }'\''
        echo "</pre>"

        echo "<h1></h1><h1><font color=\"#b57614\">ARP Table '"$hostname"'</font></h1><h3></h3>"
        ip neighbour | grep -E -v "fe80" | sort -t "." -k1,1n -k2,2n -k3,3n -k4,4n | sed -E "s/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/lladdr ([0-9a-f:]+)/lladdr <span style=\"color:tomato;\">\1<\/span>/"
        
        echo "<h1></h1><h1><font color=\"#b57614\">MAC Table '"$hostname"'</font></h1><h3></h3>"
        sudo /usr/sbin/bridge fdb 2>/dev/null | grep -E -v "00:00:00:00:00:00" | sort | sed -E "s/^([0-9a-f:]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/vlan ([0-9]+)/vlan <span style=\"color:red;\">\1<\/span>/; s/dst ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/dst <span style=\"color:lime;\">\1<\/span>/"
        
        echo "<h1></h1><h1><font color=\"#b57614\">BGP Status '"$hostname"'</font></h1><h3></h3>"
        sudo vtysh -c "show bgp vrf all sum" 2>/dev/null | sed -E "s/(VRF\s+)([a-zA-Z0-9_-]+)/\1<span style=\"color:tomato;\">\2<\/span>/g; s/Total number of neighbors ([0-9]+)/Total number of neighbors <span style=\"color:steelblue;\">\1<\/span>/g; s/(\S+)\s+(\S+)\s+Summary/<span style=\"color:lime;\">\1 \2<\/span> Summary/g; s/\b(Active|Idle)\b/<span style=\"color:red;\">\1<\/span>/g"
        
        echo "===HTML_OUTPUT_END==="
        
        # =====================================================================
        # SECTION 2: BGP Data (for analysis)
        # =====================================================================
        echo "===BGP_DATA_START==="
        sudo vtysh -c "show bgp vrf all sum" 2>/dev/null
        echo "===BGP_DATA_END==="
        
        # =====================================================================
        # SECTION 3: Carrier Transitions (for flap analysis)
        # =====================================================================
        echo "===CARRIER_DATA_START==="
        all_interfaces=$(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}")
        for interface in $all_interfaces; do
            if [ -e "/sys/class/net/$interface" ]; then
                carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
                echo "$interface:$carrier_count"
            fi
        done
        echo "===CARRIER_DATA_END==="
        
        # =====================================================================
        # SECTION 4: Optical Transceiver Data
        # =====================================================================
        echo "===OPTICAL_DATA_START==="
        all_interfaces=$(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}")
        for interface in $all_interfaces; do
            if [ -e "/sys/class/net/$interface" ]; then
                state=$(cat /sys/class/net/$interface/operstate 2>/dev/null)
                if [ "$state" = "up" ]; then
                    echo "--- Interface: $interface"
                    if sudo ethtool -m "$interface" >/dev/null 2>&1; then
                        sudo ethtool -m "$interface" 2>/dev/null
                    else
                        echo "No transceiver data"
                    fi
                fi
            fi
        done
        echo "===OPTICAL_DATA_END==="
        
        # =====================================================================
        # SECTION 5: BER/Interface Statistics
        # =====================================================================
        echo "===BER_DATA_START==="
        cat /proc/net/dev 2>/dev/null
        echo "===BER_DATA_END==="
        
        # =====================================================================
        # SECTION 6: L1-Show (if available)
        # =====================================================================
        echo "===L1_DATA_START==="
        if command -v l1-show >/dev/null 2>&1; then
            sudo l1-show all -p 2>/dev/null || echo "l1-show failed"
        else
            echo "l1-show not available"
        fi
        echo "===L1_DATA_END==="
        
        # =====================================================================
        # SECTION 7: Hardware Health
        # =====================================================================
        echo "===HARDWARE_DATA_START==="
        echo "HARDWARE_HEALTH:"
        sensors 2>/dev/null || echo "No sensors available"
        echo "HW_MGMT_THERMAL:"
        if [ -r "/var/run/hw-management/thermal/asic" ]; then
            asic_raw=$(cat /var/run/hw-management/thermal/asic 2>/dev/null || echo "")
            if [ -n "$asic_raw" ]; then
                awk "BEGIN{printf \"HW_MGMT_ASIC: %.1f\n\", $asic_raw/1000}"
            fi
        fi
        if [ -r "/var/run/hw-management/thermal/cpu_pack" ]; then
            cpu_raw=$(cat /var/run/hw-management/thermal/cpu_pack 2>/dev/null || echo "")
            if [ -n "$cpu_raw" ]; then
                awk "BEGIN{printf \"HW_MGMT_CPU: %.1f\n\", $cpu_raw/1000}"
            fi
        fi
        echo "MEMORY_INFO:"
        free -h 2>/dev/null || echo "No memory info"
        echo "CPU_INFO:"
        cat /proc/loadavg 2>/dev/null || echo "No CPU info"
        echo "===HARDWARE_DATA_END==="
        
        # =====================================================================
        # SECTION 8: System Logs
        # =====================================================================
        echo "===LOG_DATA_START==="
        
        echo "FRR_ROUTING_LOGS:"
        if systemctl is-active --quiet frr 2>/dev/null; then
            sudo journalctl -u frr --since="2 hours ago" --no-pager --lines=100 2>/dev/null | grep -E "(ERROR|WARN|CRIT|FAIL|DOWN|BGP|neighbor|peer)" || echo "No recent FRR issues"
        else
            echo "FRR not available"
        fi
        
        echo "SWITCHD_LOGS:"
        if systemctl is-active --quiet switchd 2>/dev/null; then
            sudo journalctl -u switchd --since="2 hours ago" --no-pager --lines=50 2>/dev/null | grep -E "(ERROR|WARN|CRIT|FAIL|port|link)" || echo "No recent switchd issues"
        else
            echo "Switchd not available"
        fi
        
        echo "JOURNALCTL_PRIORITY_LOGS:"
        sudo journalctl --since="3 hours ago" --priority=0..3 --no-pager --lines=50 2>/dev/null | grep -E "(CRIT|ALERT|EMERG|ERROR|fail|crash)" || echo "No high priority logs"
        
        echo "DMESG_HARDWARE_LOGS:"
        sudo dmesg --since="3 hours ago" --level=crit,alert,emerg 2>/dev/null | tail -30 || echo "No critical hardware logs"
        
        echo "===LOG_DATA_END==="
        
    ' > "monitor-results/${hostname}_raw_data.txt" 2>/dev/null
    
    # =========================================================================
    # Parse raw data into separate files
    # =========================================================================
    if [ -f "monitor-results/${hostname}_raw_data.txt" ]; then
        # Extract HTML output
        sed -n '/===HTML_OUTPUT_START===/,/===HTML_OUTPUT_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===HTML_OUTPUT" >> "monitor-results/${hostname}.html"
        
        # Extract BGP data
        sed -n '/===BGP_DATA_START===/,/===BGP_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===BGP_DATA" > "monitor-results/bgp-data/${hostname}_bgp.txt"
        
        # Extract Carrier data
        echo "=== CARRIER TRANSITIONS ===" > "monitor-results/flap-data/${hostname}_carrier_transitions.txt"
        sed -n '/===CARRIER_DATA_START===/,/===CARRIER_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===CARRIER_DATA" >> "monitor-results/flap-data/${hostname}_carrier_transitions.txt"
        
        # Extract Optical data
        echo "=== OPTICAL DIAGNOSTICS ===" > "monitor-results/optical-data/${hostname}_optical.txt"
        sed -n '/===OPTICAL_DATA_START===/,/===OPTICAL_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===OPTICAL_DATA" >> "monitor-results/optical-data/${hostname}_optical.txt"
        
        # Extract BER data
        sed -n '/===BER_DATA_START===/,/===BER_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===BER_DATA" > "monitor-results/ber-data/${hostname}_interface_errors.txt"
        
        # Extract L1 data
        sed -n '/===L1_DATA_START===/,/===L1_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===L1_DATA" > "monitor-results/ber-data/${hostname}_l1_show.txt"
        
        # Extract Hardware data
        sed -n '/===HARDWARE_DATA_START===/,/===HARDWARE_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===HARDWARE_DATA" > "monitor-results/hardware-data/${hostname}_hardware.txt"
        
        # Extract Log data
        sed -n '/===LOG_DATA_START===/,/===LOG_DATA_END===/p' "monitor-results/${hostname}_raw_data.txt" | \
            grep -v "===LOG_DATA" > "monitor-results/log-data/${hostname}_logs.txt"
        
        # Cleanup raw file
        rm -f "monitor-results/${hostname}_raw_data.txt"
    fi
    
    # Add config section to HTML
    cat >> monitor-results/${hostname}.html << EOF

<h1></h1><h1><font color="#b57614">Device Configuration - ${hostname}</font></h1><h3></h3>
EOF

    if [ -f "/var/www/html/configs/${hostname}.txt" ]; then
        echo "<h2><font color='steelblue'>NV Set Commands</font></h2>" >> monitor-results/${hostname}.html
        echo "<div class='config-content' id='config-content'>" >> monitor-results/${hostname}.html
        cat "/var/www/html/configs/${hostname}.txt" | sed '
            s/</\&lt;/g; s/>/\&gt;/g;
            s/^#.*/<span class="comment">&<\/span>/;
        ' >> monitor-results/${hostname}.html
        echo "</div>" >> monitor-results/${hostname}.html
    else
        echo "<p><span style='color: orange;'>⚠️  Configuration not available for ${hostname}</span></p>" >> monitor-results/${hostname}.html
    fi
    
    # Close HTML
    cat >> monitor-results/${hostname}.html << EOF
    </pre>
    </h3>
    <span style="color:tomato;">Created on $DATE</span>
</body>
</html>
EOF

    local device_end=$(date +%s)
    local duration=$((device_end - device_start))
    echo "✅ [$hostname] Completed in ${duration}s"
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

# ============================================================================
# PARALLEL EXECUTION WITH LIMIT
# ============================================================================
echo "🚀 Starting optimized monitoring (max $MAX_PARALLEL parallel)..."
echo "📊 Total devices: ${#devices[@]}"

job_count=0
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    
    # Start job in background
    process_device "$device" "$user" "$hostname" &
    ((job_count++))
    
    # Wait if we hit the parallel limit
    if [ $job_count -ge $MAX_PARALLEL ]; then
        wait -n 2>/dev/null || wait
        ((job_count--))
    fi
done

# Wait for all remaining jobs
wait

echo ""
echo -e "\e[1;34m✅ Data collection completed!\e[0m"

# ============================================================================
# PARALLEL ANALYSIS PHASE
# ============================================================================
echo -e "\n🔬 \e[1;34mStarting PARALLEL Analysis Phase...\e[0m"
analysis_start=$(date +%s)

# Run all analyses in parallel
python3 process_bgp_data.py &
pid_bgp=$!

python3 process_flap_data.py &
pid_flap=$!

python3 process_optical_data.py &
pid_optical=$!

python3 process_ber_data.py &
pid_ber=$!

python3 process_hardware_data.py &
pid_hardware=$!

python3 process_log_data.py &
pid_log=$!

# Wait for all analyses
wait $pid_bgp && echo "✅ BGP analysis done" || echo "⚠️ BGP analysis failed"
wait $pid_flap && echo "✅ Flap analysis done" || echo "⚠️ Flap analysis failed"
wait $pid_optical && echo "✅ Optical analysis done" || echo "⚠️ Optical analysis failed"
wait $pid_ber && echo "✅ BER analysis done" || echo "⚠️ BER analysis failed"
wait $pid_hardware && echo "✅ Hardware analysis done" || echo "⚠️ Hardware analysis failed"
wait $pid_log && echo "✅ Log analysis done" || echo "⚠️ Log analysis failed"

analysis_end=$(date +%s)
analysis_duration=$((analysis_end - analysis_start))
echo "📊 Total analysis time: ${analysis_duration}s"

# ============================================================================
# COPY RESULTS
# ============================================================================
sudo cp -r monitor-results/ /var/www/html/
sudo chmod 644 /var/www/html/monitor-results/* 2>/dev/null

rm -f "$unreachable_hosts_file"
rm -f "$active_jobs_file"

# Calculate execution time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "🎉 ==============================================="
echo "⚡ OPTIMIZED monitoring completed!"
echo "⏱️  Total execution time: ${MINUTES}m ${SECONDS}s"
echo "📊 Devices processed: ${#devices[@]}"
echo "🔧 Max parallel: $MAX_PARALLEL"
echo "🔬 Analysis time: ${analysis_duration}s"
echo "🌐 Results available at web interface"
echo "==============================================="
exit 0
