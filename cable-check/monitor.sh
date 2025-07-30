#!/bin/bash
DATE=$(date '+%Y-%m-%d %H-%M')
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
source "$SCRIPT_DIR/devices.sh"

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

execute_commands() {
    local device=$1
    local user=$2
    local hostname=$3
    cat <<EOF > monitor-results/${hostname}.html
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">
<head>
    <link rel="shortcut icon" href="/png/favicon.ico">
    <title>..::${hostname}::..</title>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>.interface-info {color: green;margin-top: 20px;}</style>
</head>
<body>
    <h1></h1>
    <h1><font color="#b57614">Port Monitoring ${hostname}</font></h1>
    <h3></h3>
EOF
#    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "bwm-ng -o html" >> monitor-results/${hostname}.html
#    sed -i 's/"bwm-ng-header">bwm-ng bwm-ng v0.6.3 (refresh 5s); input: \/proc\/net\/dev/ /g' monitor-results/${hostname}.html
#    echo "" >> monitor-results/${hostname}.html

    echo "<h3 class='interface-info'>" >> monitor-results/${hostname}.html
    echo "<pre>" >> monitor-results/${hostname}.html
    echo -e "<span style=\"color:tomato;\">Created on $DATE</span>\n" >> monitor-results/${hostname}.html

    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "nv show interface | sed -E '1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g'" >> monitor-results/${hostname}.html

    echo "<h1></h1><h1><font color="#b57614">Port Status ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "nv show interface status | sed -E '1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g'" >> monitor-results/${hostname}.html

    echo "<h1></h1><h1><font color="#b57614">Port Description ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "nv show interface description | sed -E '1 s/^port/<span style=\"color:green;\">Interface<\/span>/; 1,2! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/;  s/ up /<span style=\"color:lime;\"> up <\/span>/g; s/ down /<span style=\"color:red;\"> down <\/span>/g'" >> monitor-results/${hostname}.html

    echo "<h1></h1><h1><font color="#b57614">Port VLAN Mapping ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "nv show bridge port-vlan | cut -c11- | sed -E '1 s/^    port/<span style=\"color:green;\">    port<\/span>/; 2! s/^(\s{0,4})([a-zA-Z_]\S*)/\1<span style=\"color:steelblue;\">\2<\/span>/; s/\btagged\b/<span style=\"color:tomato;\">tagged<\/span>/g'" >> monitor-results/${hostname}.html

    echo "<h1></h1><h1><font color="#b57614">ARP Table ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "ip neighbour | grep -E -v 'fe80' | sort -t '.' -k1,1n -k2,2n -k3,3n -k4,4n | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/lladdr ([0-9a-f:]+)/lladdr <span style=\"color:tomato;\">\1<\/span>/'" >> monitor-results/${hostname}.html

    echo "<h1></h1><h1><font color="#b57614">MAC Table ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "sudo bridge fdb | grep -E -v '00:00:00:00:00:00' | sort | sed -E 's/^([0-9a-f:]+)/<span style=\"color:tomato;\">\1<\/span>/; s/dev ([^ ]+)/dev <span style=\"color:steelblue;\">\1<\/span>/; s/vlan ([0-9]+)/vlan <span style=\"color:red;\">\1<\/span>/; s/dst ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/dst <span style=\"color:lime;\">\1<\/span>/'" >> monitor-results/${hostname}.html


    # BGP Status for device page
    echo "<h1></h1><h1><font color="#b57614">BGP Status ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html    
    mkdir -p monitor-results/bgp-data
    bgp_output=$(ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "sudo vtysh -c \"show bgp vrf all sum\"" 2>/dev/null)
    echo "$bgp_output" > "monitor-results/bgp-data/${hostname}_bgp.txt"
    echo "$bgp_output" | sed -E 's/(VRF\s+)([a-zA-Z0-9_-]+)/\1<span style=\"color:tomato;\">\2<\/span>/g; s/Total number of neighbors ([0-9]+)/Total number of neighbors <span style=\"color:steelblue;\">\1<\/span>/g; s/(\S+)\s+(\S+)\s+Summary/<span style=\"color:lime;\">\1 \2<\/span> Summary/g; s/\b(Active|Idle)\b/<span style=\"color:red;\">\1<\/span>/g' >> monitor-results/${hostname}.html


    echo "<h1></h1><h1><font color="#b57614">Port LAYER-1 Status ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "sudo l1-show all | sed -E 's/^Port: +([^ ]+)/\n=========================================================================================\n\nPort:  <span style=\"color:steelblue;\">\1<\/span>\n/g; s/Troubleshooting Info: (.+)/<span style=\"color:tomato;\">Troubleshooting Info:<\/span><span style=\"color:lime;\"> \1<\/span>/g'" >> monitor-results/${hostname}.html

    echo "<h1></h1><h1><font color="#b57614">Port LAYER-1 BER Status ${hostname}</font></h1><h3></h3>" >> monitor-results/${hostname}.html
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "sudo l1-show all -p | awk 'BEGIN { FS=\": +\"; OFS=\"\t\"; print \"Port\",\"Time_Since_Last_Clear\",\"Phy_Received_Bits\",\"Phy_Symbol_Errors\",\"Phy_Corrected_Bits\",\"Phy_Raw_Errors_Lane0\",\"Phy_Raw_Errors_Lane1\",\"Phy_Raw_Errors_Lane2\",\"Phy_Raw_Errors_Lane3\",\"Phy_Raw_Errors_Lane4\",\"Phy_Raw_Errors_Lane5\",\"Phy_Raw_Errors_Lane6\",\"Phy_Raw_Errors_Lane7\",\"Raw_BER_Magnitude\",\"Raw_BER_Coef\",\"Effective_BER_Magnitude\",\"Effective_BER_Coef\"; } /^Port:/ { if (port != \"\") print port, tslc, prb, pse, pcb, prl0, prl1, prl2, prl3, prl4, prl5, prl6, prl7, rbm, rbc, ebm, ebc; port = \$2; tslc = prb = pse = pcb = prl0 = prl1 = prl2 = prl3 = prl4 = prl5 = prl6 = prl7 = rbm = rbc = ebm = ebc = \"\"; next; } /time_since_last_clear/ { tslc = \$2 } /phy_received_bits/ { prb = \$2 } /phy_symbol_errors/ { pse = \$2 } /phy_corrected_bits/ { pcb = \$2 } /phy_raw_errors_lane0/ { prl0 = \$2 } /phy_raw_errors_lane1/ { prl1 = \$2 } /phy_raw_errors_lane2/ { prl2 = \$2 } /phy_raw_errors_lane3/ { prl3 = \$2 } /phy_raw_errors_lane4/ { prl4 = \$2 } /phy_raw_errors_lane5/ { prl5 = \$2 } /phy_raw_errors_lane6/ { prl6 = \$2 } /phy_raw_errors_lane7/ { prl7 = \$2 } /raw_ber_magnitude/ { rbm = \$2 } /raw_ber_coef/ { rbc = \$2 } /effective_ber_magnitude/ { ebm = \$2 } /effective_ber_coef/ { ebc = \$2 } END { if (port != \"\") print port, tslc, prb, pse, pcb, prl0, prl1, prl2, prl3, prl4, prl5, prl6, prl7, rbm, rbc, ebm, ebc; }' | column -t -s \$'\t' | sed -E '1! s/^(\S+)/<span style=\"color:steelblue;\">\1<\/span>/'" >> monitor-results/${hostname}.html

    # Carrier Transition Collection for Link Flap Detection (lldpqv2 method)
    echo "Collecting carrier transitions for flap detection on ${hostname}..."
    mkdir -p monitor-results/flap-data
    carrier_file="monitor-results/flap-data/${hostname}_carrier_transitions.txt"
    
    # Use lldpqv2's proven method
    carrier_stats=$(ssh -o StrictHostKeyChecking=no -T -q "$user@$device" '
        echo "=== CARRIER TRANSITIONS ==="
        
        # Get all swp interfaces (both standard and breakout formats) 
        all_interfaces=$(nv show interface 2>/dev/null | grep -E "swp[0-9]+(s[0-9]+)?" | awk "{print \$1}" || ls /sys/class/net/swp* 2>/dev/null | xargs -n1 basename)
        
        for interface in $all_interfaces; do
            # Skip if interface does not exist in system
            if [ ! -e "/sys/class/net/$interface" ]; then
                continue
            fi
            
            # Try NVUE command first (Cumulus/NVIDIA switches)
            carrier_count=$(nv show interface $interface counters 2>/dev/null | grep "carrier-transitions" | awk "{print \$2}")
            if [ -z "$carrier_count" ] || [ "$carrier_count" = "" ]; then
                # Fallback to system file (FIXED: carrier_changes not carrier_transitions!)
                carrier_count=$(cat /sys/class/net/$interface/carrier_changes 2>/dev/null || echo "0")
            fi
            
            # Only include if we got a valid number
            if [[ "$carrier_count" =~ ^[0-9]+$ ]]; then
                echo "$interface:$carrier_count"
            fi
        done
    ' 2>/dev/null)
    
    # Save carrier transition data
    echo "$carrier_stats" > "$carrier_file"
    
    echo "</h3>" >> monitor-results/${hostname}.html
    echo "</pre>" >> monitor-results/${hostname}.html
    echo -e "<span style=\"color:tomato;\">Created on $DATE</span>" >> monitor-results/${hostname}.html
    echo "</body></html>" >> monitor-results/${hostname}.html
}

process_device() {
    local device=$1
    local user=$2
    local hostname=$3
    ping_test "$device" "$hostname"
    if [ $? -eq 0 ]; then
        execute_commands "$device" "$user" "$hostname"
    fi
}

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    process_device "$device" "$user" "$hostname" &
done

wait

echo ""
echo -e "\e[1;34mAll commands have been executed...\e[0m"
echo ""

if [ -s "$unreachable_hosts_file" ]; then
    echo -e "\e[0;36mUnreachable hosts:\e[0m"
    echo ""
    while IFS= read -r host; do
        IFS=' ' read -r ip hostname <<< "$host"
        printf "\e[31m[%-14s]\t\e[0;31m[%-1s]\e[0m\n" "$ip" "$hostname"
    done < "$unreachable_hosts_file"
    echo ""
else
    echo -e "\e[0;32mAll hosts are reachable.\e[0m"
    echo ""
fi

# Run BGP Neighbor Analysis
echo -e "\n\e[0;34mRunning BGP Neighbor Analysis...\e[0m"
cd "$(dirname "$0")"
if python3 process_bgp_data.py; then
    echo -e "\e[0;32mBGP analysis completed successfully\e[0m"
else
    echo -e "\e[0;33mWarning: BGP analysis failed\e[0m"
fi

# Run Link Flap Analysis
echo -e "\n\e[0;34mRunning Link Flap Analysis...\e[0m"
cd "$(dirname "$0")"
if python3 process_flap_data.py; then
    echo -e "\e[0;32mLink Flap analysis completed successfully\e[0m"
else
    echo -e "\e[0;33mWarning: Link Flap analysis failed\e[0m"
fi

sudo cp -r monitor-results/ /var/www/html/
sudo chmod 644 /var/www/html/monitor-results/*
rm -f "$unreachable_hosts_file"
exit 0
