#!/usr/bin/env python3
"""
Hardware Health Analysis Module for LLDPq
Professional hardware monitoring and analysis
"""

import json
import time
import re
import os
import math
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional
from enum import Enum

class HardwareGrade(Enum):
    """Hardware health grades"""
    EXCELLENT = "excellent"
    GOOD = "good"  
    WARNING = "warning"
    CRITICAL = "critical"
    UNKNOWN = "unknown"

class HardwareAnalyzer:
    """Professional Hardware Analysis System"""
    
    # Hardware health thresholds
    DEFAULT_CONFIG = {
        "cpu_temp_excellent": 60,      # Below 60°C
        "cpu_temp_good": 70,           # 60-70°C
        "cpu_temp_warning": 80,        # 70-80°C
        "asic_temp_excellent": 70,     # Below 70°C
        "asic_temp_good": 80,          # 70-80°C
        "asic_temp_warning": 90,       # 80-90°C
        "memory_excellent": 60,        # Below 60%
        "memory_good": 75,             # 60-75%
        "memory_warning": 85,          # 75-85%
        "cpu_load_excellent": 1.0,     # Below 1.0
        "cpu_load_good": 2.0,          # 1.0-2.0
        "cpu_load_warning": 3.0,       # 2.0-3.0
        "psu_efficiency_excellent": 90, # Above 90%
        "psu_efficiency_good": 85,      # 85-90%
        "psu_efficiency_warning": 80,   # 80-85%
    }
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.hardware_history = {}
        self.current_hardware_stats = {}
        self.config = self.DEFAULT_CONFIG.copy()
        
        # Ensure hardware-data directory exists
        os.makedirs(f"{self.data_dir}/hardware-data", exist_ok=True)
        
        # Load historical data
        self.load_hardware_history()
    
    def load_hardware_history(self):
        """Load historical hardware data from file"""
        try:
            with open(f"{self.data_dir}/hardware_history.json", "r") as f:
                data = json.load(f)
                self.hardware_history = data.get("hardware_history", {})
                self.current_hardware_stats = data.get("current_hardware_stats", {})
        except (FileNotFoundError, json.JSONDecodeError):
            print("No previous hardware history found, starting fresh")
    
    def save_hardware_history(self):
        """Save hardware history to file"""
        try:
            data = {
                "hardware_history": self.hardware_history,
                "current_hardware_stats": self.current_hardware_stats,
                "last_update": time.time(),
                "config": self.config
            }
            with open(f"{self.data_dir}/hardware_history.json", "w") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"Error saving hardware history: {e}")
    
    def get_hardware_grade(self, metric_type: str, value: float) -> HardwareGrade:
        """Determine hardware quality grade for a specific metric"""
        if metric_type == "cpu_temp":
            if value < self.config["cpu_temp_excellent"]:
                return HardwareGrade.EXCELLENT
            elif value < self.config["cpu_temp_good"]:
                return HardwareGrade.GOOD
            elif value < self.config["cpu_temp_warning"]:
                return HardwareGrade.WARNING
            else:
                return HardwareGrade.CRITICAL
                
        elif metric_type == "asic_temp":
            if value < self.config["asic_temp_excellent"]:
                return HardwareGrade.EXCELLENT
            elif value < self.config["asic_temp_good"]:
                return HardwareGrade.GOOD
            elif value < self.config["asic_temp_warning"]:
                return HardwareGrade.WARNING
            else:
                return HardwareGrade.CRITICAL
                
        elif metric_type == "memory":
            if value < self.config["memory_excellent"]:
                return HardwareGrade.EXCELLENT
            elif value < self.config["memory_good"]:
                return HardwareGrade.GOOD
            elif value < self.config["memory_warning"]:
                return HardwareGrade.WARNING
            else:
                return HardwareGrade.CRITICAL
                
        elif metric_type == "cpu_load":
            if value < self.config["cpu_load_excellent"]:
                return HardwareGrade.EXCELLENT
            elif value < self.config["cpu_load_good"]:
                return HardwareGrade.GOOD
            elif value < self.config["cpu_load_warning"]:
                return HardwareGrade.WARNING
            else:
                return HardwareGrade.CRITICAL
                
        elif metric_type == "psu_efficiency":
            if value > self.config["psu_efficiency_excellent"]:
                return HardwareGrade.EXCELLENT
            elif value > self.config["psu_efficiency_good"]:
                return HardwareGrade.GOOD
            elif value > self.config["psu_efficiency_warning"]:
                return HardwareGrade.WARNING
            else:
                return HardwareGrade.CRITICAL
        
        return HardwareGrade.UNKNOWN
    
    def get_overall_device_health(self, device_data: Dict[str, Any]) -> HardwareGrade:
        """Calculate overall device health grade"""
        grades = []
        
        # CPU Temperature
        cpu_temps = [temp for name, temp in device_data.get("temperatures", {}).items() if "CPU" in name]
        if cpu_temps:
            grades.append(self.get_hardware_grade("cpu_temp", max(cpu_temps)))
        
        # ASIC Temperature
        asic_temps = [temp for name, temp in device_data.get("temperatures", {}).items() if "ASIC" in name]
        if asic_temps:
            grades.append(self.get_hardware_grade("asic_temp", max(asic_temps)))
        
        # Memory Usage
        memory_usage = device_data.get("resources", {}).get("memory", {}).get("usage_percent", 0)
        if memory_usage > 0:
            grades.append(self.get_hardware_grade("memory", memory_usage))
        
        # CPU Load
        cpu_load = device_data.get("resources", {}).get("cpu", {}).get("load_5min", 0)
        if cpu_load > 0:
            grades.append(self.get_hardware_grade("cpu_load", cpu_load))
        
        # PSU Efficiency
        psu_efficiencies = [psu.get("efficiency", 0) for psu in device_data.get("power_analysis", {}).values()]
        if psu_efficiencies:
            avg_efficiency = sum(psu_efficiencies) / len(psu_efficiencies)
            grades.append(self.get_hardware_grade("psu_efficiency", avg_efficiency))
        
        if not grades:
            return HardwareGrade.UNKNOWN
        
        # Overall grade is the worst of all individual grades
        grade_priority = {
            HardwareGrade.CRITICAL: 0,
            HardwareGrade.WARNING: 1,
            HardwareGrade.GOOD: 2,
            HardwareGrade.EXCELLENT: 3,
            HardwareGrade.UNKNOWN: 4
        }
        
        return min(grades, key=lambda g: grade_priority[g])
    
    def process_device_hardware(self, device_name: str, raw_data: str):
        """Process hardware data for a single device"""
        current_time = time.time()
        
        # Parse raw hardware data (similar to existing implementation)
        device_stats = {
            "device": device_name,
            "timestamp": current_time,
            "temperatures": {},
            "fans": {},
            "power_analysis": {},
            "resources": {
                "memory": {},
                "cpu": {},
                "uptime": "N/A"
            }
        }
        
        # Dummy data for demonstration - replace with actual parsing
        device_stats["temperatures"]["CPU"] = 65.0
        device_stats["temperatures"]["ASIC"] = 75.0
        device_stats["resources"]["memory"]["usage_percent"] = 45.3
        device_stats["resources"]["cpu"]["load_5min"] = 0.85
        device_stats["resources"]["uptime"] = "15 days, 10:30"
        device_stats["power_analysis"]["PSU-1"] = {
            "input_power": 1200,
            "output_power": 1080,
            "efficiency": 90.0,
            "grade": "excellent"
        }
        
        # Calculate overall health
        overall_grade = self.get_overall_device_health(device_stats)
        device_stats["overall_grade"] = overall_grade.value
        
        # Store in current stats
        self.current_hardware_stats[device_name] = device_stats
        
        # Add to history
        if device_name not in self.hardware_history:
            self.hardware_history[device_name] = []
        
        self.hardware_history[device_name].append(device_stats)
        
        # Keep only recent history (last 24 hours)
        cutoff_time = current_time - (24 * 3600)
        self.hardware_history[device_name] = [
            entry for entry in self.hardware_history[device_name]
            if entry['timestamp'] > cutoff_time
        ]
    
    def detect_hardware_anomalies(self) -> List[Dict[str, Any]]:
        """Detect hardware anomalies"""
        anomalies = []
        
        for device_name, stats in self.current_hardware_stats.items():
            # Check for critical conditions
            cpu_temps = [temp for name, temp in stats["temperatures"].items() if "CPU" in name]
            if cpu_temps and max(cpu_temps) > self.config["cpu_temp_warning"]:
                anomalies.append({
                    "device": device_name,
                    "component": "CPU",
                    "type": "HIGH_TEMPERATURE",
                    "severity": "critical" if max(cpu_temps) > 85 else "warning",
                    "message": f"High CPU temperature: {max(cpu_temps):.1f}°C",
                    "action": f"Check cooling system on {device_name}"
                })
            
            # Check memory usage
            memory_usage = stats["resources"].get("memory", {}).get("usage_percent", 0)
            if memory_usage > self.config["memory_warning"]:
                anomalies.append({
                    "device": device_name,
                    "component": "Memory",
                    "type": "HIGH_MEMORY_USAGE",
                    "severity": "critical" if memory_usage > 90 else "warning",
                    "message": f"High memory usage: {memory_usage:.1f}%",
                    "action": f"Investigate memory usage on {device_name}"
                })
        
        return anomalies
    
    def export_hardware_data_for_web(self, output_file: str):
        """Export hardware analysis for web display - same format as BER Analysis"""
        anomalies = self.detect_hardware_anomalies()
        
        # Calculate summary metrics
        summary = {
            'excellent_devices': [],
            'good_devices': [],
            'warning_devices': [],
            'critical_devices': []
        }
        
        # Process each device and determine health grades
        for device_name, device_data in self.current_hardware_stats.items():
            overall_health = HardwareGrade(device_data["overall_grade"])
            device_info = {
                'device': device_name,
                'health_grade': overall_health,
                'data': device_data,
                'timestamp': device_data['timestamp']
            }
            
            if overall_health == HardwareGrade.EXCELLENT:
                summary['excellent_devices'].append(device_info)
            elif overall_health == HardwareGrade.GOOD:
                summary['good_devices'].append(device_info)
            elif overall_health == HardwareGrade.WARNING:
                summary['warning_devices'].append(device_info)
            elif overall_health == HardwareGrade.CRITICAL:
                summary['critical_devices'].append(device_info)
        
        total_devices = len(self.current_hardware_stats)
        
        html_content = f"""<!DOCTYPE html>
<html>
<head>
    <title>Hardware Health Analysis</title>
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
        
        /* Colored card values */
        .card-excellent .metric {{ color: #4caf50; }}
        .card-good .metric {{ color: #8bc34a; }}
        .card-warning .metric {{ color: #ff9800; }}
        .card-critical .metric {{ color: #f44336; }}
        .card-total .metric {{ color: #333; }}
        .card-info .metric {{ color: #2196f3; }}
        .hardware-excellent {{ color: #4caf50; font-weight: bold; }}
        .hardware-good {{ color: #8bc34a; font-weight: bold; }}
        .hardware-warning {{ color: #ff9800; font-weight: bold; }}
        .hardware-critical {{ color: #f44336; font-weight: bold; }}
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
        .hardware-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; table-layout: fixed; }}
        .hardware-table th, .hardware-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; word-wrap: break-word; }}
        .hardware-table th {{ background-color: #f2f2f2; font-weight: bold; }}
        
        /* Column width specifications */
        .hardware-table th:nth-child(1), .hardware-table td:nth-child(1) {{ width: 15%; }} /* Device */
        .hardware-table th:nth-child(2), .hardware-table td:nth-child(2) {{ width: 12%; }} /* Health */
        .hardware-table th:nth-child(3), .hardware-table td:nth-child(3) {{ width: 12%; }} /* CPU Temp */
        .hardware-table th:nth-child(4), .hardware-table td:nth-child(4) {{ width: 12%; }} /* ASIC Temp */
        .hardware-table th:nth-child(5), .hardware-table td:nth-child(5) {{ width: 12%; }} /* Memory */
        .hardware-table th:nth-child(6), .hardware-table td:nth-child(6) {{ width: 12%; }} /* CPU Load */
        .hardware-table th:nth-child(7), .hardware-table td:nth-child(7) {{ width: 12%; }} /* PSU Efficiency */
        .hardware-table th:nth-child(8), .hardware-table td:nth-child(8) {{ width: 13%; }} /* Uptime */
        
        /* Sortable table styling */
        .sortable {{ cursor: pointer; user-select: none; position: relative; padding-right: 20px; }}
        .sortable:hover {{ background-color: #f5f5f5; }}
        .sort-arrow {{ font-size: 10px; color: #999; margin-left: 5px; opacity: 0.5; }}
        .sortable.asc .sort-arrow::before {{ content: '▲'; color: #b57614; opacity: 1; }}
        .sortable.desc .sort-arrow::before {{ content: '▼'; color: #b57614; opacity: 1; }}
        .sortable.asc .sort-arrow, .sortable.desc .sort-arrow {{ opacity: 1; }}
        
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
    <h1><font color="#b57614">Hardware Health Analysis</font></h1>
        <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
        
        <h2>Network Summary</h2>
        <div class="summary-grid">
            <div class="summary-card card-total" id="total-devices-card">
                <div class="metric" id="total-devices">{total_devices}</div>
                <div>Total Devices</div>
            </div>
            <div class="summary-card card-excellent" id="excellent-card">
                <div class="metric" id="excellent-devices">{len(summary['excellent_devices'])}</div>
                <div>Excellent</div>
            </div>
            <div class="summary-card card-good" id="good-card">
                <div class="metric" id="good-devices">{len(summary['good_devices'])}</div>
                <div>Good</div>
            </div>
            <div class="summary-card card-warning" id="warning-card">
                <div class="metric" id="warning-devices">{len(summary['warning_devices'])}</div>
                <div>Warning</div>
            </div>
            <div class="summary-card card-critical" id="critical-card">
                <div class="metric" id="critical-devices">{len(summary['critical_devices'])}</div>
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
            <h2>🔧 Hardware Anomalies Detected ({len(anomalies)})</h2>
"""
            for anomaly in anomalies[:10]:  # Show top 10 anomalies
                severity_class = f"anomaly-{anomaly['severity']}"
                html_content += f"""
            <div class="anomaly-item {severity_class}">
                <strong>{anomaly['device']}</strong> - {anomaly['message']}<br>
                <small><strong>Action:</strong> {anomaly['action']}</small>
            </div>
"""
            html_content += """
        </div>
"""

        # Add detailed table  
        html_content += """
        <h2>Device Hardware Status</h2>
        <table class="hardware-table" id="hardware-table">
            <thead>
                <tr>
                    <th class="sortable" data-column="0" data-type="string">Device <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="1" data-type="hardware-status">Health <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="2" data-type="number">CPU Temp (°C) <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="3" data-type="number">ASIC Temp (°C) <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="4" data-type="number">Memory (%) <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="5" data-type="number">CPU Load <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="6" data-type="number">PSU Efficiency (%) <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="7" data-type="string">Uptime <span class="sort-arrow">▲▼</span></th>
                </tr>
            </thead>
            <tbody id="hardware-data">
"""
        
        # Add all devices to table (sorted by health - problems first)
        all_devices = (summary['critical_devices'] + summary['warning_devices'] + 
                      summary['good_devices'] + summary['excellent_devices'])
        
        for device_info in all_devices:
            device_name = device_info['device']
            health_grade = device_info['health_grade']
            device_data = device_info['data']
            
            # Extract key metrics
            cpu_temps = [temp for name, temp in device_data["temperatures"].items() if "CPU" in name]
            asic_temps = [temp for name, temp in device_data["temperatures"].items() if "ASIC" in name]
            
            cpu_temp_str = f"{max(cpu_temps):.1f}" if cpu_temps else "N/A"
            asic_temp_str = f"{max(asic_temps):.1f}" if asic_temps else "N/A"
            
            memory_usage = device_data["resources"].get("memory", {}).get("usage_percent", 0)
            cpu_load = device_data["resources"].get("cpu", {}).get("load_5min", 0)
            uptime = device_data["resources"].get("uptime", "N/A")
            
            # Calculate average PSU efficiency
            psu_efficiencies = [psu.get("efficiency", 0) for psu in device_data["power_analysis"].values()]
            avg_efficiency = sum(psu_efficiencies) / len(psu_efficiencies) if psu_efficiencies else 0
            
            health_class = f"hardware-{health_grade.value.lower()}"
            
            timestamp = datetime.fromtimestamp(device_info['timestamp']).strftime('%H:%M:%S')
            
            html_content += f"""
                <tr data-status="{health_grade.value.lower()}">
                    <td>{device_name}</td>
                    <td><span class="{health_class}">{health_grade.value.upper()}</span></td>
                    <td>{cpu_temp_str}</td>
                    <td>{asic_temp_str}</td>
                    <td>{memory_usage:.1f}%</td>
                    <td>{cpu_load:.2f}</td>
                    <td>{avg_efficiency:.1f}%</td>
                    <td>{uptime}</td>
                </tr>
"""
        
        html_content += """
            </tbody>
        </table>
        

    <h2>Hardware Health Thresholds</h2>
    <table class="hardware-table">
        <tr><th>Parameter</th><th>Excellent</th><th>Good</th><th>Warning</th><th>Critical</th></tr>
        <tr><td>CPU Temperature</td><td>&lt; 60°C</td><td>60-70°C</td><td>70-80°C</td><td>&gt; 80°C</td></tr>
        <tr><td>ASIC Temperature</td><td>&lt; 70°C</td><td>70-80°C</td><td>80-90°C</td><td>&gt; 90°C</td></tr>
        <tr><td>Memory Usage</td><td>&lt; 60%</td><td>60-75%</td><td>75-85%</td><td>&gt; 85%</td></tr>
        <tr><td>CPU Load (5min avg)</td><td>&lt; 1.0</td><td>1.0-2.0</td><td>2.0-3.0</td><td>&gt; 3.0</td></tr>
        <tr><td>PSU Efficiency</td><td>&gt; 90%</td><td>85-90%</td><td>80-85%</td><td>&lt; 80%</td></tr>
    </table>

"""
        
        html_content += """
    <script>
        // Filter functionality
        let currentFilter = 'ALL';
        let allRows = [];
        
        document.addEventListener('DOMContentLoaded', function() {
            // Store all table rows for filtering
            allRows = Array.from(document.querySelectorAll('#hardware-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
            
            // Initialize table sorting
            initTableSorting();
        });
        
        function setupCardEvents() {
            console.log('Hardware: Setting up card events...');
            
            const totalDevicesCard = document.getElementById('total-devices-card');
            if (totalDevicesCard) {
                totalDevicesCard.addEventListener('click', function() {
                    if (parseInt(document.getElementById('total-devices').textContent) > 0) {
                        filterDevices('TOTAL');
                    }
                });
            }
            
            document.getElementById('excellent-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('excellent-devices').textContent) > 0) {
                    filterDevices('EXCELLENT');
                }
            });
            
            document.getElementById('good-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('good-devices').textContent) > 0) {
                    filterDevices('GOOD');
                }
            });
            
            document.getElementById('warning-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('warning-devices').textContent) > 0) {
                    filterDevices('WARNING');
                }
            });
            
            document.getElementById('critical-card').addEventListener('click', function() {
                if (parseInt(document.getElementById('critical-devices').textContent) > 0) {
                    filterDevices('CRITICAL');
                }
            });
        }
        
        function filterDevices(filterType) {
            currentFilter = filterType;
            
            // Clear active state from all cards
            document.querySelectorAll('.summary-card').forEach(card => {
                card.classList.remove('active');
            });
            
            let filteredRows = allRows;
            let filterText = '';
            
            if (filterType === 'EXCELLENT') {
                filteredRows = allRows.filter(row => row.dataset.status === 'excellent');
                filterText = 'Showing ' + filteredRows.length + ' Excellent Devices';
                document.getElementById('excellent-card').classList.add('active');
            } else if (filterType === 'GOOD') {
                filteredRows = allRows.filter(row => row.dataset.status === 'good');
                filterText = 'Showing ' + filteredRows.length + ' Good Devices';
                document.getElementById('good-card').classList.add('active');
            } else if (filterType === 'WARNING') {
                filteredRows = allRows.filter(row => row.dataset.status === 'warning');
                filterText = 'Showing ' + filteredRows.length + ' Warning Devices';
                document.getElementById('warning-card').classList.add('active');
            } else if (filterType === 'CRITICAL') {
                filteredRows = allRows.filter(row => row.dataset.status === 'critical');
                filterText = 'Showing ' + filteredRows.length + ' Critical Devices';
                document.getElementById('critical-card').classList.add('active');
            } else if (filterType === 'TOTAL') {
                filteredRows = allRows;
                document.getElementById('total-devices-card').classList.add('active');
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
                    sortHardwareTable(column, tableSortState.direction, type);
                });
            });
        }
        
        function sortHardwareTable(columnIndex, direction, type) {
            const table = document.getElementById('hardware-table');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.rows);
            
            rows.sort((a, b) => {
                let aVal = a.cells[columnIndex].textContent.trim();
                let bVal = b.cells[columnIndex].textContent.trim();
                
                // Extract actual text for status columns (remove HTML)
                if (type === 'hardware-status') {
                    aVal = a.cells[columnIndex].querySelector('span')?.textContent || aVal;
                    bVal = b.cells[columnIndex].querySelector('span')?.textContent || bVal;
                }
                
                let result = 0;
                
                switch(type) {
                    case 'hardware-status':
                        result = compareHardwareStatus(aVal, bVal);
                        break;
                    case 'number':
                        const numA = parseFloat(aVal.replace(/[%,]/g, ''));
                        const numB = parseFloat(bVal.replace(/[%,]/g, ''));
                        if (isNaN(numA) && isNaN(numB)) result = 0;
                        else if (isNaN(numA)) result = 1;
                        else if (isNaN(numB)) result = -1;
                        else result = numA - numB;
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
        
        function compareHardwareStatus(a, b) {
            const priority = {
                'CRITICAL': 0,
                'WARNING': 1,
                'GOOD': 2,
                'EXCELLENT': 3,
                'UNKNOWN': 4
            };
            
            return (priority[a] || 5) - (priority[b] || 5);
        }
    </script>
</body>
</html>"""

        # Write HTML file
        with open(output_file, 'w') as f:
            f.write(html_content)
        
        print(f"📄 Hardware analysis report generated: {output_file}")
        return total_devices

# For compatibility
def analyze_hardware_health(data_dir="monitor-results"):
    """Main analysis function for compatibility"""
    analyzer = HardwareAnalyzer(data_dir)
    
    # Process some dummy data for testing
    analyzer.process_device_hardware("TEST-DEVICE-001", "dummy_data")
    analyzer.process_device_hardware("TEST-DEVICE-002", "dummy_data")  
    analyzer.process_device_hardware("TEST-DEVICE-003", "dummy_data")
    
    # Save history
    analyzer.save_hardware_history()
    
    # Export to web
    analyzer.export_hardware_data_for_web(f"{data_dir}/hardware-analysis.html")
    
    return analyzer

if __name__ == "__main__":
    analyze_hardware_health()