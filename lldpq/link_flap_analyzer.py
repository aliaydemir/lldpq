#!/usr/bin/env python3
"""
Link Flap Detection Module for LLDPq
Professional Carrier Transition Based

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
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
        self._port_cache = {}  # Cache for calculated port status/counters
        
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
    
    def _build_port_cache(self):
        """Build cache of all port statuses and counters - call once before bulk operations"""
        self._port_cache = {}
        for port_name in self.carrier_transitions_stats.keys():
            counters = self.calculate_flapping_rate(port_name)
            # Determine status from counters
            if counters['flap_30_sec'] > 0 or counters['flap_1_min'] > 0:
                status = FlapStatus.FLAPPING
            elif any(count > 0 for count in counters.values()):
                status = FlapStatus.FLAPPED
            else:
                status = FlapStatus.OK
            self._port_cache[port_name] = {'status': status, 'counters': counters}
    
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
        """Get summary of all flapping ports - uses cache for performance"""
        summary = {
            "total_ports": len(self.carrier_transitions_stats),
            "flapping_ports": [],
            "flapped_ports": [],
            "ok_ports": [],
            "timestamp": datetime.now().isoformat()
        }
        
        # Build cache if empty
        if not self._port_cache:
            self._build_port_cache()
        
        for port_name, cached in self._port_cache.items():
            status = cached['status']
            counters = cached['counters']
            
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
        """Detect interface flapping anomalies - uses cache for performance"""
        anomalies = []
        
        # Build cache if empty
        if not self._port_cache:
            self._build_port_cache()
        
        for port_name, cached in self._port_cache.items():
            status = cached['status']
            counters = cached['counters']
            
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
        """Export flap data for web display - optimized with caching"""
        # Build cache once at the start
        self._build_port_cache()
        
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
    <link rel="stylesheet" type="text/css" href="/css/select2.min.css">
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
        
        /* Sortable table styling */
        .sortable {{ cursor: pointer; user-select: none; position: relative; padding-right: 20px; }}
        .sortable:hover {{ background-color: #f5f5f5; }}
        .sort-arrow {{ font-size: 10px; color: #999; margin-left: 5px; opacity: 0.5; }}
        .sortable.asc .sort-arrow::before {{ content: '▲'; color: #b57614; opacity: 1; }}
        .sortable.desc .sort-arrow::before {{ content: '▼'; color: #b57614; opacity: 1; }}
        .sortable.asc .sort-arrow, .sortable.desc .sort-arrow {{ opacity: 1; }}
        
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
    <h1><font color="#b57614">Link Flap Detection Results</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
        <h2 style="margin: 0;">Link Flap Summary</h2>
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
        
        # Collect all ports for display - using cache
        all_ports = []
        for port_name, cached in self._port_cache.items():
            device = port_name.split(':')[0] if ':' in port_name else "unknown"
            interface = port_name.split(':')[1] if ':' in port_name else port_name
            
            port_info = {
                'device': device,
                'interface': interface,
                'status': cached['status'],
                'counters': cached['counters'],
                'total_transitions': self.carrier_transitions_stats.get(port_name, 0)
            }
            all_ports.append(port_info)
        
        # Interface flapping table (sorted by problems first, like BGP)
        html_content += f"""
    <h2>Interface Flapping Status ({len(all_ports)} total)</h2>
    <table class="flap-table" id="flap-table">
        <thead>
        <tr>
            <th class="sortable" data-column="0" data-type="string">Device <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="1" data-type="port">Interface <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="2" data-type="flap-status">Status <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="3" data-type="number">30s Flaps <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="4" data-type="number">1m Flaps <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="5" data-type="number">5m Flaps <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="6" data-type="number">1h Flaps <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="7" data-type="number">12h Flaps <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="8" data-type="number">24h Flaps <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="9" data-type="number">Total Transitions <span class="sort-arrow">▲▼</span></th>
        </tr>
        </thead>
        <tbody id="flap-data">
"""
        
        # Sort by severity (problems first, like BGP)
        sorted_ports = sorted(all_ports, key=lambda x: (
            0 if x['status'] == FlapStatus.FLAPPING else
            1 if x['status'] == FlapStatus.FLAPPED else 2
        ))
        
        # Build table rows using list for O(n) performance instead of O(n²) string concat
        table_rows = []
        for port in sorted_ports:
            counters = port['counters']
            status_class = f"status-{port['status'].value}"
            
            # Color coding for transition counts
            transition_class = "transition-good"
            if port['total_transitions'] > 50:
                transition_class = "transition-critical"
            elif port['total_transitions'] > 10:
                transition_class = "transition-warning"
                
            table_rows.append(f"""
        <tr data-status="{port['status'].value}">
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
        </tr>""")
        
        html_content += ''.join(table_rows)
        
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
            allRows = Array.from(document.querySelectorAll('#flap-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
            
            // Initialize table sorting
            initTableSorting();
            
            // Initialize device search
            populateDeviceList();
            initDeviceSearch();
        });
        
        function setupCardEvents() {
            // Check if elements exist
            const totalDevicesCard = document.getElementById('total-devices-card');
            const totalPortsCard = document.getElementById('total-ports-card');
            
            if (totalDevicesCard) {
                totalDevicesCard.addEventListener('click', function() {
                    filterPorts('TOTAL');
                });
            }
            
            if (totalPortsCard) {
                totalPortsCard.addEventListener('click', function() {
                    if (parseInt(document.getElementById('total-ports').textContent) > 0) {
                        filterPorts('TOTAL');
                    }
                });
            }
            
            document.getElementById('stable-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('stable-ports').textContent) > 0) {
                    filterPorts('STABLE');
                }
            });
            
            document.getElementById('problematic-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('problematic-ports').textContent) > 0) {
                    filterPorts('PROBLEMATIC');
                }
            });
            
            document.getElementById('stability-card').addEventListener('click', function() {
                console.log('LINK FLAP: Stability clicked');
                filterPorts('TOTAL'); // Stability ratio shows all ports
            });
        }
        
        function filterPorts(filterType) {
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
            
            if (filterType === 'STABLE') {
                filteredRows = allRows.filter(row => row.dataset.status === 'ok');
                filterText = 'Showing ' + filteredRows.length + ' Stable Ports';
                document.getElementById('stable-card').classList.add('active');
            } else if (filterType === 'PROBLEMATIC') {
                filteredRows = allRows.filter(row => 
                    row.dataset.status === 'flapping' || 
                    row.dataset.status === 'flapped'
                );
                filterText = 'Showing ' + filteredRows.length + ' Problematic Ports';
                document.getElementById('problematic-card').classList.add('active');
            } else if (filterType === 'TOTAL') {
                filteredRows = allRows;
                document.getElementById('total-ports-card').classList.add('active');
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
            document.getElementById('filter-text').textContent = 'Showing interfaces for device: ' + deviceName + ' (' + matchCount + ' interfaces)';
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
                    sortFlapTable(column, tableSortState.direction, type);
                });
            });
        }
        
        function sortFlapTable(columnIndex, direction, type) {
            const table = document.getElementById('flap-table');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.rows);
            
            rows.sort((a, b) => {
                let aVal = a.cells[columnIndex].textContent.trim();
                let bVal = b.cells[columnIndex].textContent.trim();
                
                // Extract actual text for status columns (remove HTML)
                if (type === 'flap-status') {
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
                    case 'flap-status':
                        result = compareFlapStatus(aVal, bVal);
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
        
        function compareFlapStatus(a, b) {
            const priority = {
                'FLAPPING': 0,
                'FLAPPED': 1,
                'OK': 2
            };
            
            return (priority[a] || 3) - (priority[b] || 3);
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
                const filename = `Link_Flap_Analysis_Report_${dateStr}_${timeStr}.csv`;
                
                // Create CSV header
                const headers = [
                    'Device',
                    'Port',
                    'Current Status',
                    'Last 30 Seconds',
                    'Last 5 Minutes', 
                    'Last 24 Hours',
                    'Total Transitions'
                ];
                
                let csvContent = headers.join(',') + '\\n';
                
                // Get table data (only visible rows)
                const table = document.getElementById('flap-table');
                const tbody = table.querySelector('tbody');
                const rows = tbody.querySelectorAll('tr');
                
                // Add summary stats as comments
                csvContent += `# Link Flap Analysis Summary Report\\n`;
                csvContent += `# Generated: ${now.toLocaleString()}\\n`;
                csvContent += `# Total Devices: ${document.getElementById('total-devices').textContent}\\n`;
                csvContent += `# Total Ports: ${document.getElementById('total-ports').textContent}\\n`;
                csvContent += `# Stable Ports: ${document.getElementById('stable-ports').textContent}\\n`;
                csvContent += `# Problematic Ports: ${document.getElementById('problematic-ports').textContent}\\n`;
                csvContent += `# Stability Ratio: ${document.getElementById('stability-ratio').textContent}\\n`;
                csvContent += `#\\n`;
                
                // Process each visible row
                rows.forEach(row => {
                    if (row.style.display !== 'none') {
                        const cells = row.querySelectorAll('td');
                        if (cells.length >= 7) {
                            const rowData = [
                                cells[0].textContent.trim(), // Device
                                cells[1].textContent.trim(), // Port
                                cells[2].querySelector('span') ? cells[2].querySelector('span').textContent.trim() : cells[2].textContent.trim(), // Status
                                cells[3].textContent.trim(), // 30 sec
                                cells[4].textContent.trim(), // 5 min
                                cells[5].textContent.trim(), // 24 hrs
                                cells[6].textContent.trim()  // Total
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
</html>"""
        
        with open(output_file, "w") as f:
            f.write(html_content)

if __name__ == "__main__":
    analyzer = LinkFlapAnalyzer()
    print("Link Flap analyzer initialized")
    print(f"Monitoring {len(analyzer.carrier_transitions_stats)} ports")
