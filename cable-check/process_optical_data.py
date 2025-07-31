#!/usr/bin/env python3
"""
Process optical diagnostics data collected by monitor.sh
"""

import os
import re
import sys
from datetime import datetime
from optical_analyzer import OpticalAnalyzer

def parse_optical_diagnostics_file(filepath):
    """Parse optical diagnostics file"""
    port_data = {}
    
    try:
        with open(filepath, "r") as f:
            content = f.read()
        
        # Split by interface sections
        sections = content.split("--- Interface:")
        
        for section in sections[1:]:  # Skip first empty section
            lines = section.strip().split('\n')
            if not lines:
                continue
                
            # Extract interface name from first line
            interface_line = lines[0].strip()
            interface_match = re.match(r'(\w+)', interface_line)
            if not interface_match:
                continue
                
            interface = interface_match.group(1)
            
            # Combine all data for this interface
            interface_data = '\n'.join(lines[1:])
            port_data[interface] = interface_data
    
    except Exception as e:
        print(f"Error parsing {filepath}: {e}")
    
    return port_data

def process_optical_data_files(data_dir="monitor-results/optical-data"):
    """Process optical data files and update optical analyzer"""
    optical_analyzer = OpticalAnalyzer("monitor-results")
    
    print("🔬 Processing optical diagnostics data")
    print(f"📁 Data directory: {data_dir}")
    print(f"📊 Using optical thresholds: RX Power={optical_analyzer.thresholds['rx_power_min_dbm']:.1f} to {optical_analyzer.thresholds['rx_power_max_dbm']:.1f} dBm, "
          f"Temperature max={optical_analyzer.thresholds['temperature_max_c']:.1f}°C")
    
    if not os.path.exists(data_dir):
        print(f"❌ Optical data directory {data_dir} not found")
        return
    
    # List files in directory
    files = os.listdir(data_dir)
    print(f"📂 Found {len(files)} files in {data_dir}: {files}")
    
    # Process all optical diagnostic files
    total_processed = 0
    for filename in os.listdir(data_dir):
        if filename.endswith("_optical.txt"):
            hostname = filename.replace("_optical.txt", "")
            filepath = os.path.join(data_dir, filename)
            
            print(f"\n🔍 Processing optical data for {hostname}")
            print(f"📄 File: {filepath}")
            
            # Parse optical diagnostics file
            port_data = parse_optical_diagnostics_file(filepath)
            print(f"📋 Found {len(port_data)} ports in {filename}")
            total_processed += 1
            
            for interface, optical_data in port_data.items():
                port_name = f"{hostname}:{interface}"
                
                # Skip non-optical interfaces (management, virtual interfaces)
                if any(skip_iface in interface.lower() for skip_iface in ['eth0', 'lo', 'bond', 'mgmt', 'vlan']):
                    print(f"  {port_name}: Skipped (non-optical interface)")
                    continue
                
                # Skip if no meaningful data (Fixed: don't filter on error-status N/A)
                if not optical_data or len(optical_data.strip()) < 10:
                    print(f"  {port_name}: No optical data available")
                    continue
                
                # Skip if diagnostic data is explicitly unavailable  
                if "diagnostics-status          : N/A" in optical_data or "status                      : unplugged" in optical_data:
                    print(f"  {port_name}: No transceiver or diagnostics unavailable")
                    continue
                
                # Update optical analyzer
                optical_analyzer.update_optical_stats(port_name, optical_data)
                
                # Show results
                if port_name in optical_analyzer.current_optical_stats:
                    current_optical = optical_analyzer.current_optical_stats[port_name]
                    health = current_optical['health_status']
                    rx_power = current_optical.get('rx_power_dbm')
                    temperature = current_optical.get('temperature_c')
                    voltage = current_optical.get('voltage_v')
                    
                    rx_power_str = f"{rx_power:.2f} dBm" if rx_power is not None else "N/A"
                    temp_str = f"{temperature:.1f}°C" if temperature is not None else "N/A"
                    voltage_str = f"{voltage:.2f}V" if voltage is not None else "N/A"
                    
                    print(f"  ✅ {port_name}: Health={health.upper()}, RX Power={rx_power_str}, Temp={temp_str}, Voltage={voltage_str}")
                else:
                    print(f"  ❌ {port_name}: No optical parameters detected")
    
    print(f"\n📊 Processed {total_processed} files total")
    
    # Save updated optical history
    optical_analyzer.save_optical_history()
    print("💾 Optical history saved")
    
    # Generate web report
    output_file = "monitor-results/optical-analysis.html"
    optical_analyzer.export_optical_data_for_web(output_file)
    print(f"📄 Optical analysis report generated: {output_file}")
    
    # Generate summary for dashboard
    summary = optical_analyzer.get_optical_summary()
    anomalies = optical_analyzer.detect_optical_anomalies()
    print(f"📈 Summary stats: {len(optical_analyzer.current_optical_stats)} total ports analyzed")
    
    print(f"\n🔬 Optical Analysis Summary:")
    print(f"  Total ports monitored: {summary['total_ports']}")
    print(f"  Excellent health: {len(summary['excellent_ports'])}")
    print(f"  Good health: {len(summary['good_ports'])}")
    print(f"  Warning level: {len(summary['warning_ports'])}")
    print(f"  Critical issues: {len(summary['critical_ports'])}")
    print(f"  Anomalies detected: {len(anomalies)}")
    
    if summary['critical_ports']:
        print("\n🔴 Critical Optical Issues (Immediate Attention):")
        for port in summary['critical_ports']:
            rx_power = f"{port['rx_power_dbm']:.2f} dBm" if port['rx_power_dbm'] is not None else "N/A"
            temp = f"{port['temperature_c']:.1f}°C" if port['temperature_c'] is not None else "N/A"
            print(f"    {port['port']}: Health={port['health'].upper()}, RX Power={rx_power}, Temp={temp}")
    
    if summary['warning_ports']:
        print("\n🟠 Warning Level Issues (Monitor Closely):")
        for port in summary['warning_ports'][:5]:  # Show top 5
            rx_power = f"{port['rx_power_dbm']:.2f} dBm" if port['rx_power_dbm'] is not None else "N/A"
            link_margin = f"{port['link_margin_db']:.2f} dB" if port['link_margin_db'] is not None else "N/A"
            print(f"    {port['port']}: Health={port['health'].upper()}, RX Power={rx_power}, Link Margin={link_margin}")
    
    if anomalies:
        print("\n⚠️ Optical Anomalies Detected:")
        for anomaly in anomalies[:3]:  # Show top 3
            print(f"    {anomaly['port']}: {anomaly['type']} - {anomaly['message']}")
            print(f"      Action: {anomaly['action']}")
    
    # Check for excellent performers
    if summary['excellent_ports']:
        print(f"\n✅ Excellent Optical Health: {len(summary['excellent_ports'])} ports performing optimally")

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)
    
    print(f"[{datetime.now()}] Starting optical data processing")
    process_optical_data_files()
    print(f"[{datetime.now()}] Optical data processing completed")