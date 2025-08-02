#!/usr/bin/env python3
"""
Simple script to generate BER-style HTML from existing hardware data
"""

import json
import os
import re
from datetime import datetime

def parse_temperature_from_hardware_file(device_name):
    """Parse CPU and ASIC temperatures from raw hardware file"""
    
    cpu_temp = None
    asic_temp = None
    
    hardware_file = f"monitor-results/hardware-data/{device_name}_hardware.txt"
    
    if not os.path.exists(hardware_file):
        return cpu_temp, asic_temp
    
    try:
        with open(hardware_file, 'r') as f:
            content = f.read()
        
        # Parse ASIC temperature: "Ambient ASIC Temp:  +50.0°C"
        asic_match = re.search(r'Ambient ASIC Temp:\s*\+?(-?\d+\.?\d*)[°C]', content)
        if asic_match:
            asic_temp = float(asic_match.group(1))
        
        # Parse CPU temperature: multiple possible formats
        # Pattern 1: "temp1:        +47.0°C" (some devices)
        cpu_matches = re.findall(r'temp1:\s*\+?(-?\d+\.?\d*)[°C]', content)
        if cpu_matches:
            cpu_temp = float(cpu_matches[0])
        else:
            # Pattern 2: "CPU ACPI temp:  +27.8°C" (other devices)
            cpu_acpi_matches = re.findall(r'CPU ACPI temp:\s*\+?(-?\d+\.?\d*)[°C]', content)
            if cpu_acpi_matches:
                cpu_temp = float(cpu_acpi_matches[0])
            else:
                # Pattern 3: Average of CPU cores "Core 0:        +40.0°C"
                core_matches = re.findall(r'Core \d+:\s*\+?(-?\d+\.?\d*)[°C]', content)
                if core_matches:
                    core_temps = [float(temp) for temp in core_matches]
                    cpu_temp = sum(core_temps) / len(core_temps)  # Average
        
    except Exception as e:
        print(f"Warning: Could not parse temperatures for {device_name}: {e}")
    
    return cpu_temp, asic_temp

def parse_psu_efficiency_from_hardware_file(device_name):
    """Parse PSU efficiency from raw hardware file"""
    
    hardware_file = f"monitor-results/hardware-data/{device_name}_hardware.txt"
    
    if not os.path.exists(hardware_file):
        return None
    
    try:
        with open(hardware_file, 'r') as f:
            content = f.read()
        
        total_input_power = 0.0
        total_output_power = 0.0
        
        # Parse input power: Multiple formats
        # Format 1: "PMIC-X ... (in): 12.00 W"
        input_matches_w = re.findall(r'PMIC-\d+.*\(in\):\s*(\d+\.?\d*)\s*W', content)
        input_matches_mw = re.findall(r'PMIC-\d+.*\(in\):\s*(\d+\.?\d*)\s*mW', content)
        # Format 2: "PSU-X ... Pwr(in): 52.25 W" or "PSU-X ... Pwr (in): 94.62 W"
        psu_input_matches_w = re.findall(r'PSU-\d+.*Pwr\s*\(in\):\s*(\d+\.?\d*)\s*W', content)
        # Format 3: "VR IC ... pwr(in): 25.00 W"
        vr_input_matches_w = re.findall(r'VR IC.*pwr\s*\(in\):\s*(\d+\.?\d*)\s*W', content)
        
        # Sum all input power sources
        for power_str in input_matches_w:
            total_input_power += float(power_str)
        for power_str in input_matches_mw:
            total_input_power += float(power_str) / 1000.0  # Convert mW to W
        for power_str in psu_input_matches_w:
            total_input_power += float(power_str)
        for power_str in vr_input_matches_w:
            total_input_power += float(power_str)
        
        # Parse output power: Multiple formats
        # Format 1: "PMIC-X ... Pwr (out1): 5.00 W"
        output_matches_w = re.findall(r'PMIC-\d+.*Pwr \(out\d*\):\s*(\d+\.?\d*)\s*W', content)
        output_matches_mw = re.findall(r'PMIC-\d+.*Pwr \(out\d*\):\s*(\d+\.?\d*)\s*mW', content)
        # Format 2: "PSU-X ... Pwr(out): 45.88 W" or "PSU-X ... Pwr (out): 69.50 W"
        psu_output_matches_w = re.findall(r'PSU-\d+.*Pwr\s*\(out\):\s*(\d+\.?\d*)\s*W', content)
        # Format 3: VR IC outputs only (avoid PMIC double counting)
        vr_output_matches_w = re.findall(r'^(?!PMIC-).*(?:VR|VCORE).*Rail Pwr\s*\(out\):\s*(\d+\.?\d*)\s*W', content, re.MULTILINE)
        
        # Sum all output power sources
        for power_str in output_matches_w:
            total_output_power += float(power_str)
        for power_str in output_matches_mw:
            total_output_power += float(power_str) / 1000.0  # Convert mW to W
        for power_str in psu_output_matches_w:
            total_output_power += float(power_str)
        for power_str in vr_output_matches_w:
            total_output_power += float(power_str)
        
        # Calculate efficiency if we have both input and output
        if total_input_power > 0 and total_output_power > 0:
            efficiency = (total_output_power / total_input_power) * 100
            return min(efficiency, 100.0)  # Cap at 100%
        
    except Exception as e:
        print(f"Warning: Could not parse PSU efficiency for {device_name}: {e}")
    
    return None

def calculate_device_health_grade(device_name, device_data):
    """Calculate overall health grade for a device based on our thresholds"""
    health_grades = []
    priority = {"CRITICAL": 4, "WARNING": 3, "GOOD": 2, "EXCELLENT": 1}
    
    # CPU Temperature grade
    cpu_temp, asic_temp = parse_temperature_from_hardware_file(device_name)
    if cpu_temp is not None:
        if cpu_temp < 60:
            health_grades.append("EXCELLENT")
        elif cpu_temp < 70:
            health_grades.append("GOOD")
        elif cpu_temp < 80:
            health_grades.append("WARNING")
        else:
            health_grades.append("CRITICAL")
    
    # ASIC Temperature grade  
    if asic_temp is not None:
        if asic_temp < 70:
            health_grades.append("EXCELLENT")
        elif asic_temp < 80:
            health_grades.append("GOOD")
        elif asic_temp < 90:
            health_grades.append("WARNING")
        else:
            health_grades.append("CRITICAL")
    
    # Memory usage grade
    memory_usage = device_data.get("resources", {}).get("memory", {}).get("usage_percent", 0)
    if memory_usage < 60:
        health_grades.append("EXCELLENT")
    elif memory_usage < 75:
        health_grades.append("GOOD")
    elif memory_usage < 85:
        health_grades.append("WARNING")
    else:
        health_grades.append("CRITICAL")
        
    # CPU Load grade
    cpu_load = device_data.get("resources", {}).get("cpu", {}).get("load_5min", 0)
    if cpu_load < 1.0:
        health_grades.append("EXCELLENT")
    elif cpu_load < 2.0:
        health_grades.append("GOOD")
    elif cpu_load < 3.0:
        health_grades.append("WARNING")
    else:
        health_grades.append("CRITICAL")
    
    # PSU Efficiency grade
    psu_efficiency = parse_psu_efficiency_from_hardware_file(device_name) or 0.0
    if psu_efficiency > 90:
        health_grades.append("EXCELLENT")
    elif psu_efficiency >= 85:
        health_grades.append("GOOD")
    elif psu_efficiency >= 80:
        health_grades.append("WARNING")
    elif psu_efficiency > 0:
        health_grades.append("CRITICAL")
    
    # Fan status grade
    fans = device_data.get("fans", {})
    if fans:
        fan_grades = []
        for fan_name, fan_speed in fans.items():
            if fan_speed > 4000:
                fan_grades.append("EXCELLENT")
            elif fan_speed >= 3000:
                fan_grades.append("GOOD")  
            elif fan_speed >= 1000:
                fan_grades.append("WARNING")
            else:
                fan_grades.append("CRITICAL")
        if fan_grades:
            fan_status = max(fan_grades, key=lambda x: priority.get(x, 0))
            health_grades.append(fan_status)
    
    # Calculate overall health grade (worst case)
    if health_grades:
        return max(health_grades, key=lambda x: priority.get(x, 0))
    else:
        return "UNKNOWN"

def generate_hardware_html():
    """Generate hardware analysis HTML using existing data"""
    
    # Read existing hardware history
    try:
        with open("monitor-results/hardware_history.json", "r") as f:
            data = json.load(f)
            hardware_history = data.get("hardware_history", {})
    except:
        print("❌ Could not read hardware_history.json")
        return
    
    # Get latest data for each device
    latest_devices = {}
    for device_name, history in hardware_history.items():
        if history:  # If device has history entries
            latest_devices[device_name] = history[-1]  # Get the most recent entry
    
    # Calculate summary
    summary = {
        'excellent_devices': [],
        'good_devices': [],
        'warning_devices': [],
        'critical_devices': []
    }
    
    # Count devices with current hardware files
    hardware_data_dir = "monitor-results/hardware-data"
    current_device_files = 0
    if os.path.exists(hardware_data_dir):
        current_device_files = len([f for f in os.listdir(hardware_data_dir) if f.endswith('_hardware.txt')])
    
    for device_name, device_data in latest_devices.items():
        # Use our own health calculation instead of JSON's overall_grade
        overall_grade = calculate_device_health_grade(device_name, device_data)
        device_info = {
            'device': device_name,
            'health_grade': overall_grade,
            'data': device_data
        }
        
        if overall_grade == "EXCELLENT":
            summary['excellent_devices'].append(device_info)
        elif overall_grade == "GOOD":
            summary['good_devices'].append(device_info)
        elif overall_grade == "WARNING":
            summary['warning_devices'].append(device_info)
        elif overall_grade == "CRITICAL":
            summary['critical_devices'].append(device_info)
    
    # Use current device files count instead of historical count
    total_devices = current_device_files
    
    # Generate BER-style HTML
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
        .hardware-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; table-layout: fixed; }}
        .hardware-table th, .hardware-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; word-wrap: break-word; }}
        .hardware-table th {{ background-color: #f2f2f2; font-weight: bold; }}
        
        /* Column width specifications */
        .hardware-table th:nth-child(1), .hardware-table td:nth-child(1) {{ width: 13%; }} /* Device */
        .hardware-table th:nth-child(2), .hardware-table td:nth-child(2) {{ width: 8%; }} /* Health */
        .hardware-table th:nth-child(3), .hardware-table td:nth-child(3) {{ width: 12%; }} /* CPU Temp */
        .hardware-table th:nth-child(4), .hardware-table td:nth-child(4) {{ width: 12%; }} /* ASIC Temp */
        .hardware-table th:nth-child(5), .hardware-table td:nth-child(5) {{ width: 10%; }} /* Memory */
        .hardware-table th:nth-child(6), .hardware-table td:nth-child(6) {{ width: 8%; }} /* CPU Load */
        .hardware-table th:nth-child(7), .hardware-table td:nth-child(7) {{ width: 11%; }} /* Fan Status */
        .hardware-table th:nth-child(8), .hardware-table td:nth-child(8) {{ width: 13%; }} /* PSU Efficiency */
        .hardware-table th:nth-child(9), .hardware-table td:nth-child(9) {{ width: 13%; }} /* Uptime */
        
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
                    <th class="sortable" data-column="6" data-type="hardware-status">Fan Status <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="7" data-type="number">PSU Efficiency (%) <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="8" data-type="string">Uptime <span class="sort-arrow">▲▼</span></th>
                </tr>
            </thead>
            <tbody id="hardware-data">
"""
    
    # Add all devices to table (sorted by health - problems first)
    all_devices = (summary['critical_devices'] + summary['warning_devices'] + 
                  summary['good_devices'] + summary['excellent_devices'])
    
    for device_info in all_devices:
        device_name = device_info['device']
        device_data = device_info['data']
        health_grade = device_info['health_grade']  # Already calculated in summary
        
        # Extract key metrics for display
        cpu_temp, asic_temp = parse_temperature_from_hardware_file(device_name)
        cpu_temp_str = f"{cpu_temp:.1f}°C" if cpu_temp is not None else "N/A"
        asic_temp_str = f"{asic_temp:.1f}°C" if asic_temp is not None else "N/A"
        
        memory_usage = device_data.get("resources", {}).get("memory", {}).get("usage_percent", 0)
        cpu_load = device_data.get("resources", {}).get("cpu", {}).get("load_5min", 0)
        uptime = device_data.get("resources", {}).get("uptime", "N/A")
        
        # PSU Efficiency 
        psu_efficiency_parsed = parse_psu_efficiency_from_hardware_file(device_name)
        psu_efficiency = psu_efficiency_parsed if psu_efficiency_parsed is not None else 0.0
        
        # Calculate fan status for display
        fans = device_data.get("fans", {})
        if fans:
            priority = {"CRITICAL": 4, "WARNING": 3, "GOOD": 2, "EXCELLENT": 1}
            fan_grades_calculated = []
            for fan_name, fan_speed in fans.items():
                if fan_speed > 4000:
                    grade = "EXCELLENT"
                elif fan_speed >= 3000:
                    grade = "GOOD"  
                elif fan_speed >= 1000:
                    grade = "WARNING"
                else:
                    grade = "CRITICAL"
                fan_grades_calculated.append(grade)
            
            # Get overall fan status (worst case from all fans)
            fan_status = max(fan_grades_calculated, key=lambda x: priority.get(x, 0))
        else:
            fan_status = "N/A"
        
        health_class = f"hardware-{health_grade.lower()}"
        
        fan_class = f"hardware-{fan_status.lower()}" if fan_status != "N/A" else ""
        
        html_content += f"""
                <tr data-status="{health_grade.lower()}">
                    <td>{device_name}</td>
                    <td><span class="{health_class}">{health_grade.upper()}</span></td>
                    <td>{cpu_temp_str}</td>
                    <td>{asic_temp_str}</td>
                    <td>{memory_usage:.1f}%</td>
                    <td>{cpu_load:.2f}</td>
                    <td><span class="{fan_class}">{fan_status}</span></td>
                    <td>{psu_efficiency:.1f}%</td>
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
        <tr><td>Fan Speed</td><td>&gt; 4000 RPM</td><td>3000-4000 RPM</td><td>1000-3000 RPM</td><td>&lt; 1000 RPM</td></tr>
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
    with open("monitor-results/hardware-analysis.html", 'w') as f:
        f.write(html_content)
    
    print(f"✅ Hardware analysis HTML generated with {total_devices} devices!")
    print(f"   - Excellent: {len(summary['excellent_devices'])}")
    print(f"   - Good: {len(summary['good_devices'])}")
    print(f"   - Warning: {len(summary['warning_devices'])}")
    print(f"   - Critical: {len(summary['critical_devices'])}")

if __name__ == "__main__":
    generate_hardware_html()