#!/bin/bash
# Monitor Script with Linux Native Commands (No nv show)
#
# Copyright (c) 2024 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

# Start timing
START_TIME=$(date +%s)
echo "🚀 Starting monitoring at $(date) with Linux native commands"

DATE=$(date '+%Y-%m-%d %H-%M-%S')
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

    # Interface overview and status collection
    start_section "Interface Overview"
    local start_time=$(date +%s)
    
    # NATIVE LINUX: Single SSH session with Linux native commands instead of nv show
    ssh $SSH_OPTS -q "$user@$device" '

        
        echo "<h1></h1><h1><font color=\"#b57614\">Port Status '"$hostname"'</font></h1><h3></h3>"
        
        # Port status using ip link show with description (replaces nv show interface status + description)
        printf "<span style=\"color:green;\">%-14s %-12s %-12s %s</span>\n" "Interface" "State" "Link" "Description"
        
        # Get interfaces and sort them numerically by port number (no UP/DOWN grouping)
        
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
        
        # IP address information - show only interfaces with IPv4 or IPv6 global addresses
        printf "<span style=\"color:green;\">%-20s %-18s %s</span>\n" "Interface" "IPv4" "IPv6 Global"
        
        # Get interfaces with IP addresses (basic shell approach)
        temp_ip_file="/tmp/ip_addresses_$$"
        
        # Extract interface names with IPv4 addresses - simple approach
        for interface in $(ip addr show | grep "^[0-9]*:" | cut -d: -f2 | cut -d@ -f1); do
            interface=$(echo "$interface" | xargs)  # Remove spaces
            ipv4=$(ip addr show "$interface" 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | grep -o "[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/[0-9]\+" | head -1)
            ipv6=$(ip addr show "$interface" 2>/dev/null | grep "inet6.*scope global" | grep -o "[0-9a-f:]\+/[0-9]\+" | head -1)
            
            if [ -n "$ipv4" ] || [ -n "$ipv6" ]; then
                [ -z "$ipv4" ] && ipv4="-"
                [ -z "$ipv6" ] && ipv6="-"
                printf "<span style=\"color:steelblue;\">%-20s</span> <span style=\"color:orange;\">%-18s</span> <span style=\"color:cyan;\">%s</span>\n" "$interface" "$ipv4" "$ipv6"
            fi
        done





        echo "<h1></h1><h1><font color=\"#b57614\">VLAN Configuration '"$hostname"'</font></h1><h3></h3>"
        
        # VLAN mapping using bridge vlan (shows actual bridge configuration)
        echo ""  # Skip the header since bridge vlan provides its own
        
        # Use bridge vlan command (with correct full path)
        if /usr/sbin/bridge vlan >/dev/null 2>&1; then
            /usr/sbin/bridge vlan | sed -E "
                # Color header words in gray (exact match at line start)
                s/^(port)([[:space:]]+)/\<span style=\"color:gray;\"\>\1\<\/span\>\2/
                s/^([[:space:]]*)(vlan-id)/\1\<span style=\"color:gray;\"\>\2\<\/span\>/
                # Color port names in blue (swp, hgx_bond, br_default, peerlink, etc.)
                s/^([a-zA-Z][a-zA-Z0-9_]*[0-9]*)/\<span style=\"color:steelblue;\"\>\1\<\/span\>/
                # Color VLAN numbers in orange (only numbers that follow whitespace and are followed by space/comma/PVID)
                s/([[:space:]])([0-9]{1,4})([[:space:]]+|,|$)/\1\<span style=\"color:tomato;\"\>\2\<\/span\>\3/g
                s/([[:space:]])([0-9]{1,4})(PVID)/\1\<span style=\"color:tomato;\"\>\2\<\/span\>\3/g
                # Color PVID in green
                s/PVID/\<span style=\"color:lime;\"\>PVID\<\/span\>/g
                # Color Egress/tagged keywords
                s/(Egress|Untagged|tagged)/\<span style=\"color:yellow;\"\>\1\<\/span\>/g
            "
        elif bridge vlan >/dev/null 2>&1; then
            bridge vlan | sed -E "
                # Color header words in gray (exact match at line start)
                s/^(port)([[:space:]]+)/\<span style=\"color:gray;\"\>\1\<\/span\>\2/
                s/^([[:space:]]*)(vlan-id)/\1\<span style=\"color:gray;\"\>\2\<\/span\>/
                # Color port names in blue (swp, hgx_bond, br_default, peerlink, etc.)
                s/^([a-zA-Z][a-zA-Z0-9_]*[0-9]*)/\<span style=\"color:steelblue;\"\>\1\<\/span\>/
                # Color VLAN numbers in orange (only numbers that follow whitespace and are followed by space/comma/PVID)
                s/([[:space:]])([0-9]{1,4})([[:space:]]+|,|$)/\1\<span style=\"color:tomato;\"\>\2\<\/span\>\3/g
                s/([[:space:]])([0-9]{1,4})(PVID)/\1\<span style=\"color:tomato;\"\>\2\<\/span\>\3/g
                # Color PVID in green
                s/PVID/\<span style=\"color:lime;\"\>PVID\<\/span\>/g
                # Color Egress/tagged keywords
                s/(Egress|Untagged|tagged)/\<span style=\"color:yellow;\"\>\1\<\/span\>/g
            "
        else
            echo "Bridge command not found - checking PATH: $PATH"
            echo "Trying alternative paths..."
            which bridge 2>/dev/null || echo "Bridge not in PATH"
            ls -la /sbin/bridge 2>/dev/null || echo "Bridge not in /sbin/"
            ls -la /usr/sbin/bridge 2>/dev/null || echo "Bridge not in /usr/sbin/"
        fi

        echo "<h1></h1><h1><font color=\"#b57614\">VLAN Configuration Table '"$hostname"'</font></h1><h3></h3>"
        echo "<pre style=\"font-family:monospace;\">"
        printf "%-20s %-12s %s\n" "PORT" "PVID" "VLANs"
        printf "%-20s %-12s %s\n" "----" "----" "-----"
        /usr/sbin/bridge vlan | \
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
                if($1~/^vxlan/) {
                    n="9999"
                } else {
                    n="5000"
                }
                printf "%s|%s|%s|%s\n", n, $1, $2, $3
           }'\'' | \
          awk '{ match($1, /([0-9]+)$/, a); print a[1], $0 }' | sort -n | cut -d' ' -f2- | \
          awk -F"|" '\''{
               # Apply colors but use fixed-width formatting
               port_name = $2
               pvid_val = $3
               vlan_list = $4
               
               # Color the port name
               port_colored = "<span style=\"color:steelblue;\">" port_name "</span>"
               
               # Color PVID
               if(pvid_val != "") {
                   pvid_colored = "PVID=<span style=\"color:lime;\">" pvid_val "</span>"
               } else {
                   pvid_colored = "PVID=<span style=\"color:gray;\">N/A</span>"
               }
               
               # Color VLAN numbers in the list
               vlan_colored = vlan_list
               gsub(/([0-9]+)/, "<span style=\"color:tomato;\">&</span>", vlan_colored)
               
                               # Fixed width output - pad with spaces based on actual text length
                port_pad = 20 - length(port_name)
                
                # Calculate PVID text length correctly
                if(pvid_val != "") {
                    pvid_text_len = length("PVID=" pvid_val)
                } else {
                    pvid_text_len = length("PVID=N/A")
                }
                pvid_pad = 12 - pvid_text_len
                
                printf "%s%*s %s%*s VLANs=%s\n", port_colored, port_pad, "", pvid_colored, pvid_pad, "", vlan_colored
          }'\''
        echo "</pre>"

        echo "<h1></h1><h1><font color=\"#b57614\">ARP Table '"$hostname"'</font></h1><h3></h3>"
        ip neighbour | grep -E -v "fe80" | sort -t "." -k1,1n -k2,2n -k3,3n -k4,4n | sed -E "s/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/lladdr ([0-9a-f:]+)/lladdr <span style=\"color:tomato;\">\1<\/span>/"
        
        echo "<h1></h1><h1><font color=\"#b57614\">MAC Table '"$hostname"'</font></h1><h3></h3>"
        sudo bridge fdb | grep -E -v "00:00:00:00:00:00" | sort | sed -E "s/^([0-9a-f:]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/vlan ([0-9]+)/vlan <span style=\"color:red;\">\1<\/span>/; s/dst ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/dst <span style=\"color:lime;\">\1<\/span>/"
        
        echo "<h1></h1><h1><font color=\"#b57614\">BGP Status '"$hostname"'</font></h1><h3></h3>"
        sudo vtysh -c "show bgp vrf all sum" 2>/dev/null | sed -E "s/(VRF\s+)([a-zA-Z0-9_-]+)/\1<span style=\"color:tomato;\">\2<\/span>/g; s/Total number of neighbors ([0-9]+)/Total number of neighbors <span style=\"color:steelblue;\">\1<\/span>/g; s/(\S+)\s+(\S+)\s+Summary/<span style=\"color:lime;\">\1 \2<\/span> Summary/g; s/\b(Active|Idle)\b/<span style=\"color:red;\">\1<\/span>/g"
    ' >> monitor-results/${hostname}.html
    
    end_section "Interface Overview" "$start_time"
    
    # BGP data collection
    start_section "BGP Data Collection"
    local bgp_start=$(date +%s)
    ssh $SSH_OPTS -q "$user@$device" "sudo vtysh -c \"show bgp vrf all sum\"" 2>/dev/null > "monitor-results/bgp-data/${hostname}_bgp.txt"
    end_section "BGP Data Collection" "$bgp_start"
    
    # Interface detailed data collection (longest operation)
    start_section "Interface Data Collection"
    local interface_start=$(date +%s)
    
    # NATIVE LINUX: Single SSH session for all interface data collection
    timeout 600 ssh $SSH_OPTS -q "$user@$device" '
        echo "=== NATIVE LINUX INTERFACE DATA COLLECTION ==="
        
        # Get interface list using ip link (replaces nv show interface)
        all_interfaces=$(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}")
        
        # Collect ALL interface data in single loop using native Linux commands
        for interface in $all_interfaces; do
            if [ ! -e "/sys/class/net/$interface" ]; then continue; fi
            
            echo "=== INTERFACE: $interface ==="
            
            # Carrier transitions data using /sys (replaces nv show interface counters)
            echo "CARRIER_TRANSITIONS:"
            carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
            echo "$interface:$carrier_count"
            
            # Optical transceiver data using ethtool (replaces nv show interface transceiver)
            echo "OPTICAL_TRANSCEIVER:"
            if ethtool -m "$interface" >/dev/null 2>&1; then
                ethtool -m "$interface" 2>/dev/null || echo "No transceiver data available"
            else
                echo "No transceiver data available"
            fi
            
            # BER detailed counters using /sys/class/net (replaces nv show interface counters)
            echo "BER_COUNTERS:"
            if [ -d "/sys/class/net/$interface/statistics" ]; then
                echo "rx_packets: $(cat /sys/class/net/$interface/statistics/rx_packets 2>/dev/null || echo 0)"
                echo "tx_packets: $(cat /sys/class/net/$interface/statistics/tx_packets 2>/dev/null || echo 0)"
                echo "rx_errors: $(cat /sys/class/net/$interface/statistics/rx_errors 2>/dev/null || echo 0)"
                echo "tx_errors: $(cat /sys/class/net/$interface/statistics/tx_errors 2>/dev/null || echo 0)"
                echo "rx_dropped: $(cat /sys/class/net/$interface/statistics/rx_dropped 2>/dev/null || echo 0)"
                echo "tx_dropped: $(cat /sys/class/net/$interface/statistics/tx_dropped 2>/dev/null || echo 0)"
            else
                echo "No detailed counters available"
            fi
            
            echo "=== END_INTERFACE: $interface ==="
        done
    ' > "monitor-results/${hostname}_combined_interface_data.txt" 2>/dev/null
    
    end_section "Interface Data Collection" "$interface_start"
    
    # Carrier transitions collection  
    start_section "Carrier Transitions"
    local carrier_start=$(date +%s)
    
    # NATIVE LINUX: carrier transitions collection using /sys
    echo "=== CARRIER TRANSITIONS ===" > "monitor-results/flap-data/${hostname}_carrier_transitions.txt"
    
    # Single SSH session for ALL carrier transitions data using native Linux
    timeout 300 ssh $SSH_OPTS -q "$user@$device" '
        # Get all swp interfaces using ip link
        all_interfaces=$(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}")
        
        # Collect carrier transitions for all interfaces using /sys
        for interface in $all_interfaces; do
            if [ -e "/sys/class/net/$interface" ]; then
                carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
                if [ -n "$carrier_count" ] && [ "$carrier_count" != "" ]; then
                    echo "$interface:$carrier_count"
                fi
            fi
        done
    ' >> "monitor-results/flap-data/${hostname}_carrier_transitions.txt" 2>/dev/null
    
    end_section "Carrier Transitions" "$carrier_start"
    
    # Data processing for optical and BER analysis
    start_section "Data Processing"
    local processing_start=$(date +%s)
    
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
    
    end_section "Data Processing" "$processing_start"
    
    # BER interface statistics collection
    start_section "BER Statistics"
    local ber_start=$(date +%s)
    timeout 120 ssh $SSH_OPTS -q "$user@$device" '
        cat /proc/net/dev 2>/dev/null
    ' > "monitor-results/ber-data/${hostname}_interface_errors.txt" 2>/dev/null
    end_section "BER Statistics" "$ber_start"
    
    # Hardware health data collection  
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
    
    # Enhanced log data collection  
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
            sudo journalctl --since="2 hours ago" --grep="FAIL|ERROR|INVALID|DENIED|ATTACK|authentication|unauthorized" --no-pager --lines=50 2>/dev/null | grep -v -E "(journalctl|monitor\.sh|monitor2\.sh|--since|--grep|swp\|bond\|vlan\|carrier\|link|vtysh|sudo.*authentication.*grantor=pam_permit|USER_AUTH.*res=success)" || echo "No recent auth issues"
        elif [ -f "/var/log/auth.log" ]; then
            # Fallback to file-based but with date filtering (exclude monitoring activities)
            sudo grep "$(date '\''+%b %d'\'')" /var/log/auth.log 2>/dev/null | tail -30 | grep -E "(FAIL|ERROR|INVALID|DENIED|ATTACK|authentication|unauthorized)" | grep -v -E "(journalctl|monitor\.sh|monitor2\.sh|--since|swp\|bond\|vlan\|carrier\|link|vtysh|sudo.*authentication.*grantor=pam_permit|USER_AUTH.*res=success)" || echo "No recent auth issues"
        else
            echo "Auth log not found"
        fi
        
        # System critical logs from syslog (TIME-BASED: Last 2 hours only) - Only show if there are entries
        CRITICAL_LOGS=""
        if systemctl is-active --quiet systemd-journald 2>/dev/null; then
            CRITICAL_LOGS=$(sudo journalctl --since="2 hours ago" --priority=0..3 --grep="ERROR|CRIT|ALERT|EMERG|FAIL|kernel|oom|segfault" --no-pager --lines=50 2>/dev/null)
        elif [ -f "/var/log/syslog" ]; then
            CRITICAL_LOGS=$(sudo grep "$(date '\''+%b %d'\'')" /var/log/syslog 2>/dev/null | tail -50 | grep -E "(ERROR|CRIT|ALERT|EMERG|FAIL|kernel|oom|segfault)")
        fi
        
        if [ -n "$CRITICAL_LOGS" ]; then
            echo "SYSTEM_CRITICAL_LOGS:"
            echo "$CRITICAL_LOGS"
        fi
        
        echo "JOURNALCTL_PRIORITY_LOGS:"
        # High priority journalctl logs (HYBRID: TIME + SEVERITY - System Wide)
        sudo journalctl --since="3 hours ago" --priority=0..3 --no-pager --lines=75 2>/dev/null | grep -E "(CRIT|ALERT|EMERG|ERROR|fail|crash|panic)" || echo "No high priority journal logs"
        
        echo "DMESG_HARDWARE_LOGS:"
        # Hardware and kernel critical messages (HYBRID: TIME + SEVERITY - Hardware Critical)
        sudo dmesg --since="3 hours ago" --level=crit,alert,emerg 2>/dev/null | tail -40 || echo "No critical hardware logs"
        
        echo "NETWORK_INTERFACE_LOGS:"
        # Network interface state changes (HYBRID: TIME + SEVERITY - Network Events)
        # Filter out monitoring scriptimage.pngs own journalctl commands
        sudo journalctl --since="3 hours ago" --grep="swp|bond|vlan|carrier|link.*up|link.*down|port.*up|port.*down" --no-pager --lines=40 2>/dev/null | grep -v -E "(journalctl|monitor\.sh|monitor2\.sh|sudo.*journalctl)" || echo "No interface state changes"
        
    ' > "monitor-results/log-data/${hostname}_logs.txt" 2>/dev/null
    
    end_section "Log Analysis" "$log_start"
    
    # Device configuration section
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
    
    # Display timing summary
    echo ""
    echo "📊 [$hostname] Section Timing Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local total_time=0
    for i in "${!section_names[@]}"; do
        local section="${section_names[i]}"
        local time="${section_times[i]}"
        total_time=$((total_time + time))
        printf "%-25s : %3ds\n" "$section" "$time"
    done
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "%-25s : %3ds\n" "TOTAL DEVICE TIME" "$total_time"
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

# Start optimized monitoring
echo "🚀 Starting optimized monitoring with Linux native commands..."

# Process all devices in parallel
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    process_device "$device" "$user" "$hostname" &
done

wait

echo ""
echo -e "\e[1;34mNative Linux monitoring completed...\e[0m"

# Run analyses with timing
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

# Display analysis timing summary
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

# Calculate execution time
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

echo ""
echo "🎉 ==============================================="
echo "⚡ Native Linux monitoring completed successfully!"
echo "⏱️ Total execution time: ${MINUTES}m ${SECONDS}s"
echo "📊 All device sections completed with timing"
echo "🔬 All analysis phases completed with timing"  
echo "🌐 Results available at web interface"
echo "🐧 Used Linux native commands instead of nv show"
echo "=================================================="
exit 0