#!/usr/bin/env python3
"""
BER (Bit Error Rate) Analysis Module for LLDPq

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
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
        self._raw_phy_ber_cache = {}  # hostname -> { interface: raw_ber_float }
        
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

    def _parse_raw_phy_ber_for_device(self, hostname: str) -> Dict[str, float]:
        """Parse RAW PHY BER per interface for given device.

        Sources (in order):
          1) monitor-results/ber-data/<hostname>_l1_show.txt (direct l1-show output)
             - Use raw_ber_coef × 10^(raw_ber_magnitude)
             - Fallback to corrected_bits/received_bits
          2) monitor-results/ber-data/<hostname>_detailed_counters.txt (legacy combined extract)
        """
        if hostname in self._raw_phy_ber_cache:
            return self._raw_phy_ber_cache[hostname]

        result: Dict[str, float] = {}

        def parse_content(content: str):
            nonlocal result
            current_if: Optional[str] = None
            current_received_bits: Optional[int] = None
            current_corrected_bits: Optional[int] = None
            current_raw_coef: Optional[int] = None
            current_raw_mag: Optional[int] = None

            def flush():
                nonlocal current_if, current_received_bits, current_corrected_bits, current_raw_coef, current_raw_mag
                if not current_if:
                    return
                if current_raw_coef is not None and current_raw_mag is not None:
                    try:
                        raw_ber = float(current_raw_coef) * (10.0 ** float(current_raw_mag))
                        if raw_ber >= 0:
                            result[current_if] = raw_ber
                    except Exception:
                        pass
                elif current_received_bits and current_corrected_bits and current_received_bits > 0 and current_corrected_bits >= 0:
                    try:
                        raw_ber = float(current_corrected_bits) / float(current_received_bits)
                        result[current_if] = raw_ber
                    except Exception:
                        pass
                current_if = None
                current_received_bits = None
                current_corrected_bits = None
                current_raw_coef = None
                current_raw_mag = None

            for line in content.splitlines():
                s = line.strip()
                if not s:
                    continue
                if s.startswith("Port:") or s.startswith("Interface:"):
                    flush()
                    try:
                        name = s.split(":", 1)[1].strip()
                        current_if = name
                    except Exception:
                        current_if = None
                    continue
                if ":" in s and current_if:
                    key, val = s.split(":", 1)
                    key = key.strip().lower().replace(" ", "_")
                    val = val.strip()
                    try:
                        if key == "phy_received_bits":
                            current_received_bits = int(val)
                        elif key == "phy_corrected_bits":
                            current_corrected_bits = int(val)
                        elif key == "raw_ber_coef":
                            current_raw_coef = int(val)
                        elif key == "raw_ber_magnitude":
                            current_raw_mag = int(val)
                    except Exception:
                        pass
            flush()

        # 1) Prefer direct l1-show output if present
        l1_path = f"{self.data_dir}/ber-data/{hostname}_l1_show.txt"
        try:
            if os.path.exists(l1_path):
                with open(l1_path, "r") as f:
                    parse_content(f.read())
        except Exception:
            pass

        # 2) Fallback to legacy detailed counters
        if not result:
            legacy_path = f"{self.data_dir}/ber-data/{hostname}_detailed_counters.txt"
            try:
                if os.path.exists(legacy_path):
                    with open(legacy_path, "r") as f:
                        parse_content(f.read())
            except Exception:
                pass

        self._raw_phy_ber_cache[hostname] = result
        return result
    
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
    
    def calculate_ber(self, rx_packets: int, tx_packets: int, rx_errors: int, tx_errors: int, rx_bytes: int, tx_bytes: int) -> float:
        """Calculate Bit Error Rate (MTU-independent using byte counters when available).

        Falls back to a packet-size estimate only if byte counters are unavailable.
        """
        total_packets = rx_packets + tx_packets
        total_errors = rx_errors + tx_errors
        total_bytes = rx_bytes + tx_bytes

        if total_packets < self.config["min_packets_for_analysis"]:
            return 0.0  # Not enough data for reliable BER calculation

        if total_errors == 0:
            return 0.0  # Perfect transmission

        # Prefer exact bit volume from byte counters (MTU-independent)
        total_bits = total_bytes * 8

        # Fallback to estimated bits if byte counters are missing/zero
        if total_bits <= 0:
            avg_bits_per_packet = 12000  # 1500 bytes as conservative estimate
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
            interface_stats.get('tx_errors', 0),
            interface_stats.get('rx_bytes', 0),
            interface_stats.get('tx_bytes', 0)
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
        
        /* Colored card values */
        .card-excellent .metric {{ color: #4caf50; }}
        .card-good .metric {{ color: #8bc34a; }}
        .card-warning .metric {{ color: #ff9800; }}
        .card-critical .metric {{ color: #f44336; }}
        .card-total .metric {{ color: #333; }}
        .card-info .metric {{ color: #2196f3; }}
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
        .ber-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; table-layout: fixed; }}
        .ber-table th, .ber-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; word-wrap: break-word; }}
        .ber-table th {{ background-color: #f2f2f2; font-weight: bold; }}
        
        /* Column width specifications */
        .ber-table th:nth-child(1), .ber-table td:nth-child(1) {{ width: 14%; }} /* Device */
        .ber-table th:nth-child(2), .ber-table td:nth-child(2) {{ width: 14%; }} /* Interface */
        .ber-table th:nth-child(3), .ber-table td:nth-child(3) {{ width: 10%; }} /* Status */
        .ber-table th:nth-child(4), .ber-table td:nth-child(4) {{ width: 14%; }} /* BER Value */
        .ber-table th:nth-child(5), .ber-table td:nth-child(5) {{ width: 14%; }} /* RAW BER */
        .ber-table th:nth-child(6), .ber-table td:nth-child(6) {{ width: 10%; }} /* Total Packets */
        .ber-table th:nth-child(7), .ber-table td:nth-child(7) {{ width: 10%; }} /* RX Errors */
        .ber-table th:nth-child(8), .ber-table td:nth-child(8) {{ width: 10%; }} /* TX Errors */
        .ber-table th:nth-child(9), .ber-table td:nth-child(9) {{ width: 14%; }} /* Last Updated */
        
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
        
        @keyframes spin {{
            from {{ transform: rotate(0deg); }}
            to {{ transform: rotate(360deg); }}
        }}
    </style>
  </head>
  <body>
    <h1></h1>
    <h1><font color="#b57614">BER Analysis Results</font></h1>
        <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
        
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
            <h2 style="margin: 0;">Network Summary</h2>
            <div style="display: flex; gap: 10px;">
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
                    <th class="sortable" data-column="0" data-type="string">Device <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="1" data-type="port">Interface <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="2" data-type="ber-status">Status <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="3" data-type="ber-value">BER Value <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="4" data-type="ber-value">RAW BER <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="5" data-type="number">Total Packets <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="6" data-type="number">RX Errors <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="7" data-type="number">TX Errors <span class="sort-arrow">▲▼</span></th>
                    <th class="sortable" data-column="8" data-type="time">Last Updated <span class="sort-arrow">▲▼</span></th>
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
            
            # Lookup RAW PHY BER for this device/interface (if available)
            raw_map = self._parse_raw_phy_ber_for_device(device)
            raw_phy_val = raw_map.get(interface)
            raw_phy_display = f"{raw_phy_val:.2e}" if isinstance(raw_phy_val, (int, float)) and raw_phy_val is not None else "N/A"

            timestamp = datetime.fromtimestamp(port_info['timestamp']).strftime('%H:%M:%S')
            
            html_content += f"""
                <tr data-status="{status.lower()}">
                    <td>{device}</td>
                    <td>{interface}</td>
                    <td><span class="{status_class}">{status}</span></td>
                    <td>{ber_display}</td>
                    <td>{raw_phy_display}</td>
                    <td>{port_info['total_packets']:,}</td>
                    <td>{port_info['rx_errors']:,}</td>
                    <td>{port_info['tx_errors']:,}</td>
                    <td>{timestamp}</td>
                </tr>
"""
        
        html_content += """
            </tbody>
        </table>
        
    <div class="anomaly-section">
        <h2>Notes</h2>
        <ul>
            <li><strong>BER (Frame)</strong>: rx/tx frame sayaçlarından (bytes tabanlı), MTU'dan bağımsızdır.</li>
            <li><strong>RAW BER (PHY)</strong>: l1-show/PHY katmanından gelir; FEC ile düzeltilmiş bit hatalarını da içerir.</li>
            <li>Bu yüzden RAW BER > 0 iken Frame BER = 0 olabilir; bu normaldir.</li>
        </ul>
    </div>

    <h2>BER Analysis Thresholds</h2>
    <table class="ber-table">
        <tr><th>Parameter</th><th>Threshold</th><th>Description</th></tr>
        <tr><td>Excellent</td><td>Zero errors</td><td>Zero bit errors detected</td></tr>
        <tr><td>Good</td><td>&lt; 1×10⁻⁶</td><td>Industry standard acceptable BER level</td></tr>
        <tr><td>Warning</td><td>1×10⁻⁶ to 1×10⁻⁵</td><td>Elevated error rate requiring monitoring</td></tr>
        <tr><td>Critical</td><td>&gt; 1×10⁻⁵</td><td>Unacceptable error rate, immediate attention required</td></tr>
        <tr><td>Analysis Method</td><td>Interface statistics</td><td>Based on error counters and packet statistics</td></tr>
    </table>

"""
        
        html_content += """
    <script>
        // Filter functionality
        let currentFilter = 'ALL';
        let allRows = [];
        
        document.addEventListener('DOMContentLoaded', function() {
            // Store all table rows for filtering
            allRows = Array.from(document.querySelectorAll('#ber-data tr'));
            
            // Add click events to summary cards
            setupCardEvents();
            
            // Initialize table sorting
            initTableSorting();
        });
        
        function setupCardEvents() {
            console.log('BER: Setting up card events...');
            
            // Check if elements exist
            const totalPortsCard = document.getElementById('total-ports-card');
            console.log('BER: total-ports-card found?', totalPortsCard);
            
            if (totalPortsCard) {
                totalPortsCard.addEventListener('click', function() {
                    console.log('BER: Total ports clicked');
                    if (parseInt(document.getElementById('total-ports').textContent) > 0) {
                        filterPorts('TOTAL');
                    }
                });
            } else {
                console.error('BER: total-ports-card not found!');
            }
            
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
                filteredRows = allRows.filter(row => row.dataset.status === 'excellent');
                filterText = 'Showing ' + filteredRows.length + ' Excellent Ports';
                document.getElementById('excellent-card').classList.add('active');
            } else if (filterType === 'GOOD') {
                filteredRows = allRows.filter(row => row.dataset.status === 'good');
                filterText = 'Showing ' + filteredRows.length + ' Good Ports';
                document.getElementById('good-card').classList.add('active');
            } else if (filterType === 'WARNING') {
                filteredRows = allRows.filter(row => row.dataset.status === 'warning');
                filterText = 'Showing ' + filteredRows.length + ' Warning Ports';
                document.getElementById('warning-card').classList.add('active');
            } else if (filterType === 'CRITICAL') {
                filteredRows = allRows.filter(row => row.dataset.status === 'critical');
                filterText = 'Showing ' + filteredRows.length + ' Critical Ports';
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
                    sortBERTable(column, tableSortState.direction, type);
                });
            });
        }
        
        function sortBERTable(columnIndex, direction, type) {
            const table = document.getElementById('ber-table');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.rows);
            
            rows.sort((a, b) => {
                let aVal = a.cells[columnIndex].textContent.trim();
                let bVal = b.cells[columnIndex].textContent.trim();
                
                // Extract actual text for status columns (remove HTML)
                if (type === 'ber-status') {
                    aVal = a.cells[columnIndex].querySelector('span')?.textContent || aVal;
                    bVal = b.cells[columnIndex].querySelector('span')?.textContent || bVal;
                }
                
                let result = 0;
                
                switch(type) {
                    case 'port':
                        result = comparePort(aVal, bVal);
                        break;
                    case 'ber-status':
                        result = compareBERStatus(aVal, bVal);
                        break;
                    case 'ber-value':
                        result = compareBERValue(aVal, bVal);
                        break;
                    case 'number':
                        const numA = parseInt(aVal.replace(/,/g, ''));
                        const numB = parseInt(bVal.replace(/,/g, ''));
                        result = numA - numB;
                        break;
                    case 'time':
                        result = aVal.localeCompare(bVal);
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
        
        function compareBERStatus(a, b) {
            const priority = {
                'CRITICAL': 0,
                'WARNING': 1,
                'GOOD': 2,
                'EXCELLENT': 3,
                'UNKNOWN': 4
            };
            
            return (priority[a] || 5) - (priority[b] || 5);
        }
        
        function compareBERValue(a, b) {
            // Handle scientific notation (1.23e-5) and plain numbers
            if (a === '0' && b === '0') return 0;
            if (a === '0') return 1; // 0 is best (excellent)
            if (b === '0') return -1;
            
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
                    // Auto-refresh page after 15 seconds
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
                const filename = `BER_Analysis_Report_${dateStr}_${timeStr}.csv`;
                
                // Create CSV header
                const headers = [
                    'Port',
                    'Health Status',
                    'BER Value',
                    'RX Errors',
                    'TX Errors',
                    'Total Frames',
                    'Error Rate',
                    'Last Scan'
                ];
                
                let csvContent = headers.join(',') + '\\n';
                
                // Get table data (only visible rows)
                const table = document.getElementById('ber-table');
                const tbody = table.querySelector('tbody');
                const rows = tbody.querySelectorAll('tr');
                
                // Add summary stats as comments
                csvContent += `# BER Analysis Summary Report\\n`;
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
                        if (cells.length >= 8) {
                            const rowData = [
                                cells[0].textContent.trim(), // Port
                                cells[1].querySelector('span') ? cells[1].querySelector('span').textContent.trim() : cells[1].textContent.trim(), // Health Status
                                cells[2].textContent.trim(), // BER Value
                                cells[3].textContent.trim(), // RX Errors
                                cells[4].textContent.trim(), // TX Errors
                                cells[5].textContent.trim(), // Total Frames
                                cells[6].textContent.trim(), // Error Rate
                                cells[7].textContent.trim()  // Last Scan
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
        
        try:
            with open(output_file, 'w') as f:
                f.write(html_content)
            print(f"BER analysis report generated: {output_file}")
        except Exception as e:
            print(f"Error writing BER analysis report: {e}")
        
        # Save history after analysis
        self.save_ber_history()