#!/usr/bin/env python3
"""
Optical Diagnostics Analysis Module for LLDPq
Advanced SFP/QSFP monitoring and cable health assessment
"""

import json
import time
import re
import os
from datetime import datetime
from typing import Dict, List, Any, Optional
from enum import Enum

class OpticalHealth(Enum):
    EXCELLENT = "excellent"
    GOOD = "good"
    WARNING = "warning"
    CRITICAL = "critical"
    UNKNOWN = "unknown"

class OpticalAnalyzer:
    # Industry standard optical power thresholds (dBm)
    DEFAULT_THRESHOLDS = {
        "rx_power_min_dbm": -14.0,      # Minimum receive power
        "rx_power_max_dbm": 3.0,        # Maximum receive power
        "tx_power_min_dbm": -11.0,      # Minimum transmit power
        "tx_power_max_dbm": 4.0,        # Maximum transmit power
        "temperature_max_c": 70.0,      # Maximum operating temperature
        "temperature_min_c": 0.0,       # Minimum operating temperature
        "voltage_min_v": 3.0,           # Minimum supply voltage
        "voltage_max_v": 3.6,           # Maximum supply voltage
        "bias_current_max_ma": 100.0,   # Maximum laser bias current
        "link_margin_min_db": 3.0       # Minimum acceptable link margin
    }
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.optical_history = {}  # port -> historical readings
        self.current_optical_stats = {}  # port -> current optical status
        self.thresholds = self.DEFAULT_THRESHOLDS.copy()
        
        # Load historical data
        self.load_optical_history()
    
    def load_optical_history(self):
        """Load historical optical data"""
        try:
            with open(f"{self.data_dir}/optical_history.json", "r") as f:
                data = json.load(f)
                self.optical_history = data.get("optical_history", {})
                self.current_optical_stats = data.get("current_optical_stats", {})
        except (FileNotFoundError, json.JSONDecodeError):
            pass
    
    def save_optical_history(self):
        """Save optical history to file"""
        try:
            data = {
                "optical_history": self.optical_history,
                "current_optical_stats": self.current_optical_stats,
                "last_update": time.time()
            }
            with open(f"{self.data_dir}/optical_history.json", "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Error saving optical history: {e}")
    
    def parse_optical_data(self, optical_data: str) -> Dict[str, float]:
        """Parse optical output (NVUE transceiver commands) for optical parameters"""
        optical_params = {
            'rx_power_dbm': None,
            'tx_power_dbm': None,
            'temperature_c': None,
            'voltage_v': None,
            'bias_current_ma': None
        }
        
        # Track channel data for averaging
        rx_powers = []
        tx_powers = []
        bias_currents = []
        
        lines = optical_data.strip().split('\n')
        for line in lines:
            line = line.strip()
            
            # Parse temperature (NVUE format: "temperature : 48.71 degrees C / 119.69 degrees F")
            temp_match = re.search(r'temperature\s*:\s*([\d.-]+)\s*degrees?\s*C', line)
            if temp_match:
                optical_params['temperature_c'] = float(temp_match.group(1))
            
            # Parse voltage (NVUE format: "voltage : 3.2688 V")
            voltage_match = re.search(r'voltage\s*:\s*([\d.-]+)\s*V', line)
            if voltage_match:
                optical_params['voltage_v'] = float(voltage_match.group(1))
            
            # Parse multi-channel RX power (NVUE format: "ch-1-rx-power : 1.7055 mW / 2.32 dBm")
            rx_power_match = re.search(r'ch-\d+-rx-power\s*:\s*[\d.-]+\s*mW\s*/\s*([-\d.]+)\s*dBm', line)
            if rx_power_match:
                rx_powers.append(float(rx_power_match.group(1)))
            
            # Parse multi-channel TX power (NVUE format: "ch-1-tx-power : 1.1706 mW / 0.68 dBm")
            tx_power_match = re.search(r'ch-\d+-tx-power\s*:\s*[\d.-]+\s*mW\s*/\s*([-\d.]+)\s*dBm', line)
            if tx_power_match:
                tx_powers.append(float(tx_power_match.group(1)))
            
            # Parse multi-channel bias current (NVUE format: "ch-1-tx-bias-current : 7.056 mA")
            bias_match = re.search(r'ch-\d+-tx-bias-current\s*:\s*([\d.-]+)\s*mA', line)
            if bias_match:
                bias_currents.append(float(bias_match.group(1)))
        
        # Average multi-channel values
        if rx_powers:
            optical_params['rx_power_dbm'] = sum(rx_powers) / len(rx_powers)
        if tx_powers:
            optical_params['tx_power_dbm'] = sum(tx_powers) / len(tx_powers)
        if bias_currents:
            optical_params['bias_current_ma'] = sum(bias_currents) / len(bias_currents)
        
        return optical_params
    
    def calculate_link_margin(self, rx_power_dbm: float) -> float:
        """Calculate optical link margin"""
        if rx_power_dbm is None:
            return 0.0
        
        # Link margin = RX Power - Minimum sensitivity threshold
        # Using -14 dBm as a conservative minimum sensitivity for most optics
        min_sensitivity = self.thresholds['rx_power_min_dbm']
        return rx_power_dbm - min_sensitivity
    
    def assess_optical_health(self, optical_params: Dict[str, float]) -> OpticalHealth:
        """Assess optical health based on parameters"""
        rx_power = optical_params.get('rx_power_dbm')
        tx_power = optical_params.get('tx_power_dbm')
        temperature = optical_params.get('temperature_c')
        voltage = optical_params.get('voltage_v')
        bias_current = optical_params.get('bias_current_ma')
        
        # No optical data available
        if all(v is None for v in [rx_power, tx_power, temperature]):
            return OpticalHealth.UNKNOWN
        
        # Critical conditions (any one triggers critical status)
        if rx_power is not None and rx_power < self.thresholds['rx_power_min_dbm']:
            return OpticalHealth.CRITICAL
        if rx_power is not None and rx_power > self.thresholds['rx_power_max_dbm']:
            return OpticalHealth.CRITICAL
        if temperature is not None and temperature > self.thresholds['temperature_max_c']:
            return OpticalHealth.CRITICAL
        if temperature is not None and temperature < self.thresholds['temperature_min_c']:
            return OpticalHealth.CRITICAL
        if voltage is not None and (voltage < self.thresholds['voltage_min_v'] or voltage > self.thresholds['voltage_max_v']):
            return OpticalHealth.CRITICAL
        if bias_current is not None and bias_current > self.thresholds['bias_current_max_ma']:
            return OpticalHealth.CRITICAL
        
        # Warning conditions
        warning_count = 0
        
        # Low link margin warning
        if rx_power is not None:
            link_margin = self.calculate_link_margin(rx_power)
            if link_margin < self.thresholds['link_margin_min_db']:
                warning_count += 1
        
        # TX power near limits
        if tx_power is not None:
            if tx_power < self.thresholds['tx_power_min_dbm'] + 1.0 or tx_power > self.thresholds['tx_power_max_dbm'] - 1.0:
                warning_count += 1
        
        # Temperature approaching limits
        if temperature is not None:
            if temperature > self.thresholds['temperature_max_c'] - 10.0:
                warning_count += 1
        
        # Return health status
        if warning_count >= 2:
            return OpticalHealth.WARNING
        elif warning_count == 1:
            return OpticalHealth.GOOD
        else:
            return OpticalHealth.EXCELLENT
    
    def update_optical_stats(self, port_name: str, optical_data: str):
        """Update optical statistics for a port"""
        optical_params = self.parse_optical_data(optical_data)
        health = self.assess_optical_health(optical_params)
        
        # Calculate additional metrics
        link_margin_db = None
        if optical_params['rx_power_dbm'] is not None:
            link_margin_db = self.calculate_link_margin(optical_params['rx_power_dbm'])
        
        # Store current stats
        self.current_optical_stats[port_name] = {
            'health_status': health.value,
            'rx_power_dbm': optical_params['rx_power_dbm'],
            'tx_power_dbm': optical_params['tx_power_dbm'],
            'temperature_c': optical_params['temperature_c'],
            'voltage_v': optical_params['voltage_v'],
            'bias_current_ma': optical_params['bias_current_ma'],
            'link_margin_db': link_margin_db,
            'last_updated': time.time(),
            'raw_data': optical_data[:500]  # Store first 500 chars for debugging
        }
        
        # Store in history
        if port_name not in self.optical_history:
            self.optical_history[port_name] = []
        
        # Add to history (keep last 100 entries)
        history_entry = {
            'timestamp': time.time(),
            'health': health.value,
            'rx_power_dbm': optical_params['rx_power_dbm'],
            'tx_power_dbm': optical_params['tx_power_dbm'],
            'temperature_c': optical_params['temperature_c'],
            'link_margin_db': link_margin_db
        }
        
        self.optical_history[port_name].append(history_entry)
        if len(self.optical_history[port_name]) > 100:
            self.optical_history[port_name] = self.optical_history[port_name][-100:]
    
    def get_optical_summary(self) -> Dict[str, Any]:
        """Get optical analysis summary"""
        summary = {
            "total_ports": 0,  # Will calculate as sum of classified ports
            "excellent_ports": [],
            "good_ports": [],
            "warning_ports": [],
            "critical_ports": [],
            "unknown_ports": []
        }
        
        for port_name, stats in self.current_optical_stats.items():
            health = stats.get('health_status', 'unknown')
            
            port_info = {
                "port": port_name,
                "health": health,
                "rx_power_dbm": stats.get('rx_power_dbm'),
                "tx_power_dbm": stats.get('tx_power_dbm'),
                "temperature_c": stats.get('temperature_c'),
                "link_margin_db": stats.get('link_margin_db'),
                "voltage_v": stats.get('voltage_v'),
                "bias_current_ma": stats.get('bias_current_ma')
            }
            
            if health == OpticalHealth.EXCELLENT.value:
                summary["excellent_ports"].append(port_info)
            elif health == OpticalHealth.GOOD.value:
                summary["good_ports"].append(port_info)
            elif health == OpticalHealth.WARNING.value:
                summary["warning_ports"].append(port_info)
            elif health == OpticalHealth.CRITICAL.value:
                summary["critical_ports"].append(port_info)
            else:
                summary["unknown_ports"].append(port_info)
        
        # Calculate total as sum of classified ports (exclude unknown)
        summary["total_ports"] = (len(summary["excellent_ports"]) + 
                                 len(summary["good_ports"]) + 
                                 len(summary["warning_ports"]) + 
                                 len(summary["critical_ports"]))
        
        return summary
    
    def detect_optical_anomalies(self) -> List[Dict[str, Any]]:
        """Detect optical-related anomalies"""
        anomalies = []
        
        for port_name, stats in self.current_optical_stats.items():
            health = OpticalHealth(stats.get('health_status', 'unknown'))
            
            if health == OpticalHealth.CRITICAL:
                # Critical optical issues
                rx_power = stats.get('rx_power_dbm')
                temperature = stats.get('temperature_c')
                
                if rx_power is not None and rx_power < self.thresholds['rx_power_min_dbm']:
                    anomalies.append({
                        "port": port_name,
                        "type": "LOW_OPTICAL_POWER",
                        "severity": "critical",
                        "message": f"RX power too low: {rx_power:.2f} dBm (threshold: {self.thresholds['rx_power_min_dbm']} dBm)",
                        "action": "Check fiber connection, clean connectors, or replace cable",
                        "rx_power_dbm": rx_power
                    })
                
                if temperature is not None and temperature > self.thresholds['temperature_max_c']:
                    anomalies.append({
                        "port": port_name,
                        "type": "HIGH_TEMPERATURE",
                        "severity": "critical",
                        "message": f"SFP temperature too high: {temperature:.1f}°C (threshold: {self.thresholds['temperature_max_c']}°C)",
                        "action": "Check cooling, reduce load, or replace SFP module",
                        "temperature_c": temperature
                    })
            
            elif health == OpticalHealth.WARNING:
                # Warning level issues
                link_margin = stats.get('link_margin_db', 0)
                if link_margin < self.thresholds['link_margin_min_db']:
                    anomalies.append({
                        "port": port_name,
                        "type": "LOW_LINK_MARGIN",
                        "severity": "warning",
                        "message": f"Low link margin: {link_margin:.2f} dB (threshold: {self.thresholds['link_margin_min_db']} dB)",
                        "action": "Monitor closely, schedule proactive maintenance",
                        "link_margin_db": link_margin
                    })
        
        return anomalies
    
    def get_recommended_action(self, port_info: Dict[str, Any]) -> str:
        """Get recommended action for a port based on its health status and parameters"""
        health = port_info.get('health', 'unknown')
        
        if health == OpticalHealth.EXCELLENT.value:
            return ""  # No action needed for excellent health
        
        if health == OpticalHealth.CRITICAL.value:
            rx_power = port_info.get('rx_power_dbm')
            temperature = port_info.get('temperature_c')
            
            if rx_power is not None and rx_power < self.thresholds['rx_power_min_dbm']:
                return "Check fiber connection, clean connectors, or replace cable"
            elif temperature is not None and temperature > self.thresholds['temperature_max_c']:
                return "Check cooling, reduce load, or replace SFP module"
            else:
                return "Investigate critical optical parameters immediately"
        
        if health == OpticalHealth.WARNING.value:
            link_margin = port_info.get('link_margin_db', 0)
            if link_margin < self.thresholds['link_margin_min_db']:
                return "Monitor closely, schedule proactive maintenance"
            else:
                return "Monitor optical parameters regularly"
        
        if health == OpticalHealth.GOOD.value:
            return "Continue regular monitoring"
        
        return "Check optical diagnostics availability"
    
    def export_optical_data_for_web(self, output_file: str):
        """Export optical data for web display - EXACT same styling as BGP/Link Flap"""
        summary = self.get_optical_summary()
        anomalies = self.detect_optical_anomalies()
        
        html_content = f"""<!DOCTYPE html>
<html>
<head>
    <title>Optical Diagnostics Analysis</title>
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
        .metric {{ font-size: 24px; font-weight: bold; }}
        .optical-excellent {{ color: #4caf50; font-weight: bold; }}
        .optical-good {{ color: #8bc34a; font-weight: bold; }}
        .optical-warning {{ color: #ff9800; font-weight: bold; }}
        .optical-critical {{ color: #f44336; font-weight: bold; }}
        .optical-unknown {{ color: gray; }}
        .optical-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; table-layout: fixed; }}
        .optical-table th, .optical-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        
        /* Column width specifications */
        .optical-table th:nth-child(1), .optical-table td:nth-child(1) {{ width: 14%; }} /* Port */
        .optical-table th:nth-child(2), .optical-table td:nth-child(2) {{ width: 8%; }}  /* Health */
        .optical-table th:nth-child(3), .optical-table td:nth-child(3) {{ width: 10%; }} /* RX Power */
        .optical-table th:nth-child(4), .optical-table td:nth-child(4) {{ width: 10%; }} /* TX Power */
        .optical-table th:nth-child(5), .optical-table td:nth-child(5) {{ width: 10%; }} /* Temperature */
        .optical-table th:nth-child(6), .optical-table td:nth-child(6) {{ width: 10%; }} /* Link Margin */
        .optical-table th:nth-child(7), .optical-table td:nth-child(7) {{ width: 9%; }}  /* Voltage */
        .optical-table th:nth-child(8), .optical-table td:nth-child(8) {{ width: 11%; }} /* Bias Current */
        .optical-table th:nth-child(9), .optical-table td:nth-child(9) {{ width: 18%; word-wrap: break-word; }} /* Recommended Action */
        
        .optical-table th {{ background-color: #f2f2f2; font-weight: bold; }}
        .optical-table td {{ word-wrap: break-word; overflow-wrap: break-word; }}
        .anomaly-card {{ 
            margin: 10px 0; 
            padding: 15px; 
            border-radius: 8px; 
            border-left: 4px solid #f44336; 
            background-color: #ffebee; 
        }}
        .warning-card {{ 
            border-left-color: #ff9800; 
            background-color: #fff3e0; 
        }}
        
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
        
        /* Sortable table styling */
        .sortable {{ cursor: pointer; user-select: none; position: relative; padding-right: 20px; }}
        .sortable:hover {{ background-color: #f5f5f5; }}
        .sort-arrow {{ font-size: 10px; color: #999; margin-left: 5px; opacity: 0.5; }}
        .sortable.asc .sort-arrow::before {{ content: '▲'; color: #b57614; opacity: 1; }}
        .sortable.desc .sort-arrow::before {{ content: '▼'; color: #b57614; opacity: 1; }}
        .sortable.asc .sort-arrow, .sortable.desc .sort-arrow {{ opacity: 1; }}
    </style>
</head>
<body>
    <h1></h1>
    <h1><font color="#b57614">Optical Diagnostics Analysis</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <h2>Summary</h2>
    <div class="summary-grid">
        <div class="summary-card" id="total-ports-card">
            <div class="metric" id="total-ports">{summary['total_ports']}</div>
            <div>Total Ports</div>
        </div>
        <div class="summary-card" id="excellent-card">
            <div class="metric optical-excellent" id="excellent-ports">{len(summary['excellent_ports'])}</div>
            <div>Excellent</div>
        </div>
        <div class="summary-card" id="good-card">
            <div class="metric optical-good" id="good-ports">{len(summary['good_ports'])}</div>
            <div>Good</div>
        </div>
        <div class="summary-card" id="warning-card">
            <div class="metric optical-warning" id="warning-ports">{len(summary['warning_ports'])}</div>
            <div>Warning</div>
        </div>
        <div class="summary-card" id="critical-card">
            <div class="metric optical-critical" id="critical-ports">{len(summary['critical_ports'])}</div>
            <div>Critical</div>
        </div>
    </div>
    
    <div id="filter-info" class="filter-info">
        <span id="filter-text"></span>
        <button onclick="clearFilter()" style="margin-left: 10px; padding: 2px 8px; background: #1976d2; color: white; border: none; border-radius: 3px; cursor: pointer;">Show All</button>
    </div>"""
        
        # Create one unified table for all ports (sorted by health - problems first)
        all_ports = summary['critical_ports'] + summary['warning_ports'] + summary['good_ports'] + summary['excellent_ports']
        
        html_content += f"""
    <h2>Optical Port Status ({len(all_ports)} ports)</h2>
    <table class="optical-table" id="optical-table">
        <thead>
        <tr>
            <th class="sortable" data-column="0" data-type="port">Port <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="1" data-type="optical-health">Health <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="2" data-type="optical-power">RX Power (dBm) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="3" data-type="optical-power">TX Power (dBm) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="4" data-type="temperature">Temperature (°C) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="5" data-type="optical-power">Link Margin (dB) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="6" data-type="voltage">Voltage (V) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="7" data-type="current">Bias Current (mA) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="8" data-type="string">Recommended Action <span class="sort-arrow">▲▼</span></th>
        </tr>
        </thead>
        <tbody id="optical-data">"""
        
        for port in all_ports:
            rx_power = f"{port['rx_power_dbm']:.2f}" if port['rx_power_dbm'] is not None else "N/A"
            tx_power = f"{port['tx_power_dbm']:.2f}" if port['tx_power_dbm'] is not None else "N/A"
            temperature = f"{port['temperature_c']:.1f}" if port['temperature_c'] is not None else "N/A"
            link_margin = f"{port['link_margin_db']:.2f}" if port['link_margin_db'] is not None else "N/A"
            voltage = f"{port['voltage_v']:.2f}" if port['voltage_v'] is not None else "N/A"
            bias_current = f"{port['bias_current_ma']:.2f}" if port['bias_current_ma'] is not None else "N/A"
            recommended_action = self.get_recommended_action(port)
            health_class = f"optical-{port['health']}"
            
            html_content += f"""
        <tr data-health="{port['health']}">
            <td>{port['port']}</td>
            <td><span class="{health_class}">{port['health'].upper()}</span></td>
            <td>{rx_power}</td>
            <td>{tx_power}</td>
            <td>{temperature}</td>
            <td>{link_margin}</td>
            <td>{voltage}</td>
            <td>{bias_current}</td>
            <td>{recommended_action}</td>
        </tr>"""
        
        html_content += """
        </tbody>
    </table>"""
        
        html_content += f"""
    <h2>Optical Health Thresholds</h2>
    <table class="optical-table">
        <tr><th>Parameter</th><th>Min Threshold</th><th>Max Threshold</th><th>Description</th></tr>
        <tr><td>RX Power</td><td>{self.thresholds['rx_power_min_dbm']} dBm</td><td>{self.thresholds['rx_power_max_dbm']} dBm</td><td>Received optical power range</td></tr>
        <tr><td>TX Power</td><td>{self.thresholds['tx_power_min_dbm']} dBm</td><td>{self.thresholds['tx_power_max_dbm']} dBm</td><td>Transmitted optical power range</td></tr>
        <tr><td>Temperature</td><td>{self.thresholds['temperature_min_c']}°C</td><td>{self.thresholds['temperature_max_c']}°C</td><td>SFP/QSFP operating temperature</td></tr>
        <tr><td>Voltage</td><td>{self.thresholds['voltage_min_v']}V</td><td>{self.thresholds['voltage_max_v']}V</td><td>Supply voltage range</td></tr>
        <tr><td>Link Margin</td><td>{self.thresholds['link_margin_min_db']} dB</td><td>-</td><td>Minimum acceptable link budget margin</td></tr>
        <tr><td>Bias Current</td><td>-</td><td>{self.thresholds['bias_current_max_ma']} mA</td><td>Maximum laser bias current</td></tr>
    </table>
"""
        
        html_content += """
    <script>
        // Filter functionality
        let currentFilter = 'ALL';
        let allRows = [];
        
        document.addEventListener('DOMContentLoaded', function() {
            // Store all table rows for filtering
            allRows = Array.from(document.querySelectorAll('#optical-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
            
            // Initialize table sorting
            initTableSorting();
        });
        
        function setupCardEvents() {
            document.getElementById('total-ports-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('total-ports').textContent) > 0) {
                    filterPorts('TOTAL');
                }
            });
            
            document.getElementById('excellent-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('excellent-ports').textContent) > 0) {
                    filterPorts('EXCELLENT');
                }
            });
            
            document.getElementById('good-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('good-ports').textContent) > 0) {
                    filterPorts('GOOD');
                }
            });
            
            document.getElementById('warning-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('warning-ports').textContent) > 0) {
                    filterPorts('WARNING');
                }
            });
            
            document.getElementById('critical-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('critical-ports').textContent) > 0) {
                    filterPorts('CRITICAL');
                }
            });
        }
        
        function filterPorts(filterType) {
            currentFilter = filterType;
            
            // Clear active state from all cards
            document.querySelectorAll('.summary-card').forEach(card => {
                card.classList.remove('active');
            });
            
            let filteredRows = allRows;
            let filterText = '';
            
            if (filterType === 'EXCELLENT') {
                filteredRows = allRows.filter(row => row.dataset.health === 'excellent');
                filterText = `Showing ${filteredRows.length} Excellent Ports`;
                document.getElementById('excellent-card').classList.add('active');
            } else if (filterType === 'GOOD') {
                filteredRows = allRows.filter(row => row.dataset.health === 'good');
                filterText = `Showing ${filteredRows.length} Good Ports`;
                document.getElementById('good-card').classList.add('active');
            } else if (filterType === 'WARNING') {
                filteredRows = allRows.filter(row => row.dataset.health === 'warning');
                filterText = `Showing ${filteredRows.length} Warning Ports`;
                document.getElementById('warning-card').classList.add('active');
            } else if (filterType === 'CRITICAL') {
                filteredRows = allRows.filter(row => row.dataset.health === 'critical');
                filterText = `Showing ${filteredRows.length} Critical Ports`;
                document.getElementById('critical-card').classList.add('active');
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
            
            // Show all rows
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
                    sortOpticalTable(column, tableSortState.direction, type);
                });
            });
        }
        
        function sortOpticalTable(columnIndex, direction, type) {
            const table = document.getElementById('optical-table');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.rows);
            
            rows.sort((a, b) => {
                let aVal = a.cells[columnIndex].textContent.trim();
                let bVal = b.cells[columnIndex].textContent.trim();
                
                // Extract actual text for health columns (remove HTML)
                if (type === 'optical-health') {
                    aVal = a.cells[columnIndex].querySelector('span')?.textContent || aVal;
                    bVal = b.cells[columnIndex].querySelector('span')?.textContent || bVal;
                }
                
                let result = 0;
                
                switch(type) {
                    case 'optical-power':
                    case 'temperature':
                    case 'voltage':
                    case 'current':
                        result = compareOpticalValue(aVal, bVal);
                        break;
                    case 'port':
                        result = comparePort(aVal, bVal);
                        break;
                    case 'optical-health':
                        result = compareOpticalHealth(aVal, bVal);
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
        
        function compareOpticalHealth(a, b) {
            const priority = {
                'CRITICAL': 0,
                'WARNING': 1,
                'GOOD': 2,
                'EXCELLENT': 3,
                'UNKNOWN': 4
            };
            
            return (priority[a] || 5) - (priority[b] || 5);
        }
        
        function compareOpticalValue(a, b) {
            // Handle 'N/A' values
            if (a === 'N/A' && b === 'N/A') return 0;
            if (a === 'N/A') return 1;
            if (b === 'N/A') return -1;
            
            // Parse numerical values (handle negative numbers)
            const numA = parseFloat(a);
            const numB = parseFloat(b);
            
            if (isNaN(numA) && isNaN(numB)) return 0;
            if (isNaN(numA)) return 1;
            if (isNaN(numB)) return -1;
            
            return numA - numB;
        }
    </script>
</body>
</html>"""
        
        with open(output_file, "w") as f:
            f.write(html_content)

if __name__ == "__main__":
    analyzer = OpticalAnalyzer()
    print("Optical analyzer initialized")
    print(f"Monitoring {len(analyzer.current_optical_stats)} ports")