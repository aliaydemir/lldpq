#!/usr/bin/env python3
"""
LLDP Connection Health Analyzer for LLDPq Enhanced Monitoring

Analyzes LLDP neighbor status, detects problems, and provides insights
"""

import os
import re
import json
import time
from datetime import datetime, timedelta
from enum import Enum
from typing import Dict, List, Any, Optional, NamedTuple
from dataclasses import dataclass

class LLDPConnectionState(Enum):
    """LLDP connection states"""
    ESTABLISHED = "established"
    MISSING = "missing"
    UNEXPECTED = "unexpected"
    MISMATCH = "mismatch"
    UNKNOWN = "unknown"

class LLDPHealth(Enum):
    """LLDP connection health levels"""
    EXCELLENT = "excellent"
    GOOD = "good"
    WARNING = "warning"
    CRITICAL = "critical"
    UNKNOWN = "unknown"

@dataclass
class LLDPConnection:
    """LLDP connection information"""
    source_device: str
    source_interface: str
    neighbor_device: str
    neighbor_interface: str
    state: LLDPConnectionState
    expected_neighbor: str = None
    expected_interface: str = None
    last_seen: datetime = None
    discovery_time: str = None
    
class LLDPAnalyzer:
    """Main LLDP analyzer class"""
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.current_lldp_stats = {}
        self.historical_data = {}
        self.topology_expectations = {}
        
        # Health assessment thresholds
        self.thresholds = {
            'missing_connection_critical_hours': 2,
            'unexpected_connection_warning_count': 3,
            'mismatch_critical_threshold': 1,
            'connection_stability_threshold': 0.95
        }
        
        # Load existing data
        self.load_topology_expectations()
        self.load_historical_data()
    
    def load_topology_expectations(self):
        """Load expected topology from topology.dot file"""
        topology_file = "topology.dot"
        if not os.path.exists(topology_file):
            print(f"Warning: {topology_file} not found")
            return
            
        try:
            with open(topology_file, 'r') as f:
                content = f.read()
                
            # Parse topology.dot connections
            connections = re.findall(r'"([^"]+):([^"]+)"\s*--\s*"([^"]+):([^"]+)"', content)
            
            for src_dev, src_port, dst_dev, dst_port in connections:
                if src_dev not in self.topology_expectations:
                    self.topology_expectations[src_dev] = {}
                self.topology_expectations[src_dev][src_port] = {
                    'neighbor_device': dst_dev,
                    'neighbor_interface': dst_port
                }
                
                if dst_dev not in self.topology_expectations:
                    self.topology_expectations[dst_dev] = {}
                self.topology_expectations[dst_dev][dst_port] = {
                    'neighbor_device': src_dev,
                    'neighbor_interface': src_port
                }
                
        except Exception as e:
            print(f"Error loading topology expectations: {e}")
    
    def load_historical_data(self):
        """Load historical LLDP data"""
        history_file = os.path.join(self.data_dir, "lldp_history.json")
        if os.path.exists(history_file):
            try:
                with open(history_file, 'r') as f:
                    self.historical_data = json.load(f)
            except Exception as e:
                print(f"Error loading historical data: {e}")
                self.historical_data = {}
    
    def save_historical_data(self):
        """Save historical LLDP data"""
        history_file = os.path.join(self.data_dir, "lldp_history.json")
        try:
            with open(history_file, 'w') as f:
                json.dump(self.historical_data, f, indent=2, default=str)
        except Exception as e:
            print(f"Error saving historical data: {e}")
    
    def parse_lldp_output(self, filename):
        """Parse LLDP neighbor output file"""
        neighbors = []
        try:
            with open(filename, 'r') as file:
                content = file.read()
                interfaces = re.split(r'-------------------------------------------------------------------------------', content)[1:-1]
                
                for interface in interfaces:
                    data = {}
                    interface_match = re.search(r'Interface:\s+(\S+)', interface)
                    sys_name_match = re.search(r'SysName:\s+([^\n]+)', interface)
                    
                    if "Cumulus" in interface:
                        port_id_match = re.search(r'PortID:\s+ifname\s+(\S+)', interface)
                    else:
                        port_id_match = re.search(r'PortDescr:\s+(.+)', interface)
                    
                    if interface_match and sys_name_match and port_id_match:
                        sys_name = sys_name_match.group(1).strip()
                        if not "Cumulus" in interface:
                            sys_name = sys_name.split(".cm.cluster")[0]
                        
                        data['interface'] = interface_match.group(1).strip(',')
                        data['sys_name'] = sys_name
                        data['port_id'] = port_id_match.group(1).strip()
                        neighbors.append(data)
                        
        except Exception as e:
            print(f"Error parsing {filename}: {e}")
            
        return neighbors
    
    def analyze_device_connections(self, device_name, neighbors):
        """Analyze connections for a specific device"""
        connections = []
        current_time = datetime.now()
        
        # Check expected connections
        expected_connections = self.topology_expectations.get(device_name, {})
        
        for interface, expectation in expected_connections.items():
            expected_neighbor = expectation['neighbor_device']
            expected_interface = expectation['neighbor_interface']
            
            # Find actual neighbor
            actual_neighbor = next((n for n in neighbors if n['interface'] == interface), None)
            
            if not actual_neighbor:
                state = LLDPConnectionState.MISSING
                connection = LLDPConnection(
                    source_device=device_name,
                    source_interface=interface,
                    neighbor_device="MISSING",
                    neighbor_interface="MISSING",
                    state=state,
                    expected_neighbor=expected_neighbor,
                    expected_interface=expected_interface,
                    last_seen=current_time
                )
            elif (actual_neighbor['sys_name'] == expected_neighbor and 
                  actual_neighbor['port_id'] == expected_interface):
                state = LLDPConnectionState.ESTABLISHED
                connection = LLDPConnection(
                    source_device=device_name,
                    source_interface=interface,
                    neighbor_device=actual_neighbor['sys_name'],
                    neighbor_interface=actual_neighbor['port_id'],
                    state=state,
                    expected_neighbor=expected_neighbor,
                    expected_interface=expected_interface,
                    last_seen=current_time
                )
            else:
                state = LLDPConnectionState.MISMATCH
                connection = LLDPConnection(
                    source_device=device_name,
                    source_interface=interface,
                    neighbor_device=actual_neighbor['sys_name'],
                    neighbor_interface=actual_neighbor['port_id'],
                    state=state,
                    expected_neighbor=expected_neighbor,
                    expected_interface=expected_interface,
                    last_seen=current_time
                )
            
            connections.append(connection)
        
        # Check for unexpected connections
        for neighbor in neighbors:
            if neighbor['interface'] == 'eth0' or neighbor['port_id'] == 'eth0':
                continue
                
            # Skip if this interface is already covered in expected connections
            if neighbor['interface'] not in expected_connections:
                state = LLDPConnectionState.UNEXPECTED
                connection = LLDPConnection(
                    source_device=device_name,
                    source_interface=neighbor['interface'],
                    neighbor_device=neighbor['sys_name'],
                    neighbor_interface=neighbor['port_id'],
                    state=state,
                    last_seen=current_time
                )
                connections.append(connection)
        
        return connections
    
    def assess_connection_health(self, connection: LLDPConnection) -> LLDPHealth:
        """Assess health of a single connection"""
        if connection.state == LLDPConnectionState.ESTABLISHED:
            return LLDPHealth.EXCELLENT
        elif connection.state == LLDPConnectionState.UNEXPECTED:
            return LLDPHealth.WARNING
        elif connection.state == LLDPConnectionState.MISMATCH:
            return LLDPHealth.CRITICAL
        elif connection.state == LLDPConnectionState.MISSING:
            return LLDPHealth.CRITICAL
        else:
            return LLDPHealth.UNKNOWN
    
    def update_lldp_stats(self, device_name, lldp_data_file):
        """Update LLDP statistics for a device"""
        neighbors = self.parse_lldp_output(lldp_data_file)
        connections = self.analyze_device_connections(device_name, neighbors)
        
        # Calculate statistics
        total_connections = len(connections)
        established = len([c for c in connections if c.state == LLDPConnectionState.ESTABLISHED])
        missing = len([c for c in connections if c.state == LLDPConnectionState.MISSING])
        mismatched = len([c for c in connections if c.state == LLDPConnectionState.MISMATCH])
        unexpected = len([c for c in connections if c.state == LLDPConnectionState.UNEXPECTED])
        
        self.current_lldp_stats[device_name] = {
            'device_name': device_name,
            'total_connections': total_connections,
            'established_connections': established,
            'missing_connections': missing,
            'mismatched_connections': mismatched,
            'unexpected_connections': unexpected,
            'connections': [
                {
                    'source_device': c.source_device,
                    'source_interface': c.source_interface,
                    'neighbor_device': c.neighbor_device,
                    'neighbor_interface': c.neighbor_interface,
                    'state': c.state.value,
                    'expected_neighbor': c.expected_neighbor,
                    'expected_interface': c.expected_interface,
                    'health': self.assess_connection_health(c).value
                }
                for c in connections
            ],
            'last_updated': datetime.now().isoformat()
        }
    
    def detect_lldp_anomalies(self) -> List[Dict]:
        """Detect LLDP anomalies across all devices"""
        anomalies = []
        
        for device_name, stats in self.current_lldp_stats.items():
            # Check for missing connections
            if stats['missing_connections'] > 0:
                for conn in stats['connections']:
                    if conn['state'] == 'missing':
                        anomalies.append({
                            'device': device_name,
                            'interface': conn['source_interface'],
                            'severity': 'critical',
                            'type': 'missing_connection',
                            'message': f"Expected connection to {conn['expected_neighbor']}:{conn['expected_interface']} is missing",
                            'action': "Check physical cabling and LLDP daemon status on both devices"
                        })
            
            # Check for mismatched connections
            if stats['mismatched_connections'] > 0:
                for conn in stats['connections']:
                    if conn['state'] == 'mismatch':
                        anomalies.append({
                            'device': device_name,
                            'interface': conn['source_interface'],
                            'severity': 'critical',
                            'type': 'connection_mismatch',
                            'message': f"Connection mismatch: Expected {conn['expected_neighbor']}:{conn['expected_interface']}, Found {conn['neighbor_device']}:{conn['neighbor_interface']}",
                            'action': "Verify physical cabling matches topology documentation"
                        })
            
            # Check for unexpected connections
            if stats['unexpected_connections'] >= self.thresholds['unexpected_connection_warning_count']:
                anomalies.append({
                    'device': device_name,
                    'interface': 'multiple',
                    'severity': 'warning',
                    'type': 'unexpected_connections',
                    'message': f"Found {stats['unexpected_connections']} unexpected LLDP connections",
                    'action': "Review topology documentation and update expected connections"
                })
        
        return anomalies
    
    def get_lldp_summary(self) -> Dict:
        """Get overall LLDP summary statistics"""
        total_devices = len(self.current_lldp_stats)
        total_connections = sum(stats['total_connections'] for stats in self.current_lldp_stats.values())
        total_established = sum(stats['established_connections'] for stats in self.current_lldp_stats.values())
        total_missing = sum(stats['missing_connections'] for stats in self.current_lldp_stats.values())
        total_mismatched = sum(stats['mismatched_connections'] for stats in self.current_lldp_stats.values())
        total_unexpected = sum(stats['unexpected_connections'] for stats in self.current_lldp_stats.values())
        
        health_ratio = (total_established / total_connections * 100) if total_connections > 0 else 0
        
        return {
            'total_devices': total_devices,
            'total_connections': total_connections,
            'established_connections': total_established,
            'missing_connections': total_missing,
            'mismatched_connections': total_mismatched,
            'unexpected_connections': total_unexpected,
            'health_ratio': health_ratio
        }
    
    def export_lldp_data_for_web(self, output_file):
        """Export LLDP analysis to HTML format"""
        summary = self.get_lldp_summary()
        anomalies = self.detect_lldp_anomalies()
        
        # Determine overall health status
        if summary['health_ratio'] >= 95:
            overall_status = "EXCELLENT"
            status_color = "#4caf50"
        elif summary['health_ratio'] >= 85:
            overall_status = "GOOD" 
            status_color = "#8bc34a"
        elif summary['health_ratio'] >= 70:
            overall_status = "WARNING"
            status_color = "#ff9800"
        else:
            overall_status = "CRITICAL"
            status_color = "#f44336"
        
        html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>LLDP Connection Analysis</title>
    <link rel="shortcut icon" href="/png/favicon.ico">
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>
        .lldp-container {{ max-width: 1400px; margin: 0 auto; padding: 20px; }}
        .lldp-header {{ text-align: center; margin-bottom: 30px; }}
        .lldp-status {{ font-size: 24px; font-weight: bold; color: {status_color}; }}
        .lldp-summary {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }}
        .summary-card {{ background: #f8f9fa; border-left: 4px solid #007bff; padding: 15px; border-radius: 4px; }}
        .summary-number {{ font-size: 28px; font-weight: bold; color: #007bff; }}
        .summary-label {{ color: #6c757d; font-size: 14px; }}
        .lldp-table {{ width: 100%; border-collapse: collapse; margin-top: 20px; }}
        .lldp-table th, .lldp-table td {{ padding: 8px 12px; text-align: left; border-bottom: 1px solid #ddd; }}
        .lldp-table th {{ background-color: #f8f9fa; font-weight: bold; }}
        .state-established {{ color: #4caf50; font-weight: bold; }}
        .state-missing {{ color: #f44336; font-weight: bold; }}
        .state-mismatch {{ color: #f44336; font-weight: bold; }}
        .state-unexpected {{ color: #ff9800; font-weight: bold; }}
        .lldp-excellent {{ color: #4caf50; font-weight: bold; }}
        .lldp-good {{ color: #8bc34a; font-weight: bold; }}
        .lldp-warning {{ color: #ff9800; font-weight: bold; }}
        .lldp-critical {{ color: #f44336; font-weight: bold; }}
        .anomaly-card {{ margin: 10px 0; padding: 10px; border-radius: 4px; }}
        .anomaly-critical {{ background-color: #ffebee; border-left: 4px solid #f44336; }}
        .anomaly-warning {{ background-color: #fff3e0; border-left: 4px solid #ff9800; }}
        .timestamp {{ color: #6c757d; font-size: 12px; }}
    </style>
</head>
<body>
    <div class="lldp-container">
        <div class="lldp-header">
            <h1><font color="#b57614">LLDP Connection Analysis</font></h1>
            <div class="lldp-status">Overall Status: {overall_status}</div>
            <div class="timestamp">Generated on {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</div>
        </div>
        
        <div class="lldp-summary">
            <div class="summary-card">
                <div class="summary-number">{summary['total_devices']}</div>
                <div class="summary-label">Monitored Devices</div>
            </div>
            <div class="summary-card">
                <div class="summary-number">{summary['total_connections']}</div>
                <div class="summary-label">Total Connections</div>
            </div>
            <div class="summary-card">
                <div class="summary-number">{summary['established_connections']}</div>
                <div class="summary-label">Established</div>
            </div>
            <div class="summary-card">
                <div class="summary-number">{summary['missing_connections'] + summary['mismatched_connections']}</div>
                <div class="summary-label">Problems</div>
            </div>
            <div class="summary-card">
                <div class="summary-number">{summary['health_ratio']:.1f}%</div>
                <div class="summary-label">Health Ratio</div>
            </div>
        </div>
"""
        
        # Add all connections data to the end for easy processing
        all_connections = []
        for hostname, stats in self.current_lldp_stats.items():
            for conn_data in stats['connections']:
                connection_info = {
                    'hostname': hostname,
                    'connection': conn_data
                }
                all_connections.append(connection_info)
        
        # Add anomalies section if any exist
        if anomalies:
            html_content += f"""
        <h2>Connection Issues Detected ({len(anomalies)})</h2>
"""
            for anomaly in anomalies:
                severity_class = f"anomaly-{anomaly['severity']}"
                html_content += f"""
        <div class="{severity_class}">
            <h4>{anomaly['device']} - {anomaly['interface']}</h4>
            <p><strong>Issue:</strong> {anomaly['message']}</p>
            <p><strong>Recommended Action:</strong> {anomaly['action']}</p>
        </div>
"""
        
        # LLDP connections table (sorted by health - problems first)
        html_content += f"""
        <h2>LLDP Connections Status ({len(all_connections)} total)</h2>
        <table class="lldp-table">
            <tr>
                <th>Device</th>
                <th>Interface</th>
                <th>Neighbor Device</th>
                <th>Neighbor Interface</th>
                <th>Connection State</th>
                <th>Expected Neighbor</th>
                <th>Expected Interface</th>
                <th>Health</th>
            </tr>
"""
        
        # Sort connections by health - problems first
        sorted_connections = sorted(all_connections, key=lambda x: (
            0 if x['connection']['state'] in ['missing', 'mismatch'] else
            1 if x['connection']['state'] == 'unexpected' else 2
        ))
        
        for conn_info in sorted_connections:
            conn = conn_info['connection']
            hostname = conn_info['hostname']
            
            state_class = f"state-{conn['state']}"
            health_class = f"lldp-{conn['health']}"
            
            html_content += f"""
            <tr>
                <td>{hostname}</td>
                <td>{conn['source_interface']}</td>
                <td>{conn['neighbor_device']}</td>
                <td>{conn['neighbor_interface']}</td>
                <td><span class="{state_class}">{conn['state'].upper()}</span></td>
                <td>{conn['expected_neighbor'] or 'N/A'}</td>
                <td>{conn['expected_interface'] or 'N/A'}</td>
                <td><span class="{health_class}">{conn['health'].upper()}</span></td>
            </tr>
"""
        
        html_content += """
        </table>
        
        <h2>LLDP Health Assessment Criteria</h2>
        <table class="lldp-table">
            <tr><th>State</th><th>Health Level</th><th>Description</th></tr>
            <tr><td>Established</td><td class="lldp-excellent">EXCELLENT</td><td>Connection matches expected topology</td></tr>
            <tr><td>Unexpected</td><td class="lldp-warning">WARNING</td><td>Connection not defined in topology</td></tr>
            <tr><td>Mismatch</td><td class="lldp-critical">CRITICAL</td><td>Connection differs from expected topology</td></tr>
            <tr><td>Missing</td><td class="lldp-critical">CRITICAL</td><td>Expected connection not found</td></tr>
        </table>
    </div>
</body>
</html>
"""
        
        with open(output_file, "w") as f:
            f.write(html_content)

if __name__ == "__main__":
    analyzer = LLDPAnalyzer()
    print("LLDP analyzer initialized")
    print(f"Monitoring {len(analyzer.current_lldp_stats)} devices")