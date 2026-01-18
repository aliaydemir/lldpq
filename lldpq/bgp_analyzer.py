#!/usr/bin/env python3
"""
BGP Neighbor Health Analyzer for LLDPq Enhanced Monitoring

Analyzes BGP neighbor status, detects problems, and provides insights

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
import time
from datetime import datetime, timedelta
from enum import Enum
from typing import Dict, List, Any, Optional, NamedTuple
from dataclasses import dataclass

class BGPState(Enum):
    """BGP neighbor states"""
    ESTABLISHED = "established"
    IDLE = "idle"
    ACTIVE = "active"
    CONNECT = "connect"
    OPENSENT = "opensent"
    OPENCONFIRM = "openconfirm"
    UNKNOWN = "unknown"

class BGPHealth(Enum):
    """BGP neighbor health levels"""
    EXCELLENT = "excellent"
    GOOD = "good"
    WARNING = "warning"
    CRITICAL = "critical"
    UNKNOWN = "unknown"

def get_enum_value(obj):
    """Safely get value from enum or return string as-is"""
    if hasattr(obj, 'value'):
        return obj.value
    return str(obj)

@dataclass
class BGPNeighbor:
    """BGP neighbor information"""
    hostname: str
    neighbor_name: str
    neighbor_ip: str
    version: int
    asn: int
    messages_received: int
    messages_sent: int
    table_version: int
    in_queue: int
    out_queue: int
    uptime: str
    state: BGPState
    prefixes_received: int
    prefixes_sent: int
    description: str
    interface: Optional[str] = None

class BGPAnalyzer:
    """BGP neighbor health and status analyzer"""
    
    # BGP health thresholds
    DEFAULT_THRESHOLDS = {
        "critical_down_hours": 1.0,        # Critical if down > 1 hour
        "warning_down_minutes": 30,        # Warning if down > 30 minutes
        "high_queue_threshold": 10,        # Warning if queue > 10
        "low_prefix_threshold": 1,         # Warning if prefixes < 1
        "uptime_stability_days": 1,        # Expect > 1 day uptime for good health
        "message_ratio_threshold": 0.8,    # Warning if sent/received ratio < 0.8
        "history_retention_hours": 24       # Keep 24 hours of historical data
    }
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.bgp_history = {}  # hostname -> BGP historical data
        self.current_bgp_stats = {}  # hostname -> current BGP neighbors
        self.thresholds = self.DEFAULT_THRESHOLDS.copy()
        
        # Ensure bgp-data directory exists
        os.makedirs(f"{self.data_dir}/bgp-data", exist_ok=True)
        
        # Load historical data
        self.load_bgp_history()
    
    def load_bgp_history(self):
        """Load historical BGP data"""
        try:
            with open(f"{self.data_dir}/bgp_history.json", "r") as f:
                data = json.load(f)
                self.bgp_history = data.get("bgp_history", {})
                self.current_bgp_stats = data.get("current_bgp_stats", {})
                
                # Clean old data (older than retention period)
                self.cleanup_old_history()
        except (FileNotFoundError, json.JSONDecodeError):
            print("No previous BGP history found, starting fresh")
    
    def save_bgp_history(self):
        """Save BGP history to file"""
        try:
            data = {
                "bgp_history": self.bgp_history,
                "current_bgp_stats": self.current_bgp_stats,
                "last_update": time.time()
            }
            with open(f"{self.data_dir}/bgp_history.json", "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Error saving BGP history: {e}")
    
    def cleanup_old_history(self):
        """Remove history entries older than retention period"""
        current_time = time.time()
        retention_seconds = self.thresholds["history_retention_hours"] * 3600
        
        for hostname in list(self.bgp_history.keys()):
            if hostname in self.bgp_history:
                filtered_entries = []
                for entry in self.bgp_history[hostname]:
                    timestamp = entry.get('timestamp', 0)
                    
                    # Handle different timestamp formats
                    try:
                        if isinstance(timestamp, str):
                            # Parse ISO format: '2025-08-01T03:26:51.970342'
                            if 'T' in timestamp:
                                entry_time = datetime.fromisoformat(timestamp.replace('Z', '+00:00')).timestamp()
                            else:
                                entry_time = float(timestamp)
                        else:
                            entry_time = float(timestamp)
                        
                        if current_time - entry_time <= retention_seconds:
                            filtered_entries.append(entry)
                    except (ValueError, TypeError):
                        # Skip entries with invalid timestamps
                        continue
                
                self.bgp_history[hostname] = filtered_entries
                
                # Remove hostname if no history left
                if not self.bgp_history[hostname]:
                    del self.bgp_history[hostname]
    
    def parse_bgp_output(self, bgp_data: str) -> List[BGPNeighbor]:
        """Parse BGP neighbor output from vtysh command"""
        neighbors = []
        neighbor_dict = {}  # Track unique neighbors by IP, keep last seen
        
        lines = bgp_data.strip().split('\n')
        current_vrf = "default"
        local_asn = None
        
        for i, line in enumerate(lines):
            line = line.strip()
            
            # Extract VRF information
            vrf_match = re.search(r'Summary \(VRF\s+([^\)]+)\)', line)
            if vrf_match:
                current_vrf = vrf_match.group(1)
                continue
            
            # Extract local AS number
            asn_match = re.search(r'local AS number (\d+)', line)
            if asn_match:
                local_asn = int(asn_match.group(1))
                continue
            
            # Parse neighbor entries (skip header lines)
            if re.match(r'^[A-Za-z0-9._-]+.*\s+\d+\s+\d+\s+\d+\s+\d+', line):
                parts = line.split()
                if len(parts) >= 10:

                    try:
                        neighbor_name = parts[0]
                        version = int(parts[1])
                        neighbor_asn = int(parts[2])
                        msg_rcvd = int(parts[3])
                        msg_sent = int(parts[4])
                        tbl_ver = int(parts[5])
                        in_q = int(parts[6])
                        out_q = int(parts[7])
                        uptime = parts[8]
                        
                        # Parse state and prefix count
                        state_pfx = parts[9] if len(parts) > 9 else "Unknown"
                        pfx_sent = int(parts[10]) if len(parts) > 10 else 0
                        description = parts[11] if len(parts) > 11 else "N/A"
                        
                        # Determine state and prefix count
                        if state_pfx.lower() in ['idle', 'active', 'connect']:
                            state = BGPState(state_pfx.lower())
                            pfx_rcvd = 0
                        else:
                            state = BGPState.ESTABLISHED
                            try:
                                pfx_rcvd = int(state_pfx)
                            except ValueError:
                                pfx_rcvd = 0
                        
                        # Extract interface from neighbor name if present
                        interface = None
                        interface_match = re.search(r'\(([^)]+)\)', neighbor_name)
                        if interface_match:
                            interface = interface_match.group(1)
                            neighbor_ip = neighbor_name.split('(')[0]
                        else:
                            neighbor_ip = neighbor_name
                        
                        # Store neighbor (overwrite if duplicate IP found - keep last seen)
                        neighbor = BGPNeighbor(
                            hostname="",  # Will be set by caller
                            neighbor_name=neighbor_name,
                            neighbor_ip=neighbor_ip,
                            version=version,
                            asn=neighbor_asn,
                            messages_received=msg_rcvd,
                            messages_sent=msg_sent,
                            table_version=tbl_ver,
                            in_queue=in_q,
                            out_queue=out_q,
                            uptime=uptime,
                            state=state,
                            prefixes_received=pfx_rcvd,
                            prefixes_sent=pfx_sent,
                            description=description,
                            interface=interface
                        )
                        
                        # Use neighbor IP as unique key, overwrite duplicates
                        neighbor_dict[neighbor_name] = neighbor
                        
                    except (ValueError, IndexError) as e:
                        print(f"Error parsing BGP neighbor line: {line}, Error: {e}")
                        continue
        
        # Return unique neighbors (duplicates by IP are filtered out)
        return list(neighbor_dict.values())
    
    def assess_neighbor_health(self, neighbor: BGPNeighbor) -> BGPHealth:
        """Assess health of a BGP neighbor"""
        
        # Critical: Neighbor in Idle, Active, or Connect state
        if neighbor.state in [BGPState.IDLE, BGPState.ACTIVE, BGPState.CONNECT]:
            return BGPHealth.CRITICAL
        
        # Unknown state
        if neighbor.state == BGPState.UNKNOWN:
            return BGPHealth.UNKNOWN
        
        # For established neighbors, check other metrics
        if neighbor.state == BGPState.ESTABLISHED:
            issues = 0
            
            # Check queue depths
            if neighbor.in_queue > self.thresholds["high_queue_threshold"] or \
               neighbor.out_queue > self.thresholds["high_queue_threshold"]:
                issues += 1
            
            # Check prefix counts
            if neighbor.prefixes_received < self.thresholds["low_prefix_threshold"]:
                issues += 1
            
            # Check message ratio (basic health indicator)
            if neighbor.messages_sent > 0 and neighbor.messages_received > 0:
                ratio = min(neighbor.messages_sent, neighbor.messages_received) / \
                       max(neighbor.messages_sent, neighbor.messages_received)
                if ratio < self.thresholds["message_ratio_threshold"]:
                    issues += 1
            
            # Determine health based on issues
            if issues == 0:
                return BGPHealth.EXCELLENT
            elif issues == 1:
                return BGPHealth.GOOD
            else:
                return BGPHealth.WARNING
        
        # Other connecting states
        return BGPHealth.WARNING
    
    def parse_uptime(self, uptime_str: str) -> Optional[timedelta]:
        """Parse BGP uptime string to timedelta"""
        try:
            # Handle different uptime formats: "1d23h", "23:45:12", "never"
            if uptime_str.lower() == "never":
                return timedelta(0)
            
            # Format: "01w2d22h" 
            if 'w' in uptime_str or 'd' in uptime_str or 'h' in uptime_str:
                total_seconds = 0
                
                # Extract weeks
                week_match = re.search(r'(\d+)w', uptime_str)
                if week_match:
                    total_seconds += int(week_match.group(1)) * 7 * 24 * 3600
                
                # Extract days
                day_match = re.search(r'(\d+)d', uptime_str)
                if day_match:
                    total_seconds += int(day_match.group(1)) * 24 * 3600
                
                # Extract hours
                hour_match = re.search(r'(\d+)h', uptime_str)
                if hour_match:
                    total_seconds += int(hour_match.group(1)) * 3600
                
                # Extract minutes
                min_match = re.search(r'(\d+)m', uptime_str)
                if min_match:
                    total_seconds += int(min_match.group(1)) * 60
                
                return timedelta(seconds=total_seconds)
            
            # Format: "23:45:12"
            if ':' in uptime_str:
                time_parts = uptime_str.split(':')
                if len(time_parts) == 3:
                    hours = int(time_parts[0])
                    minutes = int(time_parts[1])
                    seconds = int(time_parts[2])
                    return timedelta(hours=hours, minutes=minutes, seconds=seconds)
            
            return None
            
        except Exception:
            return None
    
    def update_bgp_stats(self, hostname: str, bgp_data: str):
        """Update BGP statistics for a device"""
        neighbors = self.parse_bgp_output(bgp_data)
        
        # Set hostname for all neighbors
        for neighbor in neighbors:
            neighbor.hostname = hostname
        
        # Update current stats (convert enums to strings for JSON serialization)
        neighbor_dicts = []
        for neighbor in neighbors:
            neighbor_dict = neighbor.__dict__.copy()
            neighbor_dict['state'] = get_enum_value(neighbor.state)
            neighbor_dicts.append(neighbor_dict)
        
        self.current_bgp_stats[hostname] = {
            "neighbors": neighbor_dicts,
            "total_neighbors": len(neighbors),
            "established_neighbors": len([n for n in neighbors if n.state == BGPState.ESTABLISHED]),
            "down_neighbors": len([n for n in neighbors if n.state in [BGPState.IDLE, BGPState.ACTIVE, BGPState.CONNECT]]),
            "last_update": datetime.now().isoformat()
        }
        
        # Add to history (keep last 50 entries per device)
        if hostname not in self.bgp_history:
            self.bgp_history[hostname] = []
        
        history_entry = {
            "timestamp": datetime.now().isoformat(),
            "total_neighbors": len(neighbors),
            "established_count": len([n for n in neighbors if n.state == BGPState.ESTABLISHED]),
            "down_count": len([n for n in neighbors if n.state in [BGPState.IDLE, BGPState.ACTIVE, BGPState.CONNECT]]),
            "neighbors": neighbor_dicts  # Use the same serialized data
        }
        
        self.bgp_history[hostname].append(history_entry)
        
        # Keep only last 50 entries
        if len(self.bgp_history[hostname]) > 50:
            self.bgp_history[hostname] = self.bgp_history[hostname][-50:]
    
    def get_bgp_summary(self) -> Dict[str, Any]:
        """Get network-wide BGP summary"""
        total_devices = len(self.current_bgp_stats)
        total_neighbors = sum(stats["total_neighbors"] for stats in self.current_bgp_stats.values())
        total_established = sum(stats["established_neighbors"] for stats in self.current_bgp_stats.values())
        total_down = sum(stats["down_neighbors"] for stats in self.current_bgp_stats.values())
        
        # Get problem neighbors
        problem_neighbors = []
        for hostname, stats in self.current_bgp_stats.items():
            for neighbor_data in stats["neighbors"]:
                # Handle both enum and string state values
                neighbor_dict = neighbor_data.copy()
                if isinstance(neighbor_dict['state'], str):
                    neighbor_dict['state'] = BGPState(neighbor_dict['state'])
                
                neighbor = BGPNeighbor(**neighbor_dict)
                health = self.assess_neighbor_health(neighbor)
                if health in [BGPHealth.CRITICAL, BGPHealth.WARNING]:
                    problem_neighbors.append({
                        "hostname": hostname,
                        "neighbor": neighbor.neighbor_name,
                        "state": get_enum_value(neighbor.state),
                        "health": get_enum_value(health),
                        "uptime": neighbor.uptime
                    })
        
        return {
            "total_devices": total_devices,
            "total_neighbors": total_neighbors,
            "established_neighbors": total_established,
            "down_neighbors": total_down,
            "problem_neighbors": problem_neighbors,
            "health_ratio": (total_established / total_neighbors * 100) if total_neighbors > 0 else 0,
            "timestamp": datetime.now().isoformat()
        }
    
    def detect_bgp_anomalies(self) -> List[Dict[str, Any]]:
        """Detect BGP anomalies and problems"""
        anomalies = []
        
        for hostname, stats in self.current_bgp_stats.items():
            for neighbor_data in stats["neighbors"]:
                neighbor = BGPNeighbor(**neighbor_data)
                health = self.assess_neighbor_health(neighbor)
                
                # Critical: Down neighbors
                if neighbor.state in [BGPState.IDLE, BGPState.ACTIVE, BGPState.CONNECT]:
                    anomalies.append({
                        "device": hostname,
                        "neighbor": neighbor.neighbor_name,
                        "type": "BGP_NEIGHBOR_DOWN",
                        "severity": "critical",
                        "message": f"BGP neighbor {neighbor.neighbor_name} is in {get_enum_value(neighbor.state).upper()} state",
                        "details": {
                            "state": get_enum_value(neighbor.state),
                            "uptime": neighbor.uptime,
                            "asn": neighbor.asn,
                            "interface": neighbor.interface
                        },
                        "action": f"Check physical connectivity and BGP configuration for {neighbor.neighbor_name}"
                    })
                
                # Warning: High queue depths
                elif neighbor.in_queue > self.thresholds["high_queue_threshold"] or \
                     neighbor.out_queue > self.thresholds["high_queue_threshold"]:
                    anomalies.append({
                        "device": hostname,
                        "neighbor": neighbor.neighbor_name,
                        "type": "BGP_HIGH_QUEUE",
                        "severity": "warning",
                        "message": f"High queue depth detected: InQ={neighbor.in_queue}, OutQ={neighbor.out_queue}",
                        "details": {
                            "in_queue": neighbor.in_queue,
                            "out_queue": neighbor.out_queue,
                            "state": get_enum_value(neighbor.state)
                        },
                        "action": "Monitor for potential congestion or processing delays"
                    })
                
                # Warning: Low prefix count
                elif neighbor.prefixes_received < self.thresholds["low_prefix_threshold"] and \
                     neighbor.state == BGPState.ESTABLISHED:
                    anomalies.append({
                        "device": hostname,
                        "neighbor": neighbor.neighbor_name,
                        "type": "BGP_LOW_PREFIXES",
                        "severity": "warning",
                        "message": f"Low prefix count: receiving only {neighbor.prefixes_received} prefixes",
                        "details": {
                            "prefixes_received": neighbor.prefixes_received,
                            "prefixes_sent": neighbor.prefixes_sent,
                            "state": get_enum_value(neighbor.state)
                        },
                        "action": "Verify route advertisements and filtering policies"
                    })
        
        return anomalies
    
    def export_bgp_data_for_web(self, output_file: str):
        """Export BGP data for web display"""
        summary = self.get_bgp_summary()
        anomalies = self.detect_bgp_anomalies()
        
        html_content = f"""
<!DOCTYPE html>
<html>
<head>
    <h1></h1>
    <title>BGP Neighbor Analysis</title>
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <link rel="stylesheet" type="text/css" href="/css/select2.min.css">
    <style>
        .bgp-excellent {{ color: #4caf50; font-weight: bold; }}
        .bgp-good {{ color: #8bc34a; font-weight: bold; }}
        .bgp-warning {{ color: #ff9800; font-weight: bold; }}
        .bgp-critical {{ color: #f44336; font-weight: bold; }}
        .bgp-unknown {{ color: gray; }}
        .bgp-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        .bgp-table th, .bgp-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        .bgp-table th {{ background-color: #f2f2f2; }}
        
        /* Sortable table styling */
        .sortable {{
            cursor: pointer;
            user-select: none;
            position: relative;
            padding-right: 20px;
        }}
        
        .sortable:hover {{
            background-color: #f5f5f5;
        }}
        
        .sort-arrow {{
            font-size: 10px;
            color: #999;
            margin-left: 5px;
            opacity: 0.5;
        }}
        
        .sortable.asc .sort-arrow::before {{
            content: '▲';
            color: #b57614;
            opacity: 1;
        }}
        
        .sortable.desc .sort-arrow::before {{
            content: '▼';
            color: #b57614;
            opacity: 1;
        }}
        
        .sortable.asc .sort-arrow,
        .sortable.desc .sort-arrow {{
            opacity: 1;
        }}
        .summary-grid {{ 
            display: grid; 
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); 
            gap: 15px; 
            margin: 20px 0; 
        }}
        .summary-card {{ 
            background: #f8f9fa; 
            padding: 15px; 
            border-radius: 8px; 
            border-left: 4px solid #007bff; 
        }}
        .metric {{ font-size: 24px; font-weight: bold; }}
        .state-established {{ color: #4caf50; font-weight: bold; }}
        .state-idle {{ color: #f44336; font-weight: bold; }}
        .state-active {{ color: #f44336; font-weight: bold; }}
        .state-connect {{ color: #f44336; font-weight: bold; }}
        .uptime-good {{ color: #4caf50; }}
        .uptime-warning {{ color: #ff9800; }}
        .uptime-critical {{ color: #f44336; }}
        
        .summary-card {{
            cursor: pointer;
            transition: all 0.3s ease;
        }}
        .summary-card:hover {{
            transform: translateY(-2px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.15);
        }}
        .summary-card.active {{
            transform: translateY(-2px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.25);
            border-left-width: 6px;
        }}
        
        .filter-info {{
            text-align: center;
            padding: 10px;
            margin: 10px 0;
            background: #e8f4fd;
            border-radius: 4px;
            color: #1976d2;
            display: none;
        }}
        
        @keyframes spin {{
            from {{ transform: rotate(0deg); }}
            to {{ transform: rotate(360deg); }}
        }}
        
        /* Device Search Box */
        .device-search-container {{
            display: flex;
            align-items: center;
            gap: 8px;
        }}
        .device-search-container .select2-container {{
            min-width: 250px;
        }}
        .device-search-container .select2-container--default .select2-selection--single {{
            height: 38px;
            border: 1px solid #ccc;
            border-radius: 6px;
            display: flex;
            align-items: center;
        }}
        .device-search-container .select2-container--default .select2-selection--single .select2-selection__rendered {{
            line-height: 38px;
            color: #333;
            padding-left: 8px;
            font-size: 14px;
        }}
        .device-search-container .select2-container--default .select2-selection--single .select2-selection__arrow {{
            height: 38px;
        }}
        .device-search-container .select2-container--default .select2-selection--single .select2-selection__placeholder {{
            color: #999;
        }}
        .clear-search-btn {{
            background: #ff5722;
            color: white;
            border: none;
            padding: 8px 12px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 14px;
            display: none;
            transition: all 0.3s ease;
        }}
        .clear-search-btn:hover {{
            background: #e64a19;
        }}
    </style>
</head>
<body>
    <h1><font color="#b57614">BGP Neighbor Analysis</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
        <h2 style="margin: 0;">BGP Summary</h2>
        <div style="display: flex; gap: 10px; align-items: center;">
            <!-- Device Search Box -->
            <div class="device-search-container">
                <select id="deviceSearch" style="width: 250px;">
                    <option value="">Search Device...</option>
                </select>
                <button id="clearSearchBtn" class="clear-search-btn" onclick="clearDeviceSearch()">✕</button>
            </div>
            <button id="run-analysis" onclick="runAnalysis()" 
                    style="background: #b57614; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 14px; display: flex; align-items: center; gap: 8px; transition: all 0.3s ease;"
                    onmouseover="this.style.background='#a06612'" 
                    onmouseout="this.style.background='#b57614'">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M12,4A8,8 0 0,1 20,12A8,8 0 0,1 12,20A8,8 0 0,1 4,12A8,8 0 0,1 12,4M12,6A6,6 0 0,0 6,12A6,6 0 0,0 12,18A6,6 0 0,0 18,12A6,6 0 0,0 12,6M12,8A4,4 0 0,1 16,12A4,4 0 0,1 12,16A4,4 0 0,1 8,12A4,4 0 0,1 12,8Z"/>
                </svg>
                Run Analysis
            </button>
            <button id="download-csv" onclick="downloadCSV()" 
                    style="background: #4caf50; color: white; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 14px; display: flex; align-items: center; gap: 8px; transition: all 0.3s ease;"
                    onmouseover="this.style.background='#45a049'" 
                    onmouseout="this.style.background='#4caf50'">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor">
                    <path d="M14,2H6A2,2 0 0,0 4,4V20A2,2 0 0,0 6,22H18A2,2 0 0,0 20,20V8L14,2M18,20H6V4H13V9H18V20Z"/>
                </svg>
                Download CSV
            </button>
        </div>
    </div>
    <div class="summary-grid">
        <div class="summary-card" id="total-devices-card">
            <div class="metric" id="total-devices">{summary['total_devices']}</div>
            <div>BGP Devices</div>
        </div>
        <div class="summary-card" id="total-neighbors-card">
            <div class="metric" id="total-neighbors">{summary['total_neighbors']}</div>
            <div>Total Neighbors</div>
        </div>
        <div class="summary-card" id="established-card">
            <div class="metric bgp-excellent" id="established-neighbors">{summary['established_neighbors']}</div>
            <div>Established</div>
        </div>
        <div class="summary-card" id="down-card">
            <div class="metric bgp-critical" id="down-neighbors">{summary['down_neighbors']}</div>
            <div>Down/Problem</div>
        </div>
        <div class="summary-card" id="health-card">
            <div class="metric" id="health-ratio">{summary['health_ratio']:.1f}%</div>
            <div>Health Ratio</div>
        </div>
    </div>
"""
        
        # Collect all neighbors for display
        all_neighbors = []
        
        for hostname, stats in self.current_bgp_stats.items():
            for neighbor_data in stats["neighbors"]:
                # Handle both enum and string state values
                neighbor_dict = neighbor_data.copy()
                if isinstance(neighbor_dict['state'], str):
                    neighbor_dict['state'] = BGPState(neighbor_dict['state'])
                
                neighbor = BGPNeighbor(**neighbor_dict)
                health = self.assess_neighbor_health(neighbor)
                
                neighbor_info = {
                    'hostname': hostname,
                    'neighbor': neighbor,
                    'health': health
                }
                
                all_neighbors.append(neighbor_info)
        
        # Add anomalies section if any exist
        if anomalies:
            html_content += f"""
    <h2>📋 Detailed Issue Analysis ({len(anomalies)})</h2>
"""
            for anomaly in anomalies:
                severity_class = f"bgp-{anomaly['severity']}"
                html_content += f"""
    <div style="margin: 10px 0; padding: 10px; background-color: {'#ffebee' if anomaly['severity'] == 'critical' else '#fff3e0'}; border-left: 4px solid {'#f44336' if anomaly['severity'] == 'critical' else '#ff9800'};">
        <h4>{anomaly['device']} - {anomaly['neighbor']}</h4>
        <p><strong>Issue:</strong> {anomaly['message']}</p>
        <p><strong>Recommended Action:</strong> {anomaly['action']}</p>
    </div>
"""
        
        # BGP neighbors table (sorted by health - problems first)
        html_content += f"""
    <h2>BGP Neighbors Status ({len(all_neighbors)} total)</h2>
    <div id="filter-info" class="filter-info">
        <span id="filter-text"></span>
        <button onclick="clearFilter()" style="margin-left: 10px; padding: 2px 8px; background: #1976d2; color: white; border: none; border-radius: 3px; cursor: pointer;">Show All</button>
    </div>
    <table class="bgp-table" id="bgp-table">
        <thead>
        <tr>
            <th class="sortable" data-column="0" data-type="string">
                Device <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="1" data-type="string">
                Neighbor <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="2" data-type="port">
                Interface <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="3" data-type="bgp-state">
                State <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="4" data-type="number">
                ASN <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="5" data-type="uptime">
                Uptime <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="6" data-type="ratio">
                Prefixes RX/TX <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="7" data-type="ratio">
                Messages RX/TX <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="8" data-type="ratio">
                Queue In/Out <span class="sort-arrow">▲▼</span>
            </th>
            <th class="sortable" data-column="9" data-type="bgp-health">
                Health <span class="sort-arrow">▲▼</span>
            </th>
        </tr>
        </thead>
        <tbody id="bgp-data">
"""
        
        # Add all neighbor data (sorted by health - problems first, then good ones)
        sorted_neighbors = sorted(all_neighbors, key=lambda x: (
            0 if x['health'] == BGPHealth.CRITICAL else
            1 if x['health'] == BGPHealth.WARNING else
            2 if x['health'] == BGPHealth.GOOD else
            3 if x['health'] == BGPHealth.EXCELLENT else 4
        ))
        
        for neighbor_info in sorted_neighbors:
            neighbor = neighbor_info['neighbor']
            health = neighbor_info['health']
            hostname = neighbor_info['hostname']
            
            state_val = get_enum_value(neighbor.state)
            health_val = get_enum_value(health)
            
            state_class = f"state-{state_val}"
            health_class = f"bgp-{health_val}"
            
            html_content += f"""
        <tr data-health="{health_val}" data-state="{state_val}">
            <td>{hostname}</td>
            <td>{neighbor.neighbor_name}</td>
            <td>{neighbor.interface or 'N/A'}</td>
            <td><span class="{state_class}">{state_val.upper()}</span></td>
            <td>{neighbor.asn}</td>
            <td>{neighbor.uptime}</td>
            <td>{neighbor.prefixes_received}/{neighbor.prefixes_sent}</td>
            <td>{neighbor.messages_received}/{neighbor.messages_sent}</td>
            <td>{neighbor.in_queue}/{neighbor.out_queue}</td>
            <td><span class="{health_class}">{health_val.upper()}</span></td>
        </tr>
"""
        
        html_content += """
        </tbody>
    </table>
    
    <h2>BGP Health Thresholds</h2>
    <table class="bgp-table">
        <tr><th>Parameter</th><th>Threshold</th><th>Description</th></tr>
        <tr><td>Critical Down Time</td><td>1+ hours</td><td>Neighbor down for extended period</td></tr>
        <tr><td>High Queue Depth</td><td>10+ messages</td><td>Processing delays or congestion</td></tr>
        <tr><td>Low Prefix Count</td><td>&lt; 1 prefix</td><td>Potential route advertisement issues</td></tr>
        <tr><td>Message Ratio</td><td>&lt; 80%</td><td>Imbalanced message exchange</td></tr>
    </table>

    <!-- jQuery and Select2 for device search -->
    <script src="/css/jquery-3.5.1.min.js"></script>
    <script src="/css/select2.min.js"></script>
    
    <script>
        // Filter functionality
        let currentFilter = 'ALL';
        let allRows = [];
        let deviceSearchActive = false;
        let selectedDevice = '';
        
        document.addEventListener('DOMContentLoaded', function() {
            // Store all table rows for filtering
            allRows = Array.from(document.querySelectorAll('#bgp-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
            
            // Initialize table sorting
            initTableSorting();
            
            // Initialize device search
            populateDeviceList();
            initDeviceSearch();
        });
        
        function setupCardEvents() {
            document.getElementById('total-devices-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('total-devices').textContent) > 0) {
                    filterNeighbors('TOTAL');
                }
            });
            
            document.getElementById('total-neighbors-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('total-neighbors').textContent) > 0) {
                    filterNeighbors('TOTAL');
                }
            });
            
            document.getElementById('established-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('established-neighbors').textContent) > 0) {
                    filterNeighbors('ESTABLISHED');
                }
            });
            
            document.getElementById('down-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('down-neighbors').textContent) > 0) {
                    filterNeighbors('DOWN');
                }
            });
        }
        
        function filterNeighbors(filterType) {
            currentFilter = filterType;
            
            // Clear device search when using card filters
            if (deviceSearchActive) {
                selectedDevice = '';
                deviceSearchActive = false;
                $('#deviceSearch').val('').trigger('change');
                document.getElementById('clearSearchBtn').style.display = 'none';
            }
            
            // Clear active state from all cards
            document.querySelectorAll('.summary-card').forEach(card => {
                card.classList.remove('active');
            });
            
            let filteredRows = allRows;
            let filterText = '';
            
            if (filterType === 'ESTABLISHED') {
                filteredRows = allRows.filter(row => row.dataset.state === 'established');
                filterText = `Showing ${filteredRows.length} Established Neighbors`;
                document.getElementById('established-card').classList.add('active');
            } else if (filterType === 'DOWN') {
                filteredRows = allRows.filter(row => 
                    row.dataset.state !== 'established' || 
                    row.dataset.health === 'critical' || 
                    row.dataset.health === 'warning'
                );
                filterText = `Showing ${filteredRows.length} Down/Problem Neighbors`;
                document.getElementById('down-card').classList.add('active');
            } else if (filterType === 'TOTAL') {
                filteredRows = allRows;
                document.getElementById('total-neighbors-card').classList.add('active');
            }
            
            // Show filter info for all filters except TOTAL
            if (filterType !== 'ALL' && filterType !== 'TOTAL') {
                document.getElementById('filter-info').style.display = 'block';
                document.getElementById('filter-text').textContent = filterText;
            } else {
                document.getElementById('filter-info').style.display = 'none';
            }
            
            // Hide all rows first
            allRows.forEach(row => row.style.display = 'none');
            
            // Show filtered rows
            filteredRows.forEach(row => row.style.display = '');
        }
        
        function clearFilter() {
            currentFilter = 'ALL';
            document.querySelectorAll('.summary-card').forEach(card => {
                card.classList.remove('active');
            });
            document.getElementById('filter-info').style.display = 'none';
            
            // Also clear device search
            if (deviceSearchActive) {
                selectedDevice = '';
                deviceSearchActive = false;
                $('#deviceSearch').val('').trigger('change');
                document.getElementById('clearSearchBtn').style.display = 'none';
            }
            
            // Show all rows
            allRows.forEach(row => row.style.display = '');
        }
        
        // ===== Device Search Functions =====
        function initDeviceSearch() {
            $('#deviceSearch').select2({
                placeholder: 'Search Device...',
                allowClear: true,
                width: '250px',
                dropdownAutoWidth: true,
                matcher: function(params, data) {
                    if ($.trim(params.term) === '') return data;
                    if (typeof data.text === 'undefined') return null;
                    if (data.text.toLowerCase().indexOf(params.term.toLowerCase()) > -1) return data;
                    return null;
                }
            });
            
            $('#deviceSearch').on('select2:select', function(e) {
                const device = e.params.data.id;
                if (device) filterByDevice(device);
            });
            
            $('#deviceSearch').on('select2:clear', function(e) {
                clearDeviceSearch();
            });
        }
        
        function populateDeviceList() {
            const deviceSet = new Set();
            allRows.forEach(row => {
                // First column is the device name
                const deviceName = row.cells[0]?.textContent?.trim();
                if (deviceName) deviceSet.add(deviceName);
            });
            
            const sortedDevices = Array.from(deviceSet).sort((a, b) => 
                a.localeCompare(b, undefined, { numeric: true, sensitivity: 'base' })
            );
            
            const select = document.getElementById('deviceSearch');
            select.innerHTML = '<option value="">Search Device...</option>';
            sortedDevices.forEach(device => {
                const option = document.createElement('option');
                option.value = device;
                option.textContent = device;
                select.appendChild(option);
            });
        }
        
        function filterByDevice(deviceName) {
            if (!deviceName) return;
            
            selectedDevice = deviceName;
            deviceSearchActive = true;
            
            // Clear card-based filter
            currentFilter = 'ALL';
            document.querySelectorAll('.summary-card').forEach(card => card.classList.remove('active'));
            
            // Filter table rows
            let matchCount = 0;
            allRows.forEach(row => {
                const rowDeviceName = row.cells[0]?.textContent?.trim();
                if (rowDeviceName === deviceName) {
                    row.style.display = '';
                    matchCount++;
                } else {
                    row.style.display = 'none';
                }
            });
            
            // Show filter info
            document.getElementById('filter-info').style.display = 'block';
            document.getElementById('filter-text').textContent = 'Showing neighbors for device: ' + deviceName + ' (' + matchCount + ' neighbors)';
            document.getElementById('clearSearchBtn').style.display = 'inline-block';
        }
        
        function clearDeviceSearch() {
            selectedDevice = '';
            deviceSearchActive = false;
            $('#deviceSearch').val('').trigger('change');
            document.getElementById('clearSearchBtn').style.display = 'none';
            document.getElementById('filter-info').style.display = 'none';
            allRows.forEach(row => row.style.display = '');
        }

        // Generic table sorting functionality  
        let tableSortState = { column: -1, direction: 'asc' };
        
        function initTableSorting() {
            const headers = document.querySelectorAll('.sortable');
            headers.forEach(header => {
                header.addEventListener('click', function() {
                    const column = parseInt(this.dataset.column);
                    const type = this.dataset.type;
                    
                    // Toggle sort direction
                    if (tableSortState.column === column) {
                        tableSortState.direction = tableSortState.direction === 'asc' ? 'desc' : 'asc';
                    } else {
                        tableSortState.direction = 'asc';
                    }
                    tableSortState.column = column;
                    
                    // Update header styling
                    headers.forEach(h => h.classList.remove('asc', 'desc'));
                    this.classList.add(tableSortState.direction);
                    
                    // Sort table
                    sortBGPTable(column, tableSortState.direction, type);
                });
            });
        }
        
        function sortBGPTable(columnIndex, direction, type) {
            const table = document.getElementById('bgp-table');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.rows);
            
            rows.sort((a, b) => {
                let aVal = a.cells[columnIndex].textContent.trim();
                let bVal = b.cells[columnIndex].textContent.trim();
                
                // Extract actual text for status/health columns (remove HTML)
                if (type === 'bgp-state' || type === 'bgp-health') {
                    aVal = a.cells[columnIndex].querySelector('span')?.textContent || aVal;
                    bVal = b.cells[columnIndex].querySelector('span')?.textContent || bVal;
                }
                
                let result = 0;
                
                switch(type) {
                    case 'number':
                        result = parseInt(aVal) - parseInt(bVal);
                        break;
                    case 'port':
                        result = comparePort(aVal, bVal);
                        break;
                    case 'uptime':
                        result = compareBGPUptime(aVal, bVal);
                        break;
                    case 'bgp-state':
                        result = compareBGPState(aVal, bVal);
                        break;
                    case 'bgp-health':
                        result = compareBGPHealth(aVal, bVal);
                        break;
                    case 'ratio':
                        result = compareRatio(aVal, bVal);
                        break;
                    case 'string':
                    default:
                        result = aVal.localeCompare(bVal, undefined, { numeric: true, sensitivity: 'base' });
                        break;
                }
                
                return direction === 'desc' ? -result : result;
            });
            
            // Clear tbody and add sorted rows back
            tbody.innerHTML = '';
            rows.forEach(row => tbody.appendChild(row));
        }
        
        function comparePort(a, b) {
            if (a === 'N/A') return 1;
            if (b === 'N/A') return -1;
            
            // Handle port sorting (swp1, swp10, swp1s0, etc.)
            const extractPortNumber = (port) => {
                const match = port.match(/swp(\\d+)(?:s(\\d+))?/);
                if (match) {
                    const mainPort = parseInt(match[1]);
                    const subPort = match[2] ? parseInt(match[2]) : 0;
                    return mainPort * 1000 + subPort;
                }
                return port.localeCompare(b, undefined, { numeric: true });
            };
            
            return extractPortNumber(a) - extractPortNumber(b);
        }
        
        function compareBGPUptime(a, b) {
            if (a === 'never') return 1;
            if (b === 'never') return -1;
            
            // Parse BGP uptime format (e.g., "1d23h", "00:30:45", etc.)
            const parseUptime = (uptime) => {
                let minutes = 0;
                
                // Handle format like "1d23h", "2w3d", etc.
                const weekMatch = uptime.match(/(\\d+)w/);
                const dayMatch = uptime.match(/(\\d+)d/);
                const hourMatch = uptime.match(/(\\d+)h/);
                
                if (weekMatch) minutes += parseInt(weekMatch[1]) * 7 * 24 * 60;
                if (dayMatch) minutes += parseInt(dayMatch[1]) * 24 * 60;
                if (hourMatch) minutes += parseInt(hourMatch[1]) * 60;
                
                // Handle HH:MM:SS format
                const timeMatch = uptime.match(/(\\d+):(\\d+):(\\d+)/);
                if (timeMatch) {
                    minutes += parseInt(timeMatch[1]) * 60; // hours
                    minutes += parseInt(timeMatch[2]); // minutes
                }
                
                return minutes;
            };
            
            return parseUptime(a) - parseUptime(b);
        }
        
        function compareBGPState(a, b) {
            const priority = {
                'IDLE': 0,
                'ACTIVE': 1,
                'CONNECT': 2,
                'ESTABLISHED': 3
            };
            
            return (priority[a] || 4) - (priority[b] || 4);
        }
        
        function compareBGPHealth(a, b) {
            const priority = {
                'CRITICAL': 0,
                'WARNING': 1,
                'GOOD': 2,
                'EXCELLENT': 3
            };
            
            return (priority[a] || 4) - (priority[b] || 4);
        }
        
        function compareRatio(a, b) {
            // Parse ratio like "100/200" and compare by first number
            const getRatioValue = (ratio) => {
                const parts = ratio.split('/');
                return parseInt(parts[0]) || 0;
            };
            
            return getRatioValue(a) - getRatioValue(b);
        }

        // Run Analysis Function
        function runAnalysis() {
            const button = document.getElementById('run-analysis');
            const originalText = button.innerHTML;
            
            // Disable button and show loading
            button.disabled = true;
            button.innerHTML = `
                <svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor" style="animation: spin 1s linear infinite;">
                    <path d="M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2M12,4A8,8 0 0,1 20,12A8,8 0 0,1 12,20A8,8 0 0,1 4,12A8,8 0 0,1 12,4M12,6A6,6 0 0,0 6,12A6,6 0 0,0 12,18A6,6 0 0,0 18,12A6,6 0 0,0 12,6M12,8A4,4 0 0,1 16,12A4,4 0 0,1 12,16A4,4 0 0,1 8,12A4,4 0 0,1 12,8Z"/>
                </svg>
                Running...
            `;
            
            // Send POST request to trigger monitor
            fetch('/trigger-monitor', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                }
            })
            .then(response => response.json())
            .then(data => {
                if (data.status === 'success') {
                    console.log('✅ Monitor analysis triggered successfully');
                    // Show notification
                    const notification = document.createElement('div');
                    notification.style.cssText = `
                        position: fixed;
                        top: 20px;
                        right: 20px;
                        background: #c87f0a;
                        color: white;
                        padding: 15px 20px;
                        border-radius: 8px;
                        box-shadow: 0 4px 12px rgba(0,0,0,0.2);
                        z-index: 1000;
                        font-size: 14px;
                        max-width: 350px;
                        font-family: monospace;
                    `;
                    notification.innerHTML = `
                        <strong>✅ Monitor Analysis Started</strong><br>
                        The full system analysis is running in the background.<br>
                        <small>Page will automatically refresh in 35 seconds to show the latest results.</small>
                    `;
                    document.body.appendChild(notification);
                    // Auto-refresh page after 35 seconds
                    setTimeout(() => {
                        window.location.reload();
                    }, 35000);
                } else {
                    console.error('❌ Failed to trigger monitor analysis:', data.message);
                    alert('Failed to trigger analysis. Please try again.');
                    // Restore button
                    button.disabled = false;
                    button.innerHTML = originalText;
                }
            })
            .catch(error => {
                console.error('❌ Error triggering analysis:', error);
                alert('Error triggering analysis. Please try again.');
                // Restore button
                button.disabled = false;
                button.innerHTML = originalText;
            });
        }

        // CSV Download Function
        function downloadCSV() {
            try {
                // Get current date for filename
                const now = new Date();
                const dateStr = now.toISOString().slice(0, 10); // YYYY-MM-DD
                const timeStr = now.toTimeString().slice(0, 5).replace(':', '-'); // HH-MM
                const filename = `BGP_Analysis_Report_${dateStr}_${timeStr}.csv`;
                
                // Create CSV header
                const headers = [
                    'Device',
                    'Neighbor', 
                    'Interface',
                    'State',
                    'ASN',
                    'Uptime',
                    'Prefixes RX/TX',
                    'Messages RX/TX',
                    'Queue In/Out',
                    'Health'
                ];
                
                let csvContent = headers.join(',') + '\\n';
                
                // Get table data (only visible rows)
                const table = document.getElementById('bgp-table');
                const tbody = table.querySelector('tbody');
                const rows = tbody.querySelectorAll('tr');
                
                // Add summary stats as comments
                csvContent += `# BGP Analysis Summary Report\\n`;
                csvContent += `# Generated: ${now.toLocaleString()}\\n`;
                csvContent += `# Total Devices: ${document.getElementById('total-devices').textContent}\\n`;
                csvContent += `# Total Neighbors: ${document.getElementById('total-neighbors').textContent}\\n`;
                csvContent += `# Established: ${document.getElementById('established-neighbors').textContent}\\n`;
                csvContent += `# Down/Problem: ${document.getElementById('down-neighbors').textContent}\\n`;
                csvContent += `# Health Ratio: ${document.getElementById('health-ratio').textContent}\\n`;
                csvContent += `#\\n`;
                
                // Process each visible row
                rows.forEach(row => {
                    if (row.style.display !== 'none') {
                        const cells = row.querySelectorAll('td');
                        if (cells.length >= 10) {
                            const rowData = [
                                cells[0].textContent.trim(), // Device
                                cells[1].textContent.trim(), // Neighbor
                                cells[2].textContent.trim(), // Interface
                                cells[3].textContent.trim(), // State
                                cells[4].textContent.trim(), // ASN
                                cells[5].textContent.trim(), // Uptime
                                cells[6].textContent.trim(), // Prefixes RX/TX
                                cells[7].textContent.trim(), // Messages RX/TX
                                cells[8].textContent.trim(), // Queue In/Out
                                cells[9].textContent.trim()  // Health
                            ];
                            
                            // Escape commas and quotes in data
                            const escapedData = rowData.map(field => {
                                if (field.includes(',') || field.includes('"') || field.includes('\\n')) {
                                    return '"' + field.replace(/"/g, '""') + '"';
                                }
                                return field;
                            });
                            
                            csvContent += escapedData.join(',') + '\\n';
                        }
                    }
                });
                
                // Create and trigger download
                const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
                const link = document.createElement('a');
                link.href = URL.createObjectURL(blob);
                link.download = filename;
                link.style.display = 'none';
                document.body.appendChild(link);
                link.click();
                document.body.removeChild(link);
                
                console.log(`✅ CSV downloaded: ${filename}`);
                
            } catch (error) {
                console.error('❌ Error generating CSV:', error);
                alert('Error generating CSV file. Please try again.');
            }
        }

    </script>
</body>
</html>
"""
        
        with open(output_file, "w") as f:
            f.write(html_content)

if __name__ == "__main__":
    analyzer = BGPAnalyzer()
    print("BGP analyzer initialized")
    print(f"Monitoring {len(analyzer.current_bgp_stats)} devices")
