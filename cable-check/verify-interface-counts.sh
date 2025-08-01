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
        
        # Base interfaces only (swp1, swp2, swp32 - no breakouts)
        base_only=$(echo "$interface_list" | grep -E "swp[0-9]+\s" | grep -vE "swp[0-9]+s[0-9]+" | wc -l || echo "0")
        echo "BASE_ONLY: $base_only"
        
        # Breakout sub-interfaces (swp1s0, swp1s1, etc)  
        breakout_subs=$(echo "$interface_list" | grep -cE "swp[0-9]+s[0-9]+" || echo "0")
        echo "BREAKOUT_SUBS: $breakout_subs"
        
        # Admin up interfaces (base only - exclude breakouts)
        admin_up=$(echo "$interface_list" | grep -E "swp[0-9]+\s" | grep -vE "swp[0-9]+s[0-9]+" | grep -c "up" || echo "0")
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
transceivers_sum=0
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
    elif [[ $line == ESTIMATED_TRANSCEIVERS:* ]]; then
        count=$(echo "$line" | cut -d' ' -f2)
        transceivers_sum=$((transceivers_sum + count))
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
echo "Base interfaces only: $base_only_sum" 
echo "Breakout sub-interfaces: $breakout_subs_sum"
echo "Estimated interfaces with transceivers: $transceivers_sum"
echo "Admin up interfaces: $admin_up_sum"
echo ""

echo "ANALYSIS"
echo "========"
echo ""
if [[ $total_devices -gt 0 ]]; then
    
    echo "EXPECTED MONITORING COUNTS"
    echo "========================="
    echo "Link Flap Total Ports: $base_only_sum (base interfaces)"
    echo "Optical Total Ports: $transceivers_sum (estimated transceivers)"
    echo "BER Total Ports: ~$((base_only_sum * 85 / 100)) (estimated 85% with traffic)"
    echo ""
    
    # Compare with actual monitoring results if available
    echo "LLDPq MONITORING RESULTS COMPARISON"
    echo "==================================="
    
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
                echo "  Missing ports likely due to: SSH timeouts, interface detection, or data collection issues"
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
            optical_diff=$((optical_actual - transceivers_sum))
            echo "Optical: Expected $transceivers_sum, Actual $optical_actual (diff: $optical_diff)"
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
        echo "This indicates monitor.sh may be including breakout interfaces."
        echo "Total with breakouts: $total_swp_sum"
        echo "Total base only: $base_only_sum"
        echo ""
    fi
    
    # Generate summary
    echo "ANALYSIS SUMMARY"
    echo "==============="
    echo "Total network devices: $total_devices"
    echo "Total physical interfaces: $base_only_sum"
    echo "Interfaces with transceivers: $transceivers_sum"
    echo "Breakout sub-interfaces: $breakout_subs_sum"
    echo "Admin up interfaces: $admin_up_sum"
    
    # Calculate percentages
    if [[ $base_only_sum -gt 0 ]]; then
        up_percentage=$((admin_up_sum * 100 / base_only_sum))
        transceiver_percentage=$((transceivers_sum * 100 / base_only_sum))
        echo "Interface utilization: $up_percentage% admin up"
        echo "Optical density: $transceiver_percentage% with transceivers"
    fi
fi

echo ""
echo "Raw results saved to: $RESULTS_FILE"
echo "Analysis completed at: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""