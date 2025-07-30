#!/bin/bash
# Fast Monitor Script - Simple optimization without SSH multiplexing
# Combines multiple commands into fewer SSH sessions

DATE=$(date '+%Y-%m-%d %H-%M')
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
source "$SCRIPT_DIR/devices.sh"

mkdir -p "$SCRIPT_DIR/monitor-results"
mkdir -p "$SCRIPT_DIR/monitor-results/flap-data"
mkdir -p "$SCRIPT_DIR/monitor-results/bgp-data"

unreachable_hosts_file=$(mktemp)

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

execute_commands_fast() {
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
</head>
<body>
    <h1><font color="#b57614">Monitor Results - ${hostname}</font></h1>
    <h3 class='interface-info'>
    <pre>
    <span style="color:tomato;">Created on $DATE</span>

EOF

    # FAST: Combine all network commands in one SSH call
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -T "$user@$device" << 'EOSSH' >> monitor-results/${hostname}.html

echo "<h1></h1><h1><font color=\"#b57614\">Interface Overview HOSTNAME</font></h1><h3></h3>"
nv show interface | sed -E '1 s/^port/<span style="color:green;">Interface<\/span>/; 1,2! s/^(\S+)/<span style="color:steelblue;">\1<\/span>/;  s/ up /<span style="color:lime;"> up <\/span>/g; s/ down /<span style="color:red;"> down <\/span>/g'

echo "<h1></h1><h1><font color=\"#b57614\">Port Status HOSTNAME</font></h1><h3></h3>"
nv show interface status | sed -E '1 s/^port/<span style="color:green;">Interface<\/span>/; 1,2! s/^(\S+)/<span style="color:steelblue;">\1<\/span>/;  s/ up /<span style="color:lime;"> up <\/span>/g; s/ down /<span style="color:red;"> down <\/span>/g'

echo "<h1></h1><h1><font color=\"#b57614\">Port Description HOSTNAME</font></h1><h3></h3>"
nv show interface description | sed -E '1 s/^port/<span style="color:green;">Interface<\/span>/; 1,2! s/^(\S+)/<span style="color:steelblue;">\1<\/span>/;  s/ up /<span style="color:lime;"> up <\/span>/g; s/ down /<span style="color:red;"> down <\/span>/g'

echo "<h1></h1><h1><font color=\"#b57614\">Port VLAN Mapping HOSTNAME</font></h1><h3></h3>"
nv show bridge port-vlan | cut -c11- | sed -E '1 s/^    port/<span style="color:green;">    port<\/span>/; 2! s/^(\s{0,4})([a-zA-Z_]\S*)/\1<span style="color:steelblue;">\2<\/span>/; s/\btagged\b/<span style="color:tomato;">tagged<\/span>/g'

echo "<h1></h1><h1><font color=\"#b57614\">ARP Table HOSTNAME</font></h1><h3></h3>"
ip neighbour | grep -E -v 'fe80' | sort -t '.' -k1,1n -k2,2n -k3,3n -k4,4n | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/<span style="color:tomato;">\1<\/span>/; s/dev ([^ ]+)/dev <span style="color:steelblue;">\1<\/span>/; s/lladdr ([0-9a-f:]+)/lladdr <span style="color:tomato;">\1<\/span>/'

echo "<h1></h1><h1><font color=\"#b57614\">MAC Table HOSTNAME</font></h1><h3></h3>"
sudo bridge fdb | grep -E -v '00:00:00:00:00:00' | sort | sed -E 's/^([0-9a-f:]+)/<span style="color:tomato;">\1<\/span>/; s/dev ([^ ]+)/dev <span style="color:steelblue;">\1<\/span>/; s/vlan ([0-9]+)/vlan <span style="color:red;">\1<\/span>/; s/dst ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/dst <span style="color:lime;">\1<\/span>/'

echo "<h1></h1><h1><font color=\"#b57614\">BGP Status HOSTNAME</font></h1><h3></h3>"
sudo vtysh -c "show bgp vrf all sum" 2>/dev/null | sed -E 's/(VRF\s+)([a-zA-Z0-9_-]+)/\1<span style="color:tomato;">\2<\/span>/g; s/Total number of neighbors ([0-9]+)/Total number of neighbors <span style="color:steelblue;">\1<\/span>/g; s/(\S+)\s+(\S+)\s+Summary/<span style="color:lime;">\1 \2<\/span> Summary/g; s/\b(Active|Idle)\b/<span style="color:red;">\1<\/span>/g'

EOSSH

    # Replace HOSTNAME placeholder
    sed -i "s/HOSTNAME/${hostname}/g" monitor-results/${hostname}.html

    # BGP data collection (for analysis)
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -T "$user@$device" "sudo vtysh -c \"show bgp vrf all sum\"" 2>/dev/null > "monitor-results/bgp-data/${hostname}_bgp.txt"

    # Carrier transition collection
    ssh -o StrictHostKeyChecking=no -o BatchMode=yes -T "$user@$device" << 'EOSSH' > "monitor-results/flap-data/${hostname}_carrier_transitions.txt" 2>/dev/null

echo "=== CARRIER TRANSITIONS ==="
all_interfaces=$(nv show interface 2>/dev/null | grep -E "swp[0-9]+(s[0-9]+)?" | awk '{print $1}' || ls /sys/class/net/swp* 2>/dev/null | xargs -n1 basename)
for interface in $all_interfaces; do
    if [ ! -e "/sys/class/net/$interface" ]; then continue; fi
    carrier_count=$(nv show interface $interface counters 2>/dev/null | grep "carrier-transitions" | awk '{print $2}')
    if [ -z "$carrier_count" ] || [ "$carrier_count" = "" ]; then
        carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
    fi
    if [[ "$carrier_count" =~ ^[0-9]+$ ]]; then
        echo "$interface:$carrier_count"
    fi
done

EOSSH

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
        execute_commands_fast "$device" "$user" "$hostname"
    fi
}

echo "🚀 Starting fast monitoring..."

# Process all devices in parallel
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    process_device "$device" "$user" "$hostname" &
done

wait

echo ""
echo -e "\e[1;34mFast monitoring completed...\e[0m"

# Run analyses
echo -e "\n\e[0;34mRunning BGP Analysis...\e[0m"
cd "$(dirname "$0")"
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

sudo cp -r monitor-results/ /var/www/html/
sudo chmod 644 /var/www/html/monitor-results/*
rm -f "$unreachable_hosts_file"

echo ""
echo "⚡ Fast monitoring completed!"
echo "🌐 Results available at web interface"
exit 0