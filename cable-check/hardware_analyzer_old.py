#!/usr/bin/env python3
"""
Hardware Health Analyzer - Monitor temperature, fans, power, and system resources
"""

import os
import re
import json
from datetime import datetime
from enum import Enum
from typing import Dict, List, Any, Optional


class HardwareGrade(Enum):
    EXCELLENT = "EXCELLENT"
    GOOD = "GOOD" 
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"


class HardwareAnalyzer:
    """Professional Hardware Health Analysis System"""
    
    # Industry-standard hardware thresholds
    DEFAULT_CONFIG = {
        "cpu_temp_warning": 70.0,      # CPU temp warning (°C)
        "cpu_temp_critical": 85.0,     # CPU temp critical (°C)
        "asic_temp_warning": 65.0,     # ASIC temp warning (°C)
        "asic_temp_critical": 75.0,    # ASIC temp critical (°C)
        "optical_temp_warning": 65.0,  # Optical module warning (°C)
        "optical_temp_critical": 75.0, # Optical module critical (°C)
        "psu_temp_warning": 50.0,      # PSU temp warning (°C)
        "psu_temp_critical": 60.0,     # PSU temp critical (°C)
        "fan_rpm_min": 3000,           # Minimum fan RPM
        "psu_fan_rpm_max": 25000,      # PSU fan overwork threshold
        "power_efficiency_min": 80.0,  # Minimum PSU efficiency %
        "memory_usage_warning": 80.0,  # RAM usage warning %
        "memory_usage_critical": 90.0, # RAM usage critical %
        "cpu_load_warning": 80.0,      # CPU load warning %
        "cpu_load_critical": 90.0,     # CPU load critical %
        "disk_usage_warning": 85.0,    # Disk usage warning %
        "disk_usage_critical": 95.0    # Disk usage critical %
    }
    
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.hardware_history = {}  # device -> list of hardware readings over time
        self.current_hardware_stats = {}  # device -> current hardware status
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
        data = {
            "hardware_history": self.hardware_history,
            "current_hardware_stats": self.current_hardware_stats,
            "last_updated": datetime.now().isoformat()
        }
        
        with open(f"{self.data_dir}/hardware_history.json", "w") as f:
            json.dump(data, f, indent=2)
    
    def parse_sensors_output(self, sensors_text: str) -> Dict[str, Any]:
        """Parse lm-sensors output and extract hardware metrics"""
        hardware_data = {
            "temperatures": {},
            "fans": {},
            "power": {},
            "voltages": {},
            "currents": {}
        }
        
        current_adapter = None
        
        for line in sensors_text.split('\n'):
            line = line.strip()
            if not line:
                continue
                
            # Adapter detection
            if line.endswith(':') and ('Adapter:' in line or 'coretemp' in line or 'mlxsw' in line):
                current_adapter = line.split('-')[0] if '-' in line else line.rstrip(':')
                continue
            
            # Temperature parsing
            temp_match = re.search(r'(.+?):\s*\+?(-?\d+\.?\d*)\s*°C', line)
            if temp_match:
                temp_name = temp_match.group(1).strip()
                temp_value = float(temp_match.group(2))
                
                # Categorize temperature sources
                if current_adapter:
                    if 'coretemp' in current_adapter or 'CPU' in temp_name:
                        hardware_data["temperatures"][f"CPU_{temp_name}"] = temp_value
                    elif 'mlxsw' in current_adapter or 'ASIC' in temp_name:
                        hardware_data["temperatures"][f"ASIC_{temp_name}"] = temp_value
                    elif 'front panel' in temp_name:
                        # Extract port number from front panel temp
                        port_match = re.search(r'front panel (\d+)', temp_name)
                        if port_match and temp_value > 0:  # Skip 0°C readings
                            port_num = port_match.group(1)
                            hardware_data["temperatures"][f"Optical_Port_{port_num}"] = temp_value
                    elif 'PSU' in temp_name or 'dps460' in current_adapter:
                        hardware_data["temperatures"][f"PSU_{temp_name}"] = temp_value
                    elif 'Ambient' in temp_name:
                        hardware_data["temperatures"][f"Ambient_{temp_name}"] = temp_value
                    else:
                        hardware_data["temperatures"][temp_name] = temp_value
            
            # Fan RPM parsing
            fan_match = re.search(r'(.+?):\s*(\d+)\s*RPM', line)
            if fan_match:
                fan_name = fan_match.group(1).strip()
                fan_rpm = int(fan_match.group(2))
                hardware_data["fans"][fan_name] = fan_rpm
            
            # Power parsing
            power_match = re.search(r'(.+?):\s*(\d+\.?\d*)\s*W', line)
            if power_match:
                power_name = power_match.group(1).strip()
                power_value = float(power_match.group(2))
                hardware_data["power"][power_name] = power_value
            
            # Voltage parsing
            voltage_match = re.search(r'(.+?):\s*(\d+\.?\d*)\s*V', line)
            if voltage_match:
                voltage_name = voltage_match.group(1).strip()
                voltage_value = float(voltage_match.group(2))
                hardware_data["voltages"][voltage_name] = voltage_value
            
            # Current parsing
            current_match = re.search(r'(.+?):\s*(\d+\.?\d*)\s*A', line)
            if current_match:
                current_name = current_match.group(1).strip()
                current_value = float(current_match.group(2))
                hardware_data["currents"][current_name] = current_value
        
        return hardware_data
    
    def parse_system_resources(self, memory_text: str, cpu_text: str, uptime_text: str) -> Dict[str, Any]:
        """Parse system resource information"""
        resources = {}
        
        # Parse memory info
        mem_match = re.search(r'Mem:\s+(\d+\S+)\s+(\d+\S+)\s+(\d+\S+)', memory_text)
        if mem_match:
            total_mem = mem_match.group(1)
            used_mem = mem_match.group(2)
            
            # Convert to percentage
            total_val = self._parse_memory_value(total_mem)
            used_val = self._parse_memory_value(used_mem)
            
            if total_val > 0:
                memory_usage_pct = (used_val / total_val) * 100
                resources["memory"] = {
                    "total": total_mem,
                    "used": used_mem,
                    "usage_percent": memory_usage_pct
                }
        
        # Parse CPU load
        cpu_match = re.search(r'(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)', cpu_text)
        if cpu_match:
            load_1min = float(cpu_match.group(1))
            load_5min = float(cpu_match.group(2))
            load_15min = float(cpu_match.group(3))
            
            resources["cpu"] = {
                "load_1min": load_1min,
                "load_5min": load_5min, 
                "load_15min": load_15min
            }
        
        # Parse uptime
        uptime_match = re.search(r'up\s+(.+?),\s+\d+\s+user', uptime_text)
        if uptime_match:
            uptime_str = uptime_match.group(1).strip()
            resources["uptime"] = uptime_str
        
        return resources
    
    def _parse_memory_value(self, mem_str: str) -> float:
        """Convert memory string to bytes"""
        if 'Gi' in mem_str:
            return float(mem_str.replace('Gi', '')) * 1024 * 1024 * 1024
        elif 'Mi' in mem_str:
            return float(mem_str.replace('Mi', '')) * 1024 * 1024
        elif 'Ki' in mem_str:
            return float(mem_str.replace('Ki', '')) * 1024
        else:
            return float(mem_str.replace('B', ''))
    
    def analyze_temperature_health(self, temperatures: Dict[str, float]) -> Dict[str, HardwareGrade]:
        """Analyze temperature readings and assign health grades"""
        temp_grades = {}
        
        for temp_name, temp_value in temperatures.items():
            if 'CPU' in temp_name:
                if temp_value >= self.config["cpu_temp_critical"]:
                    grade = HardwareGrade.CRITICAL
                elif temp_value >= self.config["cpu_temp_warning"]:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.EXCELLENT
            
            elif 'ASIC' in temp_name:
                if temp_value >= self.config["asic_temp_critical"]:
                    grade = HardwareGrade.CRITICAL
                elif temp_value >= self.config["asic_temp_warning"]:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.EXCELLENT
            
            elif 'Optical' in temp_name:
                if temp_value >= self.config["optical_temp_critical"]:
                    grade = HardwareGrade.CRITICAL
                elif temp_value >= self.config["optical_temp_warning"]:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.EXCELLENT
            
            elif 'PSU' in temp_name:
                if temp_value >= self.config["psu_temp_critical"]:
                    grade = HardwareGrade.CRITICAL
                elif temp_value >= self.config["psu_temp_warning"]:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.EXCELLENT
            
            else:
                # Generic temperature thresholds
                if temp_value >= 80.0:
                    grade = HardwareGrade.CRITICAL
                elif temp_value >= 60.0:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.EXCELLENT
            
            temp_grades[temp_name] = grade
        
        return temp_grades
    
    def analyze_fan_health(self, fans: Dict[str, int]) -> Dict[str, HardwareGrade]:
        """Analyze fan performance and assign health grades"""
        fan_grades = {}
        
        for fan_name, fan_rpm in fans.items():
            if 'PSU' in fan_name:
                # PSU fans - check for overwork
                if fan_rpm > self.config["psu_fan_rpm_max"]:
                    grade = HardwareGrade.WARNING
                elif fan_rpm < self.config["fan_rpm_min"]:
                    grade = HardwareGrade.CRITICAL
                else:
                    grade = HardwareGrade.EXCELLENT
            else:
                # Chassis fans
                if fan_rpm < self.config["fan_rpm_min"]:
                    grade = HardwareGrade.CRITICAL
                elif fan_rpm < 5000:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.EXCELLENT
            
            fan_grades[fan_name] = grade
        
        return fan_grades
    
    def analyze_power_efficiency(self, power_data: Dict[str, float]) -> Dict[str, Any]:
        """Analyze PSU power efficiency"""
        power_analysis = {}
        
        # Look for PSU input/output power pairs
        for psu_name in ['PSU-1', 'PSU-2']:
            input_key = f"{psu_name}(L) 220V Rail Pwr (in)" if psu_name == 'PSU-1' else f"{psu_name}(R) 220V Rail Pwr (in)"
            output_key = f"{psu_name}(L) 54V Rail Pwr (out)" if psu_name == 'PSU-1' else f"{psu_name}(R) 54V Rail Pwr (out)"
            
            input_power = power_data.get(input_key)
            output_power = power_data.get(output_key)
            
            if input_power and output_power and input_power > 0:
                efficiency = (output_power / input_power) * 100
                
                if efficiency >= 90.0:
                    grade = HardwareGrade.EXCELLENT
                elif efficiency >= self.config["power_efficiency_min"]:
                    grade = HardwareGrade.GOOD
                elif efficiency >= 70.0:
                    grade = HardwareGrade.WARNING
                else:
                    grade = HardwareGrade.CRITICAL
                
                power_analysis[psu_name] = {
                    "input_power": input_power,
                    "output_power": output_power,
                    "efficiency": efficiency,
                    "grade": grade.value  # Convert enum to string
                }
        
        return power_analysis
    
    def analyze_system_resources(self, resources: Dict[str, Any]) -> Dict[str, HardwareGrade]:
        """Analyze system resource usage"""
        resource_grades = {}
        
        # Memory analysis
        if "memory" in resources:
            mem_usage = resources["memory"]["usage_percent"]
            if mem_usage >= self.config["memory_usage_critical"]:
                resource_grades["memory"] = HardwareGrade.CRITICAL
            elif mem_usage >= self.config["memory_usage_warning"]:
                resource_grades["memory"] = HardwareGrade.WARNING
            else:
                resource_grades["memory"] = HardwareGrade.EXCELLENT
        
        # CPU load analysis (assuming 6-core system, load > cores = overload)
        if "cpu" in resources:
            cpu_load = resources["cpu"]["load_5min"]  # Use 5-minute average
            cpu_usage_pct = (cpu_load / 6.0) * 100  # Assuming 6 cores
            
            if cpu_usage_pct >= self.config["cpu_load_critical"]:
                resource_grades["cpu"] = HardwareGrade.CRITICAL
            elif cpu_usage_pct >= self.config["cpu_load_warning"]:
                resource_grades["cpu"] = HardwareGrade.WARNING
            else:
                resource_grades["cpu"] = HardwareGrade.EXCELLENT
        
        return resource_grades
    
    def update_device_hardware(self, device_name: str, sensors_output: str, 
                             memory_info: str, cpu_info: str, uptime_info: str):
        """Update hardware statistics for a device"""
        
        # Parse all hardware data
        hardware_data = self.parse_sensors_output(sensors_output)
        resources = self.parse_system_resources(memory_info, cpu_info, uptime_info)
        
        # Analyze health grades
        temp_grades = self.analyze_temperature_health(hardware_data["temperatures"])
        fan_grades = self.analyze_fan_health(hardware_data["fans"])
        power_analysis = self.analyze_power_efficiency(hardware_data["power"])
        resource_grades = self.analyze_system_resources(resources)
        
        # Calculate overall device health
        all_grades = list(temp_grades.values()) + list(fan_grades.values()) + list(resource_grades.values())
        all_grades += [HardwareGrade(psu["grade"]) for psu in power_analysis.values()]
        
        critical_count = sum(1 for grade in all_grades if grade == HardwareGrade.CRITICAL)
        warning_count = sum(1 for grade in all_grades if grade == HardwareGrade.WARNING)
        
        if critical_count > 0:
            overall_grade = HardwareGrade.CRITICAL
        elif warning_count > 0:
            overall_grade = HardwareGrade.WARNING
        else:
            overall_grade = HardwareGrade.EXCELLENT
        
        # Store current stats
        hardware_record = {
            "device": device_name,
            "timestamp": datetime.now().isoformat(),
            "overall_grade": overall_grade.value,
            "temperatures": hardware_data["temperatures"],
            "temperature_grades": {k: v.value for k, v in temp_grades.items()},
            "fans": hardware_data["fans"],
            "fan_grades": {k: v.value for k, v in fan_grades.items()},
            "power_analysis": power_analysis,
            "resources": resources,
            "resource_grades": {k: v.value for k, v in resource_grades.items()},
            "critical_issues": critical_count,
            "warning_issues": warning_count
        }
        
        self.current_hardware_stats[device_name] = hardware_record
        
        # Add to history
        if device_name not in self.hardware_history:
            self.hardware_history[device_name] = []
        
        self.hardware_history[device_name].append(hardware_record)
        
        # Keep last 100 records per device
        self.hardware_history[device_name] = self.hardware_history[device_name][-100:]
        
        return hardware_record
    
    def get_hardware_summary(self) -> Dict[str, Any]:
        """Get overall hardware health summary"""
        if not self.current_hardware_stats:
            return {
                "total_devices": 0,
                "excellent_health": 0,
                "good_health": 0,
                "warning_level": 0,
                "critical_issues": 0
            }
        
        total_devices = len(self.current_hardware_stats)
        excellent = sum(1 for stats in self.current_hardware_stats.values() 
                       if stats["overall_grade"] == "EXCELLENT")
        good = sum(1 for stats in self.current_hardware_stats.values() 
                  if stats["overall_grade"] == "GOOD")
        warning = sum(1 for stats in self.current_hardware_stats.values() 
                     if stats["overall_grade"] == "WARNING")
        critical = sum(1 for stats in self.current_hardware_stats.values() 
                      if stats["overall_grade"] == "CRITICAL")
        
        return {
            "total_devices": total_devices,
            "excellent_health": excellent,
            "good_health": good,
            "warning_level": warning,
            "critical_issues": critical,
            "last_updated": datetime.now().isoformat()
        }
    
    def detect_hardware_anomalies(self) -> List[Dict[str, Any]]:
        """Detect hardware anomalies and generate alerts"""
        anomalies = []
        
        for device_name, stats in self.current_hardware_stats.items():
            
            # Critical temperature alerts
            for temp_name, temp_grade in stats["temperature_grades"].items():
                if temp_grade == "CRITICAL":
                    temp_value = stats["temperatures"][temp_name]
                    anomalies.append({
                        "device": device_name,
                        "component": temp_name,
                        "type": "CRITICAL_TEMPERATURE",
                        "severity": "critical",
                        "message": f"Critical temperature on {temp_name}: {temp_value}°C",
                        "action": f"Immediate cooling required for {device_name}"
                    })
            
            # Fan failure alerts
            for fan_name, fan_grade in stats["fan_grades"].items():
                if fan_grade == "CRITICAL":
                    fan_rpm = stats["fans"][fan_name]
                    anomalies.append({
                        "device": device_name,
                        "component": fan_name,
                        "type": "FAN_FAILURE",
                        "severity": "critical",
                        "message": f"Fan failure detected: {fan_name} at {fan_rpm} RPM",
                        "action": f"Replace fan immediately on {device_name}"
                    })
            
            # Power efficiency alerts
            for psu_name, psu_data in stats["power_analysis"].items():
                if psu_data["grade"] == HardwareGrade.WARNING.value:
                    efficiency = psu_data["efficiency"]
                    anomalies.append({
                        "device": device_name,
                        "component": psu_name,
                        "type": "LOW_POWER_EFFICIENCY",
                        "severity": "warning",
                        "message": f"Low PSU efficiency: {efficiency:.1f}%",
                        "action": f"Monitor {psu_name} on {device_name} for degradation"
                    })
            
            # Resource usage alerts
            for resource_name, resource_grade in stats["resource_grades"].items():
                if resource_grade == "CRITICAL":
                    if resource_name == "memory":
                        usage = stats["resources"]["memory"]["usage_percent"]
                        anomalies.append({
                            "device": device_name,
                            "component": "Memory",
                            "type": "HIGH_MEMORY_USAGE",
                            "severity": "critical",
                            "message": f"Critical memory usage: {usage:.1f}%",
                            "action": f"Investigate memory leak or add RAM to {device_name}"
                        })
                    elif resource_name == "cpu":
                        load = stats["resources"]["cpu"]["load_5min"]
                        anomalies.append({
                            "device": device_name,
                            "component": "CPU",
                            "type": "HIGH_CPU_LOAD",
                            "severity": "critical", 
                            "message": f"Critical CPU load: {load}",
                            "action": f"Investigate high CPU usage on {device_name}"
                        })
        
        return anomalies
    
    def generate_html_report(self, output_file: str):
        """Generate comprehensive hardware health HTML report"""
        summary = self.get_hardware_summary()
        anomalies = self.detect_hardware_anomalies()
        
        # Sort devices by health status (critical first)
        sorted_devices = sorted(
            self.current_hardware_stats.items(),
            key=lambda x: (
                0 if x[1]["overall_grade"] == "CRITICAL" else
                1 if x[1]["overall_grade"] == "WARNING" else 
                2 if x[1]["overall_grade"] == "GOOD" else 3,
                x[0]  # Then by device name
            )
        )
        
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
                <div class="metric" id="total-devices">{summary['total_devices']}</div>
                <div>Total Devices</div>
            </div>
            <div class="summary-card card-excellent" id="excellent-card">
                <div class="metric" id="excellent-devices">{summary['excellent_health']}</div>
                <div>Excellent</div>
            </div>
            <div class="summary-card card-good" id="good-card">
                <div class="metric" id="good-devices">{summary['good_health']}</div>
                <div>Good</div>
            </div>
            <div class="summary-card card-warning" id="warning-card">
                <div class="metric" id="warning-devices">{summary['warning_level']}</div>
                <div>Warning</div>
            </div>
            <div class="summary-card card-critical" id="critical-card">
                <div class="metric" id="critical-devices">{summary['critical_issues']}</div>
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
                    <th class="sortable" data-column="0" data-type="string">Device <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="1" data-type="health">Health <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="2" data-type="number">CPU Temp (°C) <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="3" data-type="number">ASIC Temp (°C) <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="4" data-type="number">Memory (%) <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="5" data-type="number">CPU Load <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="6" data-type="number">PSU Efficiency (%) <span class="sort-arrow"></span></th>
                    <th class="sortable" data-column="7" data-type="string">Uptime <span class="sort-arrow"></span></th>
            </tr>
        </thead>
        <tbody>"""

        for device_name, stats in sorted_devices:
            # Extract key metrics
            cpu_temps = [temp for name, temp in stats["temperatures"].items() if "CPU" in name]
            asic_temps = [temp for name, temp in stats["temperatures"].items() if "ASIC" in name]
            
            cpu_temp_str = f"{max(cpu_temps):.1f}" if cpu_temps else "N/A"
            asic_temp_str = f"{max(asic_temps):.1f}" if asic_temps else "N/A"
            
            memory_usage = stats["resources"].get("memory", {}).get("usage_percent", 0)
            cpu_load = stats["resources"].get("cpu", {}).get("load_5min", 0)
            uptime = stats["resources"].get("uptime", "N/A")
            
            # Calculate average PSU efficiency
            psu_efficiencies = [psu["efficiency"] for psu in stats["power_analysis"].values()]
            avg_efficiency = sum(psu_efficiencies) / len(psu_efficiencies) if psu_efficiencies else 0
            
            health_class = f"hardware-{stats['overall_grade'].lower()}"
            
            html_content += f"""
            <tr>
                <td>{device_name}</td>
                <td><span class="{health_class}">{stats['overall_grade']}</span></td>
                <td>{cpu_temp_str}</td>
                <td>{asic_temp_str}</td>
                <td>{memory_usage:.1f}%</td>
                <td>{cpu_load:.2f}</td>
                <td>{avg_efficiency:.1f}%</td>
                <td>{uptime}</td>
            </tr>"""

        html_content += """
        </tbody>
    </table>"""

        # Add JavaScript for table sorting
        html_content += """
    <script>
        // Table sorting functionality
        function initTableSorting() {
            const sortableHeaders = document.querySelectorAll('th.sortable');
            
            sortableHeaders.forEach(header => {
                header.addEventListener('click', () => {
                    const table = header.closest('table');
                    const tbody = table.querySelector('tbody');
                    const rows = Array.from(tbody.querySelectorAll('tr'));
                    const columnIndex = parseInt(header.dataset.column);
                    const dataType = header.dataset.type;
                    
                    // Toggle sort direction
                    const isAscending = !header.classList.contains('sort-desc');
                    
                    // Remove sort classes from all headers
                    sortableHeaders.forEach(h => h.classList.remove('sort-asc', 'sort-desc'));
                    
                    // Add sort class to current header
                    header.classList.add(isAscending ? 'sort-asc' : 'sort-desc');
                    
                    // Sort rows
                    rows.sort((a, b) => {
                        const aValue = a.cells[columnIndex].textContent.trim();
                        const bValue = b.cells[columnIndex].textContent.trim();
                        
                        let comparison = 0;
                        
                        if (dataType === 'number') {
                            const aNum = parseFloat(aValue.replace(/[^0-9.-]/g, '')) || 0;
                            const bNum = parseFloat(bValue.replace(/[^0-9.-]/g, '')) || 0;
                            comparison = aNum - bNum;
                        } else if (dataType === 'health') {
                            const healthOrder = {'EXCELLENT': 4, 'GOOD': 3, 'WARNING': 2, 'CRITICAL': 1};
                            const aHealth = healthOrder[aValue] || 0;
                            const bHealth = healthOrder[bValue] || 0;
                            comparison = bHealth - aHealth; // Reverse for health (best first)
                        } else {
                            comparison = aValue.localeCompare(bValue);
                        }
                        
                        return isAscending ? comparison : -comparison;
                    });
                    
                    // Reorder table rows
                    rows.forEach(row => tbody.appendChild(row));
                });
            });
        }

        // Initialize sorting when page loads
        document.addEventListener('DOMContentLoaded', initTableSorting);
    </script>
</body>
</html>"""

        # Write HTML file
        with open(output_file, 'w') as f:
            f.write(html_content)
        
        print(f"📄 Hardware analysis report generated: {output_file}")
        return len(sorted_devices)