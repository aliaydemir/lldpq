#!/usr/bin/env python3
"""
Optical Diagnostics Analysis Module for LLDPq
Advanced SFP/QSFP monitoring and cable health assessment

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
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
        "rx_power_max_dbm": 7.0,        # Maximum receive power (critical high)
        # High RX thresholds: treat >5 dBm as warning, >7 dBm as critical (typical DR optics)
        "rx_power_warning_high_dbm": 5.0,
        "rx_power_critical_high_dbm": 7.0,
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
        """Parse optical output (NVUE transceiver commands) for optical parameters
        
        Returns None if this is a DAC/Copper cable (not optical)
        """
        # Check for DAC/Copper cable - these don't have optical diagnostics
        cable_type_indicators = [
            'Passive copper',
            'Active copper',
            'Copper cable',
            'Base-CR',  # Copper (e.g., 100G Base-CR4)
            'DAC',
            'Twinax',
            'No separable connector'  # DAC cables
        ]
        
        for indicator in cable_type_indicators:
            if indicator in optical_data:
                # This is a copper/DAC cable, not optical - skip optical analysis
                return None
        
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

                        # Parse temperature (NVUE format: "temperature : 48.71 degrees C" or ethtool: "Module temperature : 48.85 degrees C")
            temp_match = re.search(r'(?:Module\s+)?temperature\s*:\s*([\d.-]+)\s*degrees?\s*C', line)
            if temp_match:
                optical_params['temperature_c'] = float(temp_match.group(1))
            
            # Parse voltage (NVUE format: "voltage : 3.2688 V" or ethtool: "Module voltage : 3.2096 V")
            voltage_match = re.search(r'(?:Module\s+)?voltage\s*:\s*([\d.-]+)\s*V', line)
            if voltage_match:
                optical_params['voltage_v'] = float(voltage_match.group(1))

            # Parse RX power (NVUE: "ch-1-rx-power : 1.7055 mW / 2.32 dBm" or ethtool: "Rcvr signal avg optical power(Channel 1) : 1.5601 mW / 1.93 dBm")
            # Enhanced regex to handle parentheses around Channel
            rx_power_match = re.search(r'(?:ch-\d+-rx-power|Rcvr\s+signal\s+avg\s+optical\s+power\s*\(?\s*Channel\s+\d+\s*\)?)\s*:\s*[\d.-]+\s*mW\s*/\s*([-\d.]+)\s*dBm', line)
            if rx_power_match:
                try:
                    rx_dbm = float(rx_power_match.group(1))
                    # Ignore placeholder lanes commonly reported as -40 dBm on unused channels
                    if rx_dbm > -35.0:
                        rx_powers.append(rx_dbm)
                except ValueError:
                    pass

            # Parse TX power (NVUE: "ch-1-tx-power : 1.1706 mW / 0.68 dBm" or ethtool: "Transmit avg optical power (Channel 1) : 1.0466 mW / 0.20 dBm")
            # Enhanced regex to handle parentheses around Channel
            tx_power_match = re.search(r'(?:ch-\d+-tx-power|Transmit\s+avg\s+optical\s+power\s*\(?\s*Channel\s+\d+\s*\)?)\s*:\s*[\d.-]+\s*mW\s*/\s*([-\d.]+)\s*dBm', line)
            if tx_power_match:
                try:
                    tx_dbm = float(tx_power_match.group(1))
                    # Ignore unused lanes at ~-40 dBm
                    if tx_dbm > -35.0:
                        tx_powers.append(tx_dbm)
                except ValueError:
                    pass

            # Parse bias current (NVUE: "ch-1-tx-bias-current : 7.056 mA" or ethtool: "Laser tx bias current (Channel 1) : 72.500 mA")
            # Enhanced regex to handle parentheses around Channel
            bias_match = re.search(r'(?:ch-\d+-tx-bias-current|Laser\s+tx\s+bias\s+current\s*\(?\s*Channel\s+\d+\s*\)?)\s*:\s*([\d.-]+)\s*mA', line)
            if bias_match:
                try:
                    bias_ma = float(bias_match.group(1))
                    # Ignore zero bias reported on unused lanes
                    if bias_ma > 0.1:
                        bias_currents.append(bias_ma)
                except ValueError:
                    pass

        # Average multi-channel values
        if rx_powers:
            optical_params['rx_power_dbm'] = sum(rx_powers) / len(rx_powers)
        if tx_powers:
            optical_params['tx_power_dbm'] = sum(tx_powers) / len(tx_powers)
        if bias_currents:
            optical_params['bias_current_ma'] = sum(bias_currents) / len(bias_currents)

        # Fallback: parse on full blob if line-by-line missed values (ethtool formatting variations)
        # Enhanced to handle both "Channel 1" and "(Channel 1)" formats
        if optical_params['rx_power_dbm'] is None:
            rx_all = re.findall(r'(?:Rcvr\s+signal\s+avg\s+optical\s+power\s*\(?\s*Channel\s*\d+\s*\)?|ch-\d+-rx-power)\s*:\s*[\d.-]+\s*mW\s*/\s*([-\d.]+)\s*dBm', optical_data, flags=re.IGNORECASE)
            if rx_all:
                rx_vals = [float(v) for v in rx_all if float(v) > -35.0]
                if rx_vals:
                    optical_params['rx_power_dbm'] = sum(rx_vals) / len(rx_vals)
        if optical_params['tx_power_dbm'] is None:
            tx_all = re.findall(r'(?:Transmit\s+avg\s+optical\s+power\s*\(?\s*Channel\s*\d+\s*\)?|ch-\d+-tx-power)\s*:\s*[\d.-]+\s*mW\s*/\s*([-\d.]+)\s*dBm', optical_data, flags=re.IGNORECASE)
            if tx_all:
                tx_vals = [float(v) for v in tx_all if float(v) > -35.0]
                if tx_vals:
                    optical_params['tx_power_dbm'] = sum(tx_vals) / len(tx_vals)
        if optical_params['bias_current_ma'] is None:
            bias_all = re.findall(r'(?:Laser\s+tx\s+bias\s+current\s*\(?\s*Channel\s*\d+\s*\)?|ch-\d+-tx-bias-current)\s*:\s*([\d.-]+)\s*mA', optical_data, flags=re.IGNORECASE)
            if bias_all:
                bias_vals = [float(v) for v in bias_all if float(v) > 0.1]
                if bias_vals:
                    optical_params['bias_current_ma'] = sum(bias_vals) / len(bias_vals)

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
        if rx_power is not None and \
           rx_power > self.thresholds.get('rx_power_critical_high_dbm', 7.0):
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

        # High RX power warning (above warning high but below critical high)
        if rx_power is not None and \
           rx_power > self.thresholds.get('rx_power_warning_high_dbm', 5.0):
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
        """Update optical statistics for a port
        
        Returns False if port is DAC/Copper (skipped), True if processed
        """
        optical_params = self.parse_optical_data(optical_data)
        
        # Skip DAC/Copper cables - parse_optical_data returns None for these
        if optical_params is None:
            return False
        
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
        
        return True

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
    <link rel="stylesheet" type="text/css" href="/css/select2.min.css">
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
        .optical-table th:nth-child(1), .optical-table td:nth-child(1) {{ width: 16%; }} /* Port */
        .optical-table th:nth-child(2), .optical-table td:nth-child(2) {{ width: 8%; }}  /* Health */
        .optical-table th:nth-child(3), .optical-table td:nth-child(3) {{ width: 10%; }} /* RX Power */
        .optical-table th:nth-child(4), .optical-table td:nth-child(4) {{ width: 10%; }} /* TX Power */
        .optical-table th:nth-child(5), .optical-table td:nth-child(5) {{ width: 8%; }}  /* Temperature */
        .optical-table th:nth-child(6), .optical-table td:nth-child(6) {{ width: 12%; }} /* Link Margin */
        .optical-table th:nth-child(7), .optical-table td:nth-child(7) {{ width: 9%; }}  /* Voltage */
        .optical-table th:nth-child(8), .optical-table td:nth-child(8) {{ width: 13%; }} /* Bias Current */
        .optical-table th:nth-child(9), .optical-table td:nth-child(9) {{ width: 16%; word-wrap: break-word; }} /* Recommended Action */

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
    <h1></h1>
    <h1><font color="#b57614">Optical Diagnostics Analysis</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>

    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
        <h2 style="margin: 0;">Optical Summary</h2>
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
            <th class="sortable" data-column="2" data-type="optical-power">Rx Pwr (dBm) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="3" data-type="optical-power">Tx Pwr (dBm) <span class="sort-arrow">▲▼</span></th>
            <th class="sortable" data-column="4" data-type="temperature">Temp(°C) <span class="sort-arrow">▲▼</span></th>
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
        <tr><td>RX Power</td><td>{self.thresholds['rx_power_min_dbm']} dBm</td><td>{self.thresholds['rx_power_critical_high_dbm']} dBm</td><td>Received optical power range (warning above {self.thresholds['rx_power_warning_high_dbm']} dBm)</td></tr>
        <tr><td>TX Power</td><td>{self.thresholds['tx_power_min_dbm']} dBm</td><td>{self.thresholds['tx_power_max_dbm']} dBm</td><td>Transmitted optical power range</td></tr>
        <tr><td>Temperature</td><td>{self.thresholds['temperature_min_c']}°C</td><td>{self.thresholds['temperature_max_c']}°C</td><td>SFP/QSFP operating temperature</td></tr>
        <tr><td>Voltage</td><td>{self.thresholds['voltage_min_v']}V</td><td>{self.thresholds['voltage_max_v']}V</td><td>Supply voltage range</td></tr>
        <tr><td>Link Margin</td><td>{self.thresholds['link_margin_min_db']} dB</td><td>-</td><td>Minimum acceptable link budget margin</td></tr>
        <tr><td>Bias Current</td><td>-</td><td>{self.thresholds['bias_current_max_ma']} mA</td><td>Maximum laser bias current</td></tr>
    </table>
"""

        html_content += """
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
            allRows = Array.from(document.querySelectorAll('#optical-data tr'));

            // Add click events to summary cards
            setupCardEvents();

            // Initialize table sorting
            initTableSorting();
            
            // Initialize device search
            populateDeviceList();
            initDeviceSearch();
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
                // Port format is "hostname:interface" - extract hostname
                const portName = row.cells[0]?.textContent?.trim();
                if (portName && portName.includes(':')) {
                    const hostname = portName.split(':')[0];
                    deviceSet.add(hostname);
                }
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
            
            // Filter table rows - match hostname part of port name
            let matchCount = 0;
            allRows.forEach(row => {
                const portName = row.cells[0]?.textContent?.trim() || '';
                const hostname = portName.split(':')[0];
                if (hostname === deviceName) {
                    row.style.display = '';
                    matchCount++;
                } else {
                    row.style.display = 'none';
                }
            });
            
            // Show filter info
            document.getElementById('filter-info').style.display = 'block';
            document.getElementById('filter-text').textContent = 'Showing ports for device: ' + deviceName + ' (' + matchCount + ' ports)';
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
                const filename = `Optical_Analysis_Report_${dateStr}_${timeStr}.csv`;

                // Create CSV header
                const headers = [
                    'Port',
                    'Health',
                    'Rx Power (dBm)',
                    'Tx Power (dBm)',
                    'Temperature (°C)',
                    'Link Margin (dB)',
                    'Voltage (V)',
                    'Bias Current (mA)',
                    'Recommended Action'
                ];

                let csvContent = headers.join(',') + '\\n';

                // Get table data (only visible rows)
                const table = document.getElementById('optical-table');
                const tbody = table.querySelector('tbody');
                const rows = tbody.querySelectorAll('tr');

                // Add summary stats as comments
                csvContent += `# Optical Diagnostics Summary Report\\n`;
                csvContent += `# Generated: ${now.toLocaleString()}\\n`;
                csvContent += `# Total Ports: ${document.getElementById('total-ports').textContent}\\n`;
                csvContent += `# Excellent: ${document.getElementById('excellent-ports').textContent}\\n`;
                csvContent += `# Good: ${document.getElementById('good-ports').textContent}\\n`;
                csvContent += `# Warning: ${document.getElementById('warning-ports').textContent}\\n`;
                csvContent += `# Critical: ${document.getElementById('critical-ports').textContent}\\n`;
                csvContent += `#\\n`;

                // Process each visible row
                rows.forEach(row => {
                    if (row.style.display !== 'none') {
                        const cells = row.querySelectorAll('td');
                        if (cells.length >= 9) {
                            const rowData = [
                                cells[0].textContent.trim(), // Port
                                cells[1].querySelector('span') ? cells[1].querySelector('span').textContent.trim() : cells[1].textContent.trim(), // Health
                                cells[2].textContent.trim(), // Rx Power
                                cells[3].textContent.trim(), // Tx Power
                                cells[4].textContent.trim(), // Temperature
                                cells[5].textContent.trim(), // Link Margin
                                cells[6].textContent.trim(), // Voltage
                                cells[7].textContent.trim(), // Bias Current
                                cells[8].textContent.trim()  // Recommended Action
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
    analyzer = OpticalAnalyzer()
    print("Optical analyzer initialized")
    print(f"Monitoring {len(analyzer.current_optical_stats)} ports")