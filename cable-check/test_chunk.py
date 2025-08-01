#!/usr/bin/env python3
"""
BGP Neighbor Health Analyzer for LLDPq Enhanced Monitoring

Analyzes BGP neighbor status, detects problems, and provides insights
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
                        
                        neighbors.append(neighbor)
                        
                    except (ValueError, IndexError) as e:
                        print(f"Error parsing BGP neighbor line: {line}, Error: {e}")
                        continue
        
        return neighbors
    
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
            neighbor_dict['state'] = neighbor.state.value  # Convert enum to string
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
                        "state": neighbor.state.value,
                        "health": health.value,
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
                        "message": f"BGP neighbor {neighbor.neighbor_name} is in {neighbor.state.value.upper()} state",
                        "details": {
                            "state": neighbor.state.value,
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
                            "state": neighbor.state.value
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
                            "state": neighbor.state.value
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
        }
        
        .sortable:hover {{
            background-color: #f5f5f5;
        }
        
        .sort-arrow {{
            font-size: 10px;
            color: #999;
            margin-left: 5px;
            opacity: 0.5;
        }
        

if __name__ == '__main__':
    pass

