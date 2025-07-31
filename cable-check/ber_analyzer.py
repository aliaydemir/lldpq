#!/usr/bin/env python3
"""
BER (Bit Error Rate) Analysis Module for LLDPq
Professional network error rate monitoring and analysis
"""

import json
import time
import re
import os
import math
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional
from enum import Enum

class BERGrade(Enum):
    """BER quality grades"""
    EXCELLENT = "excellent"
    GOOD = "good"  
    WARNING = "warning"
    CRITICAL = "critical"
    UNKNOWN = "unknown"

class BERAnalyzer:
    """Professional BER Analysis System"""
    
    # Industry-standard BER thresholds
    DEFAULT_CONFIG = {
        "raw_ber_threshold": 1.0E-6,      # 1 error per million bits
        "warning_ber_threshold": 1.0E-5,   # 1 error per 100k bits  
        "critical_ber_threshold": 1.0E-4,  # 1 error per 10k bits
        "min_packets_for_analysis": 1000,  # Minimum packets for reliable BER
        "history_retention_hours": 24,     # Keep 24 hours of history
        "trend_analysis_points": 10        # Minimum points for trend analysis
    }
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.ber_history = {}  # port -> list of ber readings over time
        self.current_ber_stats = {}  # port -> current ber status
        self.config = self.DEFAULT_CONFIG.copy()
        
        # Ensure ber-data directory exists
        os.makedirs(f"{self.data_dir}/ber-data", exist_ok=True)
        
        # Load historical data
        self.load_ber_history()
    
    def load_ber_history(self):
        """Load historical BER data from file"""
        try:
            with open(f"{self.data_dir}/ber_history.json", "r") as f:
                data = json.load(f)
                self.ber_history = data.get("ber_history", {})
                self.current_ber_stats = data.get("current_ber_stats", {})
                
                # Clean old data (older than retention period)
                self.cleanup_old_history()
        except (FileNotFoundError, json.JSONDecodeError):
            print("No previous BER history found, starting fresh")
    
    def save_ber_history(self):
        """Save BER history to file"""
        try:
            data = {
                "ber_history": self.ber_history,
                "current_ber_stats": self.current_ber_stats,
                "last_update": time.time(),
                "config": self.config
            }
            with open(f"{self.data_dir}/ber_history.json", "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Error saving BER history: {e}")
    
    def cleanup_old_history(self):
        """Remove history entries older than retention period"""
        current_time = time.time()
        retention_seconds = self.config["history_retention_hours"] * 3600
        
        for port_name in list(self.ber_history.keys()):
            if port_name in self.ber_history:
                self.ber_history[port_name] = [
                    entry for entry in self.ber_history[port_name]
                    if current_time - entry['timestamp'] <= retention_seconds
                ]
                
                # Remove port if no history left
                if not self.ber_history[port_name]:
                    del self.ber_history[port_name]
    
    def is_physical_port(self, interface_name: str) -> bool:
        """Check if interface is a physical port"""
        physical_patterns = [
            r'^swp\d+',      # Cumulus swp interfaces
            r'^eth\d+',      # Ethernet interfaces
            r'^eno\d+',      # Predictable network interface names
            r'^ens\d+',      # Systemd predictable names
            r'^enp\d+s\d+',  # PCI slot names
        ]
        
        for pattern in physical_patterns:
            if re.match(pattern, interface_name):
                return True
        return False
    
    def calculate_ber(self, rx_packets: int, tx_packets: int, rx_errors: int, tx_errors: int) -> float:
        """Calculate Bit Error Rate"""
        total_packets = rx_packets + tx_packets
        total_errors = rx_errors + tx_errors
        
        if total_packets < self.config["min_packets_for_analysis"]:
            return 0.0  # Not enough data for reliable BER calculation
        
        if total_errors == 0:
            return 0.0  # Perfect transmission
        
        # BER = errors / total_bits
        # Assuming average packet size of 1500 bytes = 12000 bits
        avg_bits_per_packet = 12000
        total_bits = total_packets * avg_bits_per_packet
        
        ber = total_errors / total_bits if total_bits > 0 else 0.0
        return ber
    
    def get_ber_grade(self, ber_value: float) -> BERGrade:
        """Determine BER quality grade"""
        if ber_value == 0.0:
            return BERGrade.EXCELLENT
        elif ber_value < self.config["raw_ber_threshold"]:
            return BERGrade.GOOD
        elif ber_value < self.config["warning_ber_threshold"]:
            return BERGrade.WARNING
        else:
            return BERGrade.CRITICAL
    
    def update_interface_ber(self, port_name: str, interface_stats: Dict[str, int]):
        """Update BER statistics for an interface"""
        current_time = time.time()
        
        # Calculate BER
        ber_value = self.calculate_ber(
            interface_stats.get('rx_packets', 0),
            interface_stats.get('tx_packets', 0), 
            interface_stats.get('rx_errors', 0),
            interface_stats.get('tx_errors', 0)
        )
        
        # Get quality grade
        grade = self.get_ber_grade(ber_value)
        
        # Create BER record
        ber_record = {
            'timestamp': current_time,
            'ber_value': ber_value,
            'grade': grade.value,
            'rx_packets': interface_stats.get('rx_packets', 0),
            'tx_packets': interface_stats.get('tx_packets', 0),
            'rx_errors': interface_stats.get('rx_errors', 0),
            'tx_errors': interface_stats.get('tx_errors', 0),
            'total_packets': interface_stats.get('rx_packets', 0) + interface_stats.get('tx_packets', 0)
        }
        
        # Update history
        if port_name not in self.ber_history:
            self.ber_history[port_name] = []
        
        self.ber_history[port_name].append(ber_record)
        
        # Update current stats
        self.current_ber_stats[port_name] = ber_record
        
        return ber_record
    
    def get_ber_trend(self, port_name: str) -> Dict[str, Any]:
        """Analyze BER trend for a port"""
        if port_name not in self.ber_history or len(self.ber_history[port_name]) < self.config["trend_analysis_points"]:
            return {"trend": "insufficient_data", "confidence": "low"}
        
        history = self.ber_history[port_name]
        recent_values = [entry['ber_value'] for entry in history[-self.config["trend_analysis_points"]:]]
        
        # Simple trend analysis
        if len(recent_values) < 2:
            return {"trend": "stable", "confidence": "low"}
        
        # Calculate trend direction
        first_half = recent_values[:len(recent_values)//2]
        second_half = recent_values[len(recent_values)//2:]
        
        avg_first = sum(first_half) / len(first_half) if first_half else 0
        avg_second = sum(second_half) / len(second_half) if second_half else 0
        
        change_ratio = (avg_second - avg_first) / (avg_first + 1e-15)  # Avoid division by zero
        
        if abs(change_ratio) < 0.1:
            trend = "stable"
        elif change_ratio > 0.1:
            trend = "worsening" 
        else:
            trend = "improving"
        
        confidence = "high" if len(recent_values) >= self.config["trend_analysis_points"] else "medium"
        
        return {
            "trend": trend,
            "confidence": confidence,
            "change_ratio": change_ratio,
            "recent_avg": avg_second,
            "previous_avg": avg_first
        }
    
    def get_ber_summary(self) -> Dict[str, Any]:
        """Get overall BER analysis summary"""
        summary = {
            "total_ports": 0,
            "excellent_ports": [],
            "good_ports": [], 
            "warning_ports": [],
            "critical_ports": [],
            "unknown_ports": []
        }
        
        for port_name, stats in self.current_ber_stats.items():
            summary["total_ports"] += 1
            grade = stats.get('grade', 'unknown')
            
            port_info = {
                "port": port_name,
                "ber_value": stats.get('ber_value', 0),
                "total_packets": stats.get('total_packets', 0),
                "rx_errors": stats.get('rx_errors', 0),
                "tx_errors": stats.get('tx_errors', 0),
                "timestamp": stats.get('timestamp', time.time())
            }
            
            if grade == BERGrade.EXCELLENT.value:
                summary["excellent_ports"].append(port_info)
            elif grade == BERGrade.GOOD.value:
                summary["good_ports"].append(port_info)
            elif grade == BERGrade.WARNING.value:
                summary["warning_ports"].append(port_info)
            elif grade == BERGrade.CRITICAL.value:
                summary["critical_ports"].append(port_info)
            else:
                summary["unknown_ports"].append(port_info)
        
        return summary
    
    def detect_ber_anomalies(self) -> List[Dict[str, Any]]:
        """Detect BER-related anomalies"""
        anomalies = []
        
        for port_name, stats in self.current_ber_stats.items():
            grade = stats.get('grade', 'unknown')
            ber_value = stats.get('ber_value', 0)
            
            # Critical BER anomaly
            if grade == BERGrade.CRITICAL.value:
                anomalies.append({
                    "device": port_name.split(':')[0] if ':' in port_name else "unknown",
                    "interface": port_name.split(':')[1] if ':' in port_name else port_name,
                    "type": "HIGH_BER_RATE",
                    "severity": "critical",
                    "message": f"Critical BER detected: {ber_value:.2e}",
                    "details": {
                        "ber_value": ber_value,
                        "threshold": self.config["critical_ber_threshold"],
                        "rx_errors": stats.get('rx_errors', 0),
                        "tx_errors": stats.get('tx_errors', 0)
                    },
                    "action": f"Immediate attention required - check cable and transceivers for {port_name}"
                })
            
            # Warning BER anomaly  
            elif grade == BERGrade.WARNING.value:
                anomalies.append({
                    "device": port_name.split(':')[0] if ':' in port_name else "unknown",
                    "interface": port_name.split(':')[1] if ':' in port_name else port_name,
                    "type": "ELEVATED_BER_RATE",
                    "severity": "warning",
                    "message": f"Elevated BER detected: {ber_value:.2e}",
                    "details": {
                        "ber_value": ber_value,
                        "threshold": self.config["warning_ber_threshold"],
                        "rx_errors": stats.get('rx_errors', 0),
                        "tx_errors": stats.get('tx_errors', 0)
                    },
                    "action": f"Monitor {port_name} closely and consider preventive maintenance"
                })
            
            # Trend-based anomalies
            trend_info = self.get_ber_trend(port_name)
            if trend_info["trend"] == "worsening" and trend_info["confidence"] == "high":
                anomalies.append({
                    "device": port_name.split(':')[0] if ':' in port_name else "unknown",
                    "interface": port_name.split(':')[1] if ':' in port_name else port_name,
                    "type": "BER_TREND_WORSENING",
                    "severity": "warning",
                    "message": f"BER trend worsening on {port_name}",
                    "details": {
                        "trend": trend_info["trend"],
                        "change_ratio": trend_info.get("change_ratio", 0),
                        "current_ber": ber_value
                    },
                    "action": f"Investigate potential cable degradation on {port_name}"
                })
        
        return anomalies
    
    def export_ber_data_for_web(self, output_file: str):
        """Export BER data for web display - same format as BGP/Link Flap/Optical"""
        summary = self.get_ber_summary()
        anomalies = self.detect_ber_anomalies()
        
        # Determine overall health status
        total_problematic = len(summary['warning_ports']) + len(summary['critical_ports'])
        
        if total_problematic == 0:
            overall_status = "healthy"
            status_color = "#4caf50"
        elif len(summary['critical_ports']) > 0:
            overall_status = "critical"
            status_color = "#f44336"
        else:
            overall_status = "warning"
            status_color = "#ff9800"
        
        # Calculate health percentages
        total_ports = summary['total_ports']
        if total_ports > 0:
            excellent_pct = len(summary['excellent_ports']) / total_ports * 100
            good_pct = len(summary['good_ports']) / total_ports * 100
            warning_pct = len(summary['warning_ports']) / total_ports * 100
            critical_pct = len(summary['critical_ports']) / total_ports * 100
        else:
            excellent_pct = good_pct = warning_pct = critical_pct = 0
        
        html_content = f"""<!DOCTYPE html>
<html>
<head>
    <title>BER Analysis Results</title>
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>
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
        .card-excellent {{ border-left-color: #4caf50; }}
        .card-good {{ border-left-color: #8bc34a; }}
        .card-warning {{ border-left-color: #ff9800; }}
        .card-critical {{ border-left-color: #f44336; }}
        .card-total {{ border-left-color: #2196f3; }}
        .metric {{ font-size: 24px; font-weight: bold; }}
        .ber-excellent {{ color: #4caf50; font-weight: bold; }}
        .ber-good {{ color: #8bc34a; font-weight: bold; }}
        .ber-warning {{ color: #ff9800; font-weight: bold; }}
        .ber-critical {{ color: #f44336; font-weight: bold; }}
        .anomaly-section {{
            margin: 30px 0;
            padding: 20px;
            background: #fff;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        .anomaly-item {{
            margin: 15px 0;
            padding: 15px;
            border-radius: 4px;
            border-left: 4px solid;
        }}
        .anomaly-critical {{
            background-color: #ffebee;
            border-left-color: #f44336;
        }}
        .anomaly-warning {{
            background-color: #fff3e0;
            border-left-color: #ff9800;
        }}
        .ber-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        .ber-table th, .ber-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        .ber-table th {{ background-color: #f2f2f2; }}
        
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
    </style>
  </head>
  <body>
    <h1></h1>
    <h1><font color="#b57614">BER Analysis Results</font></h1>
        <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
        
        <h2>Network Summary</h2>
        <div class="summary-grid">
            <div class="summary-card card-total" id="total-ports-card">
                <div class="metric" id="total-ports">{total_ports}</div>
                <div>Total Ports</div>
            </div>
            <div class="summary-card card-excellent" id="excellent-card">
                <div class="metric" id="excellent-ports">{len(summary['excellent_ports'])}</div>
                <div>Excellent</div>
            </div>
            <div class="summary-card card-good" id="good-card">
                <div class="metric" id="good-ports">{len(summary['good_ports'])}</div>
                <div>Good</div>
            </div>
            <div class="summary-card card-warning" id="warning-card">
                <div class="metric" id="warning-ports">{len(summary['warning_ports'])}</div>
                <div>Warning</div>
            </div>
            <div class="summary-card card-critical" id="critical-card">
                <div class="metric" id="critical-ports">{len(summary['critical_ports'])}</div>
                <div>Critical</div>
            </div>
        </div>
        
        <div id="filter-info" class="filter-info">
            <span id="filter-text"></span>
            <button onclick="clearFilter()" style="margin-left: 10px; padding: 2px 8px; background: #1976d2; color: white; border: none; border-radius: 3px; cursor: pointer;">Show All</button>
        </div>
"""
        
        # Add anomalies section if any
        if anomalies:
            html_content += f"""
        <div class="anomaly-section">
            <h2>🚨 BER Anomalies Detected ({len(anomalies)})</h2>
"""
            for anomaly in anomalies[:10]:  # Show top 10 anomalies
                severity_class = f"anomaly-{anomaly['severity']}"
                html_content += f"""
            <div class="anomaly-item {severity_class}">
                <strong>{anomaly['device']}:{anomaly['interface']}</strong> - {anomaly['message']}<br>
                <small><strong>Action:</strong> {anomaly['action']}</small>
            </div>
"""
            html_content += """
        </div>
"""
        
        # Add detailed table  
        html_content += """
        <h2>Interface BER Status</h2>
        <table class="ber-table" id="ber-table">
            <thead>
                <tr>
                    <th>Device</th>
                    <th>Interface</th>
                    <th>Status</th>
                    <th>BER Value</th>
                    <th>Total Packets</th>
                    <th>RX Errors</th>
                    <th>TX Errors</th>
                    <th>Last Updated</th>
                </tr>
            </thead>
            <tbody id="ber-data">
"""
        
        # Add all ports to table (sorted by health - problems first, then good ones)
        all_ports = (summary['excellent_ports'] + summary['good_ports'] + 
                    summary['warning_ports'] + summary['critical_ports'])
        
        # Sort ports by BER status priority (critical/warning first)
        def get_ber_priority(port_info):
            ber_value = port_info['ber_value']
            if ber_value >= self.config["critical_ber_threshold"]:
                return 0  # Critical first
            elif ber_value >= self.config["warning_ber_threshold"]:
                return 1  # Warning second  
            elif ber_value == 0:
                return 3  # Excellent third (perfect quality)
            elif ber_value < self.config["raw_ber_threshold"]:
                return 2  # Good second (low error rate)
            else:
                return 4  # Marginal last
        
        sorted_ports = sorted(all_ports, key=get_ber_priority)
        
        for port_info in sorted_ports:
            port_name = port_info['port']
            device = port_name.split(':')[0] if ':' in port_name else "unknown"
            interface = port_name.split(':')[1] if ':' in port_name else port_name
            
            # Determine status and color
            ber_value = port_info['ber_value']
            if ber_value == 0:
                status = "EXCELLENT"
                status_class = "ber-excellent"
            elif ber_value < self.config["raw_ber_threshold"]:
                status = "GOOD"
                status_class = "ber-good"
            elif ber_value < self.config["warning_ber_threshold"]:
                status = "WARNING"
                status_class = "ber-warning"
            else:
                status = "CRITICAL"
                status_class = "ber-critical"
            
            ber_display = f"{ber_value:.2e}" if ber_value > 0 else "0"
            
            timestamp = datetime.fromtimestamp(port_info['timestamp']).strftime('%H:%M:%S')
            
            html_content += f"""
                <tr data-status="{status.lower()}">
                    <td>{device}</td>
                    <td>{interface}</td>
                    <td><span class="{status_class}">{status}</span></td>
                    <td>{ber_display}</td>
                    <td>{port_info['total_packets']:,}</td>
                    <td>{port_info['rx_errors']:,}</td>
                    <td>{port_info['tx_errors']:,}</td>
                    <td>{timestamp}</td>
                </tr>
"""
        
        html_content += """
            </tbody>
        </table>
        
        <div style="margin-top: 30px; padding: 15px; background-color: #f8f9fa; border-radius: 4px;">
            <h3>📊 BER Analysis Information</h3>
            <ul>
                <li><strong>Excellent:</strong> Zero bit errors detected</li>
                <li><strong>Good:</strong> BER &lt; 1×10⁻⁶ (industry standard)</li>
                <li><strong>Warning:</strong> BER between 1×10⁻⁶ and 1×10⁻⁵</li>
                <li><strong>Critical:</strong> BER &gt; 1×10⁻⁵ (requires immediate attention)</li>
                <li><strong>Analysis:</strong> Based on interface error statistics and packet counters</li>
            </ul>
        </div>

    <script>
        // Filter functionality
        let currentFilter = 'ALL';
        let allRows = [];
        
        document.addEventListener('DOMContentLoaded', function() {{
            // Store all table rows for filtering
            allRows = Array.from(document.querySelectorAll('#ber-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
        }});
        
        function setupCardEvents() {{
            console.log('BER: Setting up card events...');
            
            document.getElementById('total-ports-card').addEventListener('click', function() {{
                console.log('BER: Total ports clicked');
                if (parseInt(document.getElementById('total-ports').textContent) > 0) {{
                    filterPorts('TOTAL');
                }}
            }});
            
            document.getElementById('excellent-card').addEventListener('click', function() {{
                console.log('BER: Excellent clicked');
                if (parseInt(document.getElementById('excellent-ports').textContent) > 0) {{
                    filterPorts('EXCELLENT');
                }}
            }});
            
            document.getElementById('good-card').addEventListener('click', function() {{
                console.log('BER: Good clicked');
                if (parseInt(document.getElementById('good-ports').textContent) > 0) {{
                    filterPorts('GOOD');
                }}
            }});
            
            document.getElementById('warning-card').addEventListener('click', function() {{
                console.log('BER: Warning clicked');
                if (parseInt(document.getElementById('warning-ports').textContent) > 0) {{
                    filterPorts('WARNING');
                }}
            }});
            
            document.getElementById('critical-card').addEventListener('click', function() {{
                console.log('BER: Critical clicked');
                if (parseInt(document.getElementById('critical-ports').textContent) > 0) {{
                    filterPorts('CRITICAL');
                }}
            }});
        }}
        
        function filterPorts(filterType) {{
            console.log('BER: filterPorts called with:', filterType);
            currentFilter = filterType;
            
            // Clear active state from all cards
            document.querySelectorAll('.summary-card').forEach(card => {{
                card.classList.remove('active');
            }});
            
            let filteredRows = allRows;
            let filterText = '';
            
            if (filterType === 'EXCELLENT') {{
                filteredRows = allRows.filter(row => row.dataset.status === 'excellent');
                console.log('BER: Found', filteredRows.length, 'excellent ports');
                filterText = `Showing ${{filteredRows.length}} Excellent Ports`;
                document.getElementById('excellent-card').classList.add('active');
            }} else if (filterType === 'GOOD') {{
                filteredRows = allRows.filter(row => row.dataset.status === 'good');
                filterText = `Showing ${{filteredRows.length}} Good Ports`;
                document.getElementById('good-card').classList.add('active');
            }} else if (filterType === 'WARNING') {{
                filteredRows = allRows.filter(row => row.dataset.status === 'warning');
                filterText = `Showing ${{filteredRows.length}} Warning Ports`;
                document.getElementById('warning-card').classList.add('active');
            }} else if (filterType === 'CRITICAL') {{
                filteredRows = allRows.filter(row => row.dataset.status === 'critical');
                filterText = `Showing ${{filteredRows.length}} Critical Ports`;
                document.getElementById('critical-card').classList.add('active');
            }} else if (filterType === 'TOTAL') {{
                filteredRows = allRows;
                document.getElementById('total-ports-card').classList.add('active');
            }}
            
            // Show filter info for all filters except TOTAL
            if (filterType !== 'ALL' && filterType !== 'TOTAL') {{
                document.getElementById('filter-info').style.display = 'block';
                document.getElementById('filter-text').textContent = filterText;
            }} else {{
                document.getElementById('filter-info').style.display = 'none';
            }}
            
            // Hide all rows first
            allRows.forEach(row => row.style.display = 'none');
            
            // Show filtered rows
            filteredRows.forEach(row => row.style.display = '');
        }}
        
        function clearFilter() {{
            currentFilter = 'ALL';
            document.querySelectorAll('.summary-card').forEach(card => {{
                card.classList.remove('active');
            }});
            document.getElementById('filter-info').style.display = 'none';
            
            // Show all rows
            allRows.forEach(row => row.style.display = '');
        }}
    </script>
</body>
</html>"""
        
        try:
            with open(output_file, 'w') as f:
                f.write(html_content)
            print(f"BER analysis report generated: {output_file}")
        except Exception as e:
            print(f"Error writing BER analysis report: {e}")
        
        # Save history after analysis
        self.save_ber_history()