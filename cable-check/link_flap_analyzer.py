#!/usr/bin/env python3
"""
Link Flap Detection Module for LLDPq
Professional Carrier Transition Based
"""

import os
import re
import json
import time
import collections
from datetime import datetime, timedelta
from enum import Enum
from typing import Dict, List, Any, Optional, NamedTuple
from dataclasses import dataclass, asdict

class FlapStatus(Enum):
    """flap status"""
    OK = "ok"
    FLAPPING = "flapping"
    FLAPPED = "flapped"

class FlapPeriod(Enum):
    """flap detection periods"""
    FLAP_30_SEC = 30
    FLAP_1_MIN = 60
    FLAP_5_MIN = 5 * 60
    FLAP_1_HR = 60 * 60
    FLAP_12_HRS = 12 * 60 * 60
    FLAP_24_HRS = 24 * 60 * 60

@dataclass
class CarrierTransitionData:
    """Carrier transition data for a port"""
    port_name: str
    transitions: int
    timestamp: float
    device: str = ""
    interface: str = ""
    
class LinkFlapAnalyzer:
    """Professional Link Flap Detection System"""
    
    # constants  
    FLAPPING_INTERVAL = 125  # seconds - detection window
    MIN_CARRIER_TRANSITION_DELTA = 2  # minimum transitions to consider flap
    INTERVAL_TO_PERSIST_FLAP = 60  # seconds - how long flap status persists
    INTERVAL_24_HOURS = 24 * 60 * 60  # 24 hour cleanup
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.carrier_transitions_lookback = {}  # port -> deque of (time, transitions)
        self.flapping_hist = {}  # port -> deque of (time, transitions, flap_count)
        self.carrier_transitions_stats = {}  # port -> current transition count
        self.flapping_counters = {}  # port -> {period: count}
        
        # Ensure flap-data directory exists
        os.makedirs(f"{self.data_dir}/flap-data", exist_ok=True)
        
        # Load historical data if exists
        self.load_flap_history()
    
    def load_flap_history(self):
        """Load historical flap data from file"""
        try:
            with open(f"{self.data_dir}/flap_history.json", "r") as f:
                data = json.load(f)
                # Convert lists back to deques
                for port, hist in data.get("flapping_hist", {}).items():
                    self.flapping_hist[port] = collections.deque(hist, maxlen=1000)
                for port, lookback in data.get("carrier_transitions_lookback", {}).items():
                    self.carrier_transitions_lookback[port] = collections.deque(lookback, maxlen=100)
        except (FileNotFoundError, json.JSONDecodeError):
            pass
    
    def save_flap_history(self):
        """Save flap history to file"""
        try:
            data = {
                "flapping_hist": {port: list(deq) for port, deq in self.flapping_hist.items()},
                "carrier_transitions_lookback": {port: list(deq) for port, deq in self.carrier_transitions_lookback.items()},
                "last_update": time.time()
            }
            with open(f"{self.data_dir}/flap_history.json", "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Error saving flap history: {e}")
    
    def update_carrier_transitions(self, port_name: str, current_transitions: int):
        """Update carrier transition count for a port"""
        curr_time = time.time()
        
        # Initialize if new port
        if port_name not in self.carrier_transitions_lookback:
            self.carrier_transitions_lookback[port_name] = collections.deque(maxlen=100)
            self.flapping_hist[port_name] = collections.deque(maxlen=1000)
        
        # Add current reading
        self.carrier_transitions_lookback[port_name].append((curr_time, current_transitions))
        self.carrier_transitions_stats[port_name] = current_transitions
        
        # Clean old entries
        self._cleanup_old_entries(curr_time)
    
    def _cleanup_old_entries(self, curr_time: float):
        """Remove entries older than thresholds"""
        # Remove entries older than flapping interval
        for port, lookback_queue in self.carrier_transitions_lookback.items():
            while lookback_queue and (curr_time - lookback_queue[0][0] > self.FLAPPING_INTERVAL):
                lookback_queue.popleft()
        
        # Remove entries older than 24 hrs
        for port, flap_hist_queue in self.flapping_hist.items():
            while flap_hist_queue and (curr_time - flap_hist_queue[0][0] > self.INTERVAL_24_HOURS):
                flap_hist_queue.popleft()
    
    def check_flapping(self) -> bool:
        """Check for link flapping - returns True if any flaps detected"""
        flap_detected = False
        curr_time = time.time()
        
        for port_name, ct_lookback in self.carrier_transitions_lookback.items():
            if len(ct_lookback) > 1:
                # Calculate delta in transitions over the monitoring period
                delta = ct_lookback[-1][1] - ct_lookback[0][1]
                
                if delta >= self.MIN_CARRIER_TRANSITION_DELTA:
                    # Flap detected! Record it
                    flap_count = delta // 2  # Each flap is up/down cycle
                    self.flapping_hist[port_name].append((curr_time, ct_lookback[-1][1], flap_count))
                    
                    # Clear the lookback to start fresh detection
                    elements_to_delete = len(ct_lookback) - 1
                    for _ in range(elements_to_delete):
                        ct_lookback.popleft()
                    
                    flap_detected = True
                    print(f"Flap detected on {port_name}: {flap_count} flaps")
        
        return flap_detected
    
    def calculate_flapping_rate(self, port_name: str) -> Dict[str, int]:
        """Calculate flapping rates for different time periods"""
        flap_counters = {period.name.lower(): 0 for period in FlapPeriod}
        
        curr_time = time.time()
        flaps = self.flapping_hist.get(port_name, [])
        
        if flaps:
            for flap_time, _, flap_count in flaps:
                time_delta = curr_time - flap_time
                
                # Add to appropriate time buckets
                for period in FlapPeriod:
                    if time_delta <= period.value:
                        flap_counters[period.name.lower()] += flap_count
        
        return flap_counters
    
    def get_port_flap_status(self, port_name: str) -> FlapStatus:
        """Get current flap status for a port"""
        counters = self.calculate_flapping_rate(port_name)
        
        # Currently flapping if recent activity
        if counters['flap_30_sec'] > 0 or counters['flap_1_min'] > 0:
            return FlapStatus.FLAPPING
        
        # Previously flapped if any activity in longer periods
        if any(count > 0 for count in counters.values()):
            return FlapStatus.FLAPPED
        
        return FlapStatus.OK
    
    def get_flap_summary(self) -> Dict[str, Any]:
        """Get summary of all flapping ports"""
        summary = {
            "total_ports": len(self.carrier_transitions_stats),
            "flapping_ports": [],
            "flapped_ports": [],
            "ok_ports": [],
            "timestamp": datetime.now().isoformat()
        }
        
        for port_name in self.carrier_transitions_stats.keys():
            status = self.get_port_flap_status(port_name)
            counters = self.calculate_flapping_rate(port_name)
            
            port_info = {
                "port": port_name,
                "status": status.value,
                "counters": counters,
                "last_transitions": self.carrier_transitions_stats.get(port_name, 0)
            }
            
            if status == FlapStatus.FLAPPING:
                summary["flapping_ports"].append(port_info)
            elif status == FlapStatus.FLAPPED:
                summary["flapped_ports"].append(port_info)
            else:
                summary["ok_ports"].append(port_info)
        
        return summary
    
    def detect_flap_anomalies(self) -> List[Dict[str, Any]]:
        """Detect interface flapping anomalies"""
        anomalies = []
        
        for port_name in self.carrier_transitions_stats.keys():
            status = self.get_port_flap_status(port_name)
            counters = self.calculate_flapping_rate(port_name)
            
            if status == FlapStatus.FLAPPING:
                anomalies.append({
                    "device": port_name.split(':')[0] if ':' in port_name else "unknown",
                    "interface": port_name.split(':')[1] if ':' in port_name else port_name,
                    "type": "CRITICAL_FLAPPING",
                    "severity": "critical",
                    "message": f"Port {port_name} is currently flapping ({counters['flap_30_sec']} flaps in last 30 seconds)",
                    "details": {
                        "flap_count_30s": counters['flap_30_sec'],
                        "flap_count_1min": counters['flap_1_min'],
                        "current_transitions": self.carrier_transitions_stats.get(port_name, 0)
                    },
                    "action": f"Check physical cabling and hardware health for {port_name}"
                })
            
            elif status == FlapStatus.FLAPPED and counters['flap_5_min'] > 0:
                anomalies.append({
                    "device": port_name.split(':')[0] if ':' in port_name else "unknown",
                    "interface": port_name.split(':')[1] if ':' in port_name else port_name,
                    "type": "WARNING_FLAPPING",
                    "severity": "warning",
                    "message": f"Port {port_name} recently flapped ({counters['flap_5_min']} flaps in last 5 minutes)",
                    "details": {
                        "flap_count_5min": counters['flap_5_min'],
                        "flap_count_1hr": counters['flap_1_hr'],
                        "current_transitions": self.carrier_transitions_stats.get(port_name, 0)
                    },
                    "action": f"Monitor {port_name} closely and investigate if pattern continues"
                })
        
        return anomalies
    
    def export_flap_data_for_web(self, output_file: str):
        """Export flap data for web display"""
        summary = self.get_flap_summary()
        anomalies = self.detect_flap_anomalies()
        
        # Determine overall health status
        total_problematic = len(summary['flapping_ports']) + len(summary['flapped_ports'])
        stability_ratio = ((summary['total_ports'] - total_problematic) / summary['total_ports'] * 100) if summary['total_ports'] > 0 else 0
        
        html_content = f"""
<!DOCTYPE html>
<html>
<head>
    <h1></h1>
    <title>Link Flap Detection Results</title>
    <link rel="stylesheet" type="text/css" href="/css/styles2.css">
    <style>
        .flap-excellent {{ color: #4caf50; font-weight: bold; }}
        .flap-good {{ color: #8bc34a; font-weight: bold; }}
        .flap-warning {{ color: #ff9800; font-weight: bold; }}
        .flap-critical {{ color: #f44336; font-weight: bold; }}
        .flap-unknown {{ color: gray; }}
        .flap-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        .flap-table th, .flap-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        .flap-table th {{ background-color: #f2f2f2; }}
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
        .metric {{ font-size: 24px; font-weight: bold; }}
        
        .filter-info {{
            text-align: center;
            padding: 10px;
            margin: 10px 0;
            background: #e8f4fd;
            border-radius: 4px;
            color: #1976d2;
            display: none;
        }}
        .status-established {{ color: #4caf50; font-weight: bold; }}
        .status-flapping {{ color: #f44336; font-weight: bold; }}
        .status-flapped {{ color: #ff9800; font-weight: bold; }}
        .status-ok {{ color: #4caf50; font-weight: bold; }}
        .transition-good {{ color: #4caf50; }}
        .transition-warning {{ color: #ff9800; }}
        .transition-critical {{ color: #f44336; }}
    </style>
</head>
<body>
    <h1><font color="#b57614">Link Flap Detection Results</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <h2>Network Summary</h2>
    <div class="summary-grid">
        <div class="summary-card" id="total-devices-card">
            <div class="metric" id="total-devices">{len(set(port.split(':')[0] for port in self.carrier_transitions_stats.keys()))}</div>
            <div>Total Devices</div>
        </div>
        <div class="summary-card" id="total-ports-card">
            <div class="metric" id="total-ports">{summary['total_ports']}</div>
            <div>Total Ports</div>
        </div>
        <div class="summary-card" id="stable-card">
            <div class="metric flap-excellent" id="stable-ports">{len(summary['ok_ports'])}</div>
            <div>Stable</div>
        </div>
        <div class="summary-card" id="problematic-card">
            <div class="metric flap-critical" id="problematic-ports">{len(summary['flapping_ports']) + len(summary['flapped_ports'])}</div>
            <div>Problematic</div>
        </div>
        <div class="summary-card" id="stability-card">
            <div class="metric" id="stability-ratio">{stability_ratio:.1f}%</div>
            <div>Stability Ratio</div>
        </div>
    </div>
    
    <div id="filter-info" class="filter-info">
        <span id="filter-text"></span>
        <button onclick="clearFilter()" style="margin-left: 10px; padding: 2px 8px; background: #1976d2; color: white; border: none; border-radius: 3px; cursor: pointer;">Show All</button>
    </div>
"""
        
        # Add anomalies section if any exist
        if anomalies:
            html_content += f"""
    <h2>📋 Detailed Issue Analysis ({len(anomalies)})</h2>
"""
            for anomaly in anomalies:
                html_content += f"""
    <div style="margin: 10px 0; padding: 10px; background-color: {'#ffebee' if anomaly['severity'] == 'critical' else '#fff3e0'}; border-left: 4px solid {'#f44336' if anomaly['severity'] == 'critical' else '#ff9800'};">
        <h4>{anomaly['device']} - {anomaly['interface']}</h4>
        <p><strong>Issue:</strong> {anomaly['message']}</p>
        <p><strong>Recommended Action:</strong> {anomaly['action']}</p>
    </div>
"""
        
        # Collect all ports for display
        all_ports = []
        for port_name in self.carrier_transitions_stats.keys():
            status = self.get_port_flap_status(port_name)
            counters = self.calculate_flapping_rate(port_name)
            device = port_name.split(':')[0] if ':' in port_name else "unknown"
            interface = port_name.split(':')[1] if ':' in port_name else port_name
            
            port_info = {
                'device': device,
                'interface': interface,
                'status': status,
                'counters': counters,
                'total_transitions': self.carrier_transitions_stats.get(port_name, 0)
            }
            all_ports.append(port_info)
        
        # Interface flapping table (sorted by problems first, like BGP)
        html_content += f"""
    <h2>Interface Flapping Status ({len(all_ports)} total)</h2>
    <table class="flap-table" id="flap-table">
        <thead>
        <tr>
            <th>Device</th>
            <th>Interface</th>
            <th>Status</th>
            <th>30s Flaps</th>
            <th>1m Flaps</th>
            <th>5m Flaps</th>
            <th>1h Flaps</th>
            <th>12h Flaps</th>
            <th>24h Flaps</th>
            <th>Total Transitions</th>
        </tr>
        </thead>
        <tbody id="flap-data">
"""
        
        # Sort by severity (problems first, like BGP)
        sorted_ports = sorted(all_ports, key=lambda x: (
            0 if x['status'] == FlapStatus.FLAPPING else
            1 if x['status'] == FlapStatus.FLAPPED else 2
        ))
        
        for port in sorted_ports:
            counters = port['counters']
            status_class = f"status-{port['status'].value}"
            
            # Color coding for transition counts
            transition_class = "transition-good"
            if port['total_transitions'] > 50:
                transition_class = "transition-critical"
            elif port['total_transitions'] > 10:
                transition_class = "transition-warning"
                
            html_content += f"""
        <tr class="{status_class}" data-status="{port['status'].value}">
            <td>{port['device']}</td>
            <td>{port['interface']}</td>
            <td><span class="{status_class}">{port['status'].value.upper()}</span></td>
            <td>{counters['flap_30_sec']}</td>
            <td>{counters['flap_1_min']}</td>
            <td>{counters['flap_5_min']}</td>
            <td>{counters['flap_1_hr']}</td>
            <td>{counters['flap_12_hrs']}</td>
            <td>{counters['flap_24_hrs']}</td>
            <td><span class="{transition_class}">{port['total_transitions']}</span></td>
        </tr>
"""
        
        html_content += """
    </table>
    
    <h2>Link Flap Detection Thresholds</h2>
    <table class="flap-table">
        <tr><th>Parameter</th><th>Threshold</th><th>Description</th></tr>
        <tr><td>Detection Window</td><td>125 seconds</td><td>Time window for carrier transition analysis</td></tr>
        <tr><td>Min Transition Delta</td><td>2+ transitions</td><td>Minimum transitions to trigger flap detection</td></tr>
        <tr><td>Flap Persistence</td><td>60 seconds</td><td>Duration flap status remains active</td></tr>
        <tr><td>High Transition Alert</td><td>50+ transitions</td><td>Indicates potential hardware issues</td></tr>
        <tr><td>Data Retention</td><td>24 hours</td><td>Historical carrier transition data retention</td></tr>
    </table>
</body>
</html>
    <script>
        // Filter functionality
        let currentFilter = 'ALL';
        let allRows = [];
        
        document.addEventListener('DOMContentLoaded', function() {{
            // Store all table rows for filtering
            allRows = Array.from(document.querySelectorAll('#flap-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
        }});
        
        function setupCardEvents() {{
            document.getElementById('total-ports-card').addEventListener('click', function() {{
                if (parseInt(document.getElementById('total-ports').textContent) > 0) {{
                    filterPorts('TOTAL');
                }}
            }});
            
            document.getElementById('stable-card').addEventListener('click', function() {{
                if (parseInt(document.getElementById('stable-ports').textContent) > 0) {{
                    filterPorts('STABLE');
                }}
            }});
            
            document.getElementById('problematic-card').addEventListener('click', function() {{
                if (parseInt(document.getElementById('problematic-ports').textContent) > 0) {{
                    filterPorts('PROBLEMATIC');
                }}
            }});
        }}
        
        function filterPorts(filterType) {{
            currentFilter = filterType;
            
            // Clear active state from all cards
            document.querySelectorAll('.summary-card').forEach(card => {{
                card.classList.remove('active');
            }});
            
            let filteredRows = allRows;
            let filterText = '';
            
            if (filterType === 'STABLE') {{
                filteredRows = allRows.filter(row => row.dataset.status === 'ok');
                filterText = `Showing ${{filteredRows.length}} Stable Ports`;
                document.getElementById('stable-card').classList.add('active');
            }} else if (filterType === 'PROBLEMATIC') {{
                filteredRows = allRows.filter(row => 
                    row.dataset.status === 'flapping' || 
                    row.dataset.status === 'flapped'
                );
                filterText = `Showing ${{filteredRows.length}} Problematic Ports`;
                document.getElementById('problematic-card').classList.add('active');
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
        
        with open(output_file, "w") as f:
            f.write(html_content)

if __name__ == "__main__":
    analyzer = LinkFlapAnalyzer()
    print("Link Flap analyzer initialized")
    print(f"Monitoring {len(analyzer.carrier_transitions_stats)} ports")
