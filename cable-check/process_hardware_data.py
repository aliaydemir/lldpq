#!/usr/bin/env python3
"""
Process hardware health data collected by monitor.sh
"""

import os
import sys
from datetime import datetime
from hardware_analyzer import HardwareAnalyzer


def process_hardware_data_files(data_dir="monitor-results"):
    """Process all hardware data files and generate analysis"""
    
    analyzer = HardwareAnalyzer(data_dir)
    processed_count = 0
    
    # Look for hardware data files (they don't exist yet, will be created by monitor.sh updates)
    hardware_data_dir = f"{data_dir}/hardware-data"
    
    if not os.path.exists(hardware_data_dir):
        print("📂 Hardware data directory doesn't exist yet.")
        print("💡 Hardware data collection needs to be added to monitor.sh")
        return processed_count
    
    # Process all hardware data files
    for filename in os.listdir(hardware_data_dir):
        if filename.endswith('_hardware.txt'):
            device_name = filename.replace('_hardware.txt', '')
            filepath = os.path.join(hardware_data_dir, filename)
            
            print(f"🔍 Processing hardware data for {device_name}")
            
            try:
                # Read hardware data file
                with open(filepath, 'r') as f:
                    content = f.read()
                
                # Parse different sections from the hardware data file
                sections = parse_hardware_file_sections(content)
                
                if sections:
                    # Update analyzer with parsed data
                    hardware_record = analyzer.update_device_hardware(
                        device_name=device_name,
                        sensors_output=sections.get('sensors', ''),
                        memory_info=sections.get('memory', ''),
                        cpu_info=sections.get('cpu', ''),
                        uptime_info=sections.get('uptime', '')
                    )
                    
                    print(f"  ✅ {device_name}: Health={hardware_record['overall_grade']}, "
                          f"Critical={hardware_record['critical_issues']}, "
                          f"Warning={hardware_record['warning_issues']}")
                    
                    processed_count += 1
                else:
                    print(f"  ❌ {device_name}: No valid hardware data found")
                    
            except Exception as e:
                print(f"  ❌ {device_name}: Error processing - {str(e)}")
    
    if processed_count > 0:
        # Save updated history
        analyzer.save_hardware_history()
        
        # Generate HTML report
        output_file = f"{data_dir}/hardware-analysis.html"
        devices_reported = analyzer.generate_html_report(output_file)
        
        # Print summary
        summary = analyzer.get_hardware_summary()
        anomalies = analyzer.detect_hardware_anomalies()
        
        print(f"\n📊 Processed {processed_count} files total")
        print(f"💾 Hardware history saved")
        print(f"📄 Hardware analysis report generated: {output_file}")
        print(f"📈 Summary stats: {summary['total_devices']} total devices analyzed")
        
        print(f"\n🔧 Hardware Health Summary:")
        print(f"  Total devices monitored: {summary['total_devices']}")
        print(f"  Excellent health: {summary['excellent_health']}")
        print(f"  Good health: {summary['good_health']}")
        print(f"  Warning level: {summary['warning_level']}")
        print(f"  Critical issues: {summary['critical_issues']}")
        
        # Show critical hardware issues
        critical_anomalies = [a for a in anomalies if a['severity'] == 'critical']
        if critical_anomalies:
            print(f"\n🔴 Critical Hardware Issues (Immediate Attention):")
            for anomaly in critical_anomalies[:10]:  # Show first 10
                print(f"    {anomaly['device']}:{anomaly['component']}: {anomaly['message']}")
        
        # Show hardware anomalies
        warning_anomalies = [a for a in anomalies if a['severity'] == 'warning']
        if warning_anomalies:
            print(f"\n⚠️ Hardware Warnings Detected:")
            for anomaly in warning_anomalies[:5]:  # Show first 5
                print(f"    {anomaly['device']}:{anomaly['component']}: {anomaly['message']}")
                print(f"      Action: {anomaly['action']}")
        
        print(f"\n✅ Excellent Hardware Health: {summary['excellent_health']} devices performing optimally")
    else:
        print("📂 No hardware data files found to process")
        print("💡 Run monitor.sh with hardware collection enabled first")
    
    print(f"[{datetime.now()}] Hardware data processing completed")
    return processed_count


def parse_hardware_file_sections(content: str) -> dict:
    """Parse hardware data file into sections"""
    sections = {
        'sensors': '',
        'memory': '',
        'cpu': '',
        'uptime': ''
    }
    
    # Split content by section markers
    lines = content.split('\n')
    current_section = None
    
    for line in lines:
        line = line.strip()
        
        # Detect section headers
        if line == "HARDWARE_HEALTH:":
            current_section = 'sensors'
            continue
        elif line == "MEMORY_INFO:":
            current_section = 'memory'
            continue
        elif line == "CPU_INFO:":
            current_section = 'cpu'
            continue
        elif line == "UPTIME_INFO:":
            current_section = 'uptime'
            continue
        
        # Add content to current section
        if current_section and line:
            sections[current_section] += line + '\n'
    
    return sections


def main():
    """Main function to process hardware data"""
    
    # Get script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(script_dir, "monitor-results")
    
    print("🔧 Starting hardware health data processing...")
    print(f"📂 Data directory: {data_dir}")
    
    # Check if data directory exists
    if not os.path.exists(data_dir):
        print(f"❌ Data directory not found: {data_dir}")
        print("💡 Run monitor.sh first to collect data")
        sys.exit(1)
    
    # Process hardware data
    processed_count = process_hardware_data_files(data_dir)
    
    if processed_count == 0:
        print("\n💡 To enable hardware monitoring:")
        print("   1. Hardware data collection is not yet added to monitor.sh")
        print("   2. This will be added in the next step")
        print("   3. After updating monitor.sh, run it to collect hardware data")
        print("   4. Then run this script again to generate hardware analysis")


if __name__ == "__main__":
    main()