#!/usr/bin/env python3
"""
Process LLDP neighbor data collected by check-lldp.sh
"""

import os
import re
import sys
from datetime import datetime
from lldp_analyzer import LLDPAnalyzer

def process_lldp_data_files(data_dir="lldp-results"):
    """Process LLDP data files and update LLDP analyzer"""
    lldp_analyzer = LLDPAnalyzer("monitor-results")
    
    print("Processing LLDP neighbor data")
    print(f"Using LLDP thresholds: Missing connection hours={lldp_analyzer.thresholds['missing_connection_critical_hours']}h, "
          f"Unexpected threshold={lldp_analyzer.thresholds['unexpected_connection_warning_count']}")
    
    if not os.path.exists(data_dir):
        print(f"LLDP data directory {data_dir} not found")
        return
    
    # Process all LLDP result files
    for filename in os.listdir(data_dir):
        if filename.endswith("_lldp_result.ini"):
            hostname = filename.replace("_lldp_result.ini", "")
            filepath = os.path.join(data_dir, filename)
            
            print(f"Processing LLDP data for {hostname}")
            
            # Check if file exists and has content
            if not os.path.exists(filepath):
                print(f"  {hostname}: LLDP data file not found")
                continue
                
            file_size = os.path.getsize(filepath)
            if file_size < 100:  # Very small file, likely no data
                print(f"  {hostname}: No LLDP data available (file too small)")
                continue
            
            # Update LLDP analyzer
            lldp_analyzer.update_lldp_stats(hostname, filepath)
            
            # Show results
            if hostname in lldp_analyzer.current_lldp_stats:
                stats = lldp_analyzer.current_lldp_stats[hostname]
                total = stats["total_connections"]
                established = stats["established_connections"]
                missing = stats["missing_connections"]
                mismatched = stats["mismatched_connections"]
                unexpected = stats["unexpected_connections"]
                
                print(f"  {hostname}: Total={total}, Established={established}, Missing={missing}, Mismatched={mismatched}, Unexpected={unexpected}")
                
                # Show problematic connections
                for conn_data in stats["connections"]:
                    if conn_data['state'] in ['missing', 'mismatch']:
                        if conn_data['state'] == 'missing':
                            print(f"    ⚠️  {conn_data['source_interface']}: MISSING connection to {conn_data['expected_neighbor']}:{conn_data['expected_interface']}")
                        elif conn_data['state'] == 'mismatch':
                            print(f"    🔥 {conn_data['source_interface']}: MISMATCH - Expected {conn_data['expected_neighbor']}:{conn_data['expected_interface']}, Found {conn_data['neighbor_device']}:{conn_data['neighbor_interface']}")
            else:
                print(f"  {hostname}: No LLDP connections processed")
    
    # Save updated LLDP history
    lldp_analyzer.save_historical_data()
    
    # Generate web report
    output_file = "monitor-results/lldp-analysis.html"
    lldp_analyzer.export_lldp_data_for_web(output_file)
    print(f"LLDP analysis report generated: {output_file}")
    
    # Generate summary for dashboard
    summary = lldp_analyzer.get_lldp_summary()
    anomalies = lldp_analyzer.detect_lldp_anomalies()
    
    print(f"\n📊 LLDP Analysis Summary:")
    print(f"  Total devices: {summary['total_devices']}")
    print(f"  Total connections: {summary['total_connections']}")
    print(f"  Established: {summary['established_connections']}")
    print(f"  Missing: {summary['missing_connections']}")
    print(f"  Mismatched: {summary['mismatched_connections']}")
    print(f"  Unexpected: {summary['unexpected_connections']}")
    print(f"  Health ratio: {summary['health_ratio']:.1f}%")
    print(f"  Anomalies detected: {len(anomalies)}")
    
    # Show critical issues
    critical_anomalies = [a for a in anomalies if a['severity'] == 'critical']
    if critical_anomalies:
        print(f"\n🚨 Critical LLDP Issues:")
        for anomaly in critical_anomalies[:5]:  # Show first 5
            print(f"  • {anomaly['device']}: {anomaly['interface']} - {anomaly['message']}")
    
    # Health status indicator
    if summary['health_ratio'] >= 95:
        print(f"\n✅ LLDP Network Health: EXCELLENT ({summary['health_ratio']:.1f}%)")
    elif summary['health_ratio'] >= 85:
        print(f"\n🟢 LLDP Network Health: GOOD ({summary['health_ratio']:.1f}%)")
    elif summary['health_ratio'] >= 70:
        print(f"\n🟡 LLDP Network Health: WARNING ({summary['health_ratio']:.1f}%)")
    else:
        print(f"\n🔴 LLDP Network Health: CRITICAL ({summary['health_ratio']:.1f}%)")

if __name__ == "__main__":
    import logging
    
    # Setup logging
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(message)s',
        handlers=[
            logging.FileHandler('monitor-results/lldp_analyzer.log'),
            logging.StreamHandler()
        ]
    )
    
    logging.info("Starting LLDP data processing")
    
    try:
        process_lldp_data_files()
        logging.info("LLDP data processing completed")
    except Exception as e:
        logging.error(f"LLDP data processing failed: {e}")
        sys.exit(1)