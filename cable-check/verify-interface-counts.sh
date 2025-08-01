#!/bin/bash
# Network Interface Count Analysis and Verification Tool
# Analyzes interface counts across all devices and compares with monitoring results

show_usage() {
    echo "Network Interface Count Analysis Tool"
    echo "===================================="
    echo ""
    echo "USAGE:"
    echo "  verify-interface-counts.sh [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -h, --help     Show this help message"
    echo "  -q, --quiet    Suppress device-by-device output"
    echo "  -s, --summary  Show only summary and comparison"
    echo ""
    echo "DESCRIPTION:"
    echo "  This tool analyzes network interface counts across all devices"
    echo "  and compares them with actual monitoring results. It helps"
    echo "  verify that monitoring systems are counting interfaces correctly."
    echo ""
}

# Parse command line arguments
QUIET_MODE=false
SUMMARY_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_usage
            exit 0
            ;;
        -q|--quiet)
            QUIET_MODE=true
            shift
            ;;
        -s|--summary)
            SUMMARY_ONLY=true
            QUIET_MODE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

if [[ "$SUMMARY_ONLY" == false ]]; then
    echo "Network Interface Count Analysis"
    echo "================================"
fi

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
    
    if [[ "$QUIET_MODE" == false ]]; then
        echo "Checking $hostname..."
    fi
    
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
        
        # Base interfaces only (swp1, swp2, swp32 - no breakouts, exclude mgmt/eth0)
        # THIS IS THE REAL NETWORK STATE - what should be monitored
        base_only=$(echo "$interface_list" | grep -E "^swp[0-9]+\s" | grep -vE "swp[0-9]+s[0-9]+" | wc -l || echo "0")
        echo "BASE_ONLY: $base_only"
        
        # Breakout sub-interfaces (swp1s0, swp1s1, etc)  
        breakout_subs=$(echo "$interface_list" | grep -cE "swp[0-9]+s[0-9]+" || echo "0")
        echo "BREAKOUT_SUBS: $breakout_subs"
        
        # Admin up interfaces (base only - exclude breakouts)
        admin_up=$(echo "$interface_list" | grep -E "^swp[0-9]+\s" | grep -vE "swp[0-9]+s[0-9]+" | grep -c "up" || echo "0")
        echo "ADMIN_UP: $admin_up"
        
        # Comprehensive transceiver detection (check ALL interfaces for accuracy)
        echo "TRANSCEIVER_DETECTION: Starting comprehensive check..."
        all_interfaces=$(echo "$interface_list" | grep -E "^swp[0-9]+\s" | grep -vE "swp[0-9]+s[0-9]+" | awk '{print $1}')
        
        actual_transceivers=0
        plugged_transceivers=0
        unplugged_transceivers=0
        no_transceiver_slots=0
        
        for iface in $all_interfaces; do
            transceiver_result=$(ssh $SSH_OPTS -q "$user@$device" "nv show interface $iface transceiver 2>/dev/null" 2>/dev/null)
            
            if [[ -z "$transceiver_result" ]]; then
                # SSH/Command failed
                continue
            elif [[ "$transceiver_result" == *"Error: The requested item does not exist"* ]]; then
                # No transceiver slot at all
                ((no_transceiver_slots++))
            elif [[ "$transceiver_result" == *"No transceiver data available"* ]]; then
                # Has slot but no transceiver
                ((unplugged_transceivers++))
                ((actual_transceivers++))
            elif [[ "$transceiver_result" == *"status"*"unplugged"* ]]; then
                # Unplugged transceiver (still a transceiver port)
                ((unplugged_transceivers++))
                ((actual_transceivers++))
            else
                # Working transceiver
                ((plugged_transceivers++))
                ((actual_transceivers++))
            fi
        done
        
        echo "TRANSCEIVER_SLOTS: $actual_transceivers"
        echo "PLUGGED_TRANSCEIVERS: $plugged_transceivers"
        echo "UNPLUGGED_TRANSCEIVERS: $unplugged_transceivers"
        echo "NO_TRANSCEIVER_SLOTS: $no_transceiver_slots"
        
        echo "=== END_COUNTS ==="
    } >> "$RESULTS_FILE" 2>/dev/null &
}

if [[ "$QUIET_MODE" == false ]]; then
    echo "Starting parallel verification..."
    echo ""
fi

# Process all devices in parallel
pids=()
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    verify_device "$device" "$user" "$hostname" &
    pids+=($!)
done

# Wait for all to complete
if [[ "$QUIET_MODE" == false ]]; then
    echo "Waiting for all devices to respond..."
fi
for pid in "${pids[@]}"; do
    wait $pid
done

if [[ "$SUMMARY_ONLY" == false ]]; then
    echo ""
    echo "Verification completed! Processing results..."
    echo ""

    # Analyze results
    echo "INTERFACE COUNT SUMMARY"
    echo "======================="
fi

total_devices=0
total_swp_sum=0
base_only_sum=0
breakout_subs_sum=0
transceivers_slots_sum=0
plugged_transceivers_sum=0
unplugged_transceivers_sum=0
no_transceiver_slots_sum=0
admin_up_sum=0

while IFS= read -r line; do
    if [[ $line == *"INTERFACE COUNTS FOR"* ]]; then
        hostname=$(echo "$line" | sed 's/.*FOR //' | sed 's/ ===$//')
        ((total_devices++))
        # Device details stored in results file only
    elif [[ $line == TOTAL_SWP:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        total_swp_sum=$((total_swp_sum + count))
    elif [[ $line == BASE_ONLY:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        base_only_sum=$((base_only_sum + count))

    elif [[ $line == BREAKOUT_SUBS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        breakout_subs_sum=$((breakout_subs_sum + count))
    elif [[ $line == TRANSCEIVER_SLOTS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        transceivers_slots_sum=$((transceivers_slots_sum + count))
    elif [[ $line == PLUGGED_TRANSCEIVERS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        plugged_transceivers_sum=$((plugged_transceivers_sum + count))
    elif [[ $line == UNPLUGGED_TRANSCEIVERS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        unplugged_transceivers_sum=$((unplugged_transceivers_sum + count))
    elif [[ $line == NO_TRANSCEIVER_SLOTS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        no_transceiver_slots_sum=$((no_transceiver_slots_sum + count))
    elif [[ $line == ADMIN_UP:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        admin_up_sum=$((admin_up_sum + count))
    elif [[ $line == *"ERROR"* ]]; then
        if [[ "$QUIET_MODE" == false ]]; then
            echo "  ERROR: $line"
            echo ""
        fi
    fi
done < "$RESULTS_FILE"

echo ""
echo "NETWORK TOTALS"
echo "=============="
echo "Total devices checked: $total_devices"
echo "Total SWP interfaces: $total_swp_sum"
echo "Base interfaces only: $base_only_sum (REAL NETWORK - what should be monitored)" 
echo "Breakout sub-interfaces: $breakout_subs_sum"
echo "Admin up interfaces: $admin_up_sum"
echo ""
echo "TRANSCEIVER ANALYSIS (Comprehensive)"
echo "==================================="
echo "Total transceiver slots: $transceivers_slots_sum"
echo "Plugged transceivers: $plugged_transceivers_sum"
echo "Unplugged transceiver slots: $unplugged_transceivers_sum"
echo "No transceiver capability: $no_transceiver_slots_sum"
echo ""

echo "ANALYSIS"
echo "========"
if [[ $total_devices -gt 0 ]]; then
    avg_base=$((base_only_sum / total_devices))
    avg_transceiver_slots=$((transceivers_slots_sum / total_devices))
    avg_plugged=$((plugged_transceivers_sum / total_devices))
    
    echo "Average base interfaces per device: $avg_base"
    echo "Average transceiver slots per device: $avg_transceiver_slots"
    echo "Average plugged transceivers per device: $avg_plugged"
    
    # Calculate percentages
    if [[ $transceivers_slots_sum -gt 0 ]]; then
        plugged_percentage=$((plugged_transceivers_sum * 100 / transceivers_slots_sum))
        echo "Transceiver utilization: $plugged_percentage% plugged"
    fi
    echo ""
    
    echo "EXPECTED MONITORING COUNTS (Real Network)"
    echo "========================================="
    echo "Link Flap Total Ports: $base_only_sum (base interfaces)"
    echo "Optical Total Ports: $transceivers_slots_sum (all transceiver slots - includes unplugged)"
    echo "Optical Plugged Only: $plugged_transceivers_sum (only plugged transceivers)"
    echo "BER Total Ports: ~$((base_only_sum * 85 / 100)) (estimated 85% with traffic)"
    echo ""
    
    # Compare with actual monitoring results to validate monitor.sh
    echo "MONITOR.SH VALIDATION RESULTS"
    echo "============================="
    
    # Check Link Flap results with detailed analysis
    if [[ -f "monitor-results/link-flap-analysis.html" ]]; then
        flap_actual=$(grep -A 10 "Total Ports" monitor-results/link-flap-analysis.html 2>/dev/null | grep -o 'id="total-ports">[0-9]\+' | grep -o '[0-9]\+' | head -1)
        if [[ -z "$flap_actual" ]]; then
            # Fallback: look for any metric number after "Total Ports"
            flap_actual=$(grep -A 10 "Total Ports" monitor-results/link-flap-analysis.html 2>/dev/null | grep -o ">[0-9]\+<" | grep -o '[0-9]\+' | head -1)
        fi
        if [[ -n "$flap_actual" ]]; then
            flap_diff=$((flap_actual - base_only_sum))
            echo "Link Flap: Expected $base_only_sum, Actual $flap_actual (diff: $flap_diff)"
            
            # Detailed analysis of flap data collection
            if [[ -d "monitor-results/flap-data" ]]; then
                flap_files=$(ls monitor-results/flap-data/*_carrier_transitions.txt 2>/dev/null | wc -l)
                total_flap_ports=0
                empty_files=0
                # Process flap data files safely
                if ls monitor-results/flap-data/*_carrier_transitions.txt >/dev/null 2>&1; then
                    for file in monitor-results/flap-data/*_carrier_transitions.txt; do
                        if [[ -f "$file" ]]; then
                            port_count=$(grep -c ":" "$file" 2>/dev/null || echo 0)
                            if [[ $port_count -eq 0 ]]; then
                                ((empty_files++))
                            else
                                total_flap_ports=$((total_flap_ports + port_count))
                            fi
                        fi
                    done
                fi
                echo "  Flap Data Details: $flap_files devices, $total_flap_ports raw ports, $empty_files empty files"
                if [[ $flap_diff -lt 0 ]]; then
                    echo "  MONITOR.SH ISSUE: Missing $((0 - flap_diff)) interfaces"
                    echo "  Possible causes: SSH timeouts, /sys/class/net/ filtering, interface detection failures"
                elif [[ $flap_diff -gt 0 ]]; then
                    echo "  MONITOR.SH COLLECTING EXTRA: $flap_diff more interfaces than expected"
                else
                    echo "  MONITOR.SH STATUS: PERFECT MATCH!"
                fi
            fi
        fi
    fi
    
    # Check Optical results
    if [[ -f "monitor-results/optical-analysis.html" ]]; then
        optical_actual=$(grep -A 10 "Total Ports" monitor-results/optical-analysis.html 2>/dev/null | grep -o 'id="total-ports">[0-9]\+' | grep -o '[0-9]\+' | head -1)
        if [[ -z "$optical_actual" ]]; then
            # Fallback: look for any metric number after "Total Ports"
            optical_actual=$(grep -A 10 "Total Ports" monitor-results/optical-analysis.html 2>/dev/null | grep -o ">[0-9]\+<" | grep -o '[0-9]\+' | head -1)
        fi
        if [[ -n "$optical_actual" ]]; then
            # Compare with both total slots and plugged only
            total_slots_diff=$((optical_actual - transceivers_slots_sum))
            plugged_only_diff=$((optical_actual - plugged_transceivers_sum))
            
            echo "Optical Total Slots: Expected $transceivers_slots_sum, Actual $optical_actual (diff: $total_slots_diff)"
            echo "Optical Plugged Only: Expected $plugged_transceivers_sum, Actual $optical_actual (diff: $plugged_only_diff)"
            
            # Determine which expectation is closer
            if [[ ${plugged_only_diff#-} -lt ${total_slots_diff#-} ]]; then
                echo "  ANALYSIS: Monitor.sh appears to track PLUGGED transceivers only"
                if [[ $plugged_only_diff -eq 0 ]]; then
                    echo "  MONITOR.SH STATUS: PERFECT MATCH for plugged transceivers!"
                elif [[ ${plugged_only_diff#-} -lt 50 ]]; then
                    echo "  MONITOR.SH STATUS: Very close to plugged transceivers count"
                fi
            else
                echo "  ANALYSIS: Monitor.sh may be tracking total transceiver slots"
            fi
        fi
    fi
    
    # Check BER results
    if [[ -f "monitor-results/ber-analysis.html" ]]; then
        ber_actual=$(grep -A 10 "Total Ports" monitor-results/ber-analysis.html 2>/dev/null | grep -o 'id="total-ports">[0-9]\+' | grep -o '[0-9]\+' | head -1)
        if [[ -z "$ber_actual" ]]; then
            # Fallback: look for any metric number after "Total Ports"
            ber_actual=$(grep -A 10 "Total Ports" monitor-results/ber-analysis.html 2>/dev/null | grep -o ">[0-9]\+<" | grep -o '[0-9]\+' | head -1)
        fi
        if [[ -n "$ber_actual" ]]; then
            ber_expected=$((base_only_sum * 85 / 100))
            ber_diff=$((ber_actual - ber_expected))
            echo "BER: Expected ~$ber_expected, Actual $ber_actual (diff: $ber_diff)"
        fi
    fi
    echo ""
    
    if [[ $breakout_subs_sum -gt 0 ]]; then
        echo "WARNING: $breakout_subs_sum breakout sub-interfaces found!"
        echo "Monitor.sh should exclude these breakout sub-interfaces."
        echo "Only base interfaces should be monitored: $base_only_sum"
        echo ""
    fi
    
    # Generate summary
    echo "ANALYSIS SUMMARY"
    echo "==============="
    echo "Total network devices: $total_devices"
    echo "Total physical interfaces: $base_only_sum"
    echo "Total transceiver slots: $transceivers_slots_sum"
    echo "Plugged transceivers: $plugged_transceivers_sum"
    echo "Unplugged transceiver slots: $unplugged_transceivers_sum"
    echo "No transceiver capability: $no_transceiver_slots_sum"
    echo "Breakout sub-interfaces: $breakout_subs_sum"
    echo "Admin up interfaces: $admin_up_sum"
    
    # Calculate percentages
    if [[ $base_only_sum -gt 0 ]]; then
        up_percentage=$((admin_up_sum * 100 / base_only_sum))
        transceiver_slot_percentage=$((transceivers_slots_sum * 100 / base_only_sum))
        echo "Interface utilization: $up_percentage% admin up"
        echo "Optical slot density: $transceiver_slot_percentage% have transceiver capability"
        
        if [[ $transceivers_slots_sum -gt 0 ]]; then
            plugged_utilization=$((plugged_transceivers_sum * 100 / transceivers_slots_sum))
            echo "Transceiver utilization: $plugged_utilization% of slots are plugged"
        fi
    fi
fi

echo ""
echo "Raw results saved to: $RESULTS_FILE"
echo "Analysis completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""