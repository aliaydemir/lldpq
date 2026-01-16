#!/usr/bin/env python3
"""
Process BGP neighbor data collected by monitor.sh

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import sys
from datetime import datetime
from bgp_analyzer import BGPAnalyzer

def parse_bgp_file(filepath):
    """Parse BGP data file"""
    try:
        with open(filepath, "r") as f:
            content = f.read()
        return content
    except Exception as e:
        print(f"Error parsing {filepath}: {e}")
        return ""

def process_bgp_data_files(data_dir="monitor-results/bgp-data"):
    """Process BGP data files and update BGP analyzer"""
    bgp_analyzer = BGPAnalyzer("monitor-results")
    
    print("Processing BGP neighbor data")
    print(f"Using BGP thresholds: Down time={bgp_analyzer.thresholds['critical_down_hours']}h, "
          f"Queue threshold={bgp_analyzer.thresholds['high_queue_threshold']}")
    
    if not os.path.exists(data_dir):
        print(f"BGP data directory {data_dir} not found")
        return
    
    # Process all BGP neighbor files
    for filename in os.listdir(data_dir):
        if filename.endswith("_bgp.txt"):
            hostname = filename.replace("_bgp.txt", "")
            filepath = os.path.join(data_dir, filename)
            
            
            # Parse BGP data file
            bgp_data = parse_bgp_file(filepath)
            
            if not bgp_data or len(bgp_data.strip()) < 50:
                continue
            
            # Update BGP analyzer
            bgp_analyzer.update_bgp_stats(hostname, bgp_data)
            
            # Show results
            if hostname in bgp_analyzer.current_bgp_stats:
                stats = bgp_analyzer.current_bgp_stats[hostname]
                total = stats["total_neighbors"]
                established = stats["established_neighbors"]
                down = stats["down_neighbors"]
                
                
                # Per-device logging removed for performance
                # Only summary and critical issues are shown
    
    # Save updated BGP history
    bgp_analyzer.save_bgp_history()
    
    # Generate web report
    output_file = "monitor-results/bgp-analysis.html"
    bgp_analyzer.export_bgp_data_for_web(output_file)
    print(f"BGP analysis report generated: {output_file}")
    
    # Generate summary for dashboard
    summary = bgp_analyzer.get_bgp_summary()
    anomalies = bgp_analyzer.detect_bgp_anomalies()
    
    print(f"\n BGP Analysis Summary:")
    print(f"  Total devices: {summary['total_devices']}")
    print(f"  Total neighbors: {summary['total_neighbors']}")
    print(f"  Established: {summary['established_neighbors']}")
    print(f"  Down/Problem: {summary['down_neighbors']}")
    print(f"  Health ratio: {summary['health_ratio']:.1f}%")
    print(f"  Anomalies detected: {len(anomalies)}")
    
    # Show critical issues
    critical_anomalies = [a for a in anomalies if a['severity'] == 'critical']
    if critical_anomalies:
        print(f"\n🚨 Critical BGP Issues:")
        for anomaly in critical_anomalies[:5]:  # Show first 5
            print(f"  • {anomaly['device']}: {anomaly['neighbor']} - {anomaly['message']}")

if __name__ == "__main__":
    import logging
    
    # Setup logging
    logging.basicConfig(
        level=logging.INFO,
        format='[%(asctime)s] %(message)s',
        handlers=[
            logging.FileHandler('monitor-results/bgp_analyzer.log'),
            logging.StreamHandler()
        ]
    )
    
    logging.info("Starting BGP data processing")
    
    try:
        process_bgp_data_files()
        logging.info("BGP data processing completed")
    except Exception as e:
        logging.error(f"BGP data processing failed: {e}")
        sys.exit(1)
