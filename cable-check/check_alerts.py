#!/usr/bin/env python3
"""
LLDPq Alert System - Network monitoring alerts for Slack
Copyright (c) 2024 LLDPq Project - Licensed under MIT License

This script analyzes monitoring data and sends alerts based on configured thresholds.
Called every 10 minutes by the lldpq cron job.
"""

import json
import yaml
import requests
import os
import sys
import glob
import time
import datetime
import re
from pathlib import Path

class LLDPqAlerts:
    def __init__(self, script_dir):
        self.script_dir = Path(script_dir)
        self.config_file = self.script_dir / "notifications.yaml"
        self.state_dir = self.script_dir / "alert-states"
        self.monitor_results = self.script_dir / "monitor-results"
        
        # Create state directory if it doesn't exist
        self.state_dir.mkdir(exist_ok=True)
        
        # Load configuration
        self.config = self.load_config()
        
    def load_config(self):
        """Load notification configuration from YAML file"""
        try:
            if not self.config_file.exists():
                print(f"❌ Configuration file not found: {self.config_file}")
                return None
                
            with open(self.config_file, 'r') as f:
                config = yaml.safe_load(f)
                
            if not config.get('notifications', {}).get('enabled', False):
                print("ℹ️  Notifications disabled in config")
                return None
                
            return config
        except Exception as e:
            print(f"❌ Error loading config: {e}")
            return None
    
    def get_alert_state(self, device, alert_type):
        """Get the last alert state for a device/alert combination"""
        state_file = self.state_dir / f"{device}_{alert_type}.state"
        if state_file.exists():
            try:
                with open(state_file, 'r') as f:
                    return f.read().strip()
            except:
                pass
        return "UNKNOWN"
    
    def set_alert_state(self, device, alert_type, state):
        """Save the current alert state"""
        state_file = self.state_dir / f"{device}_{alert_type}.state"
        try:
            with open(state_file, 'w') as f:
                f.write(state)
        except Exception as e:
            print(f"❌ Error saving state: {e}")
    
    def should_send_alert(self, device, alert_type, current_state):
        """Check if we should send an alert based on state changes and frequency limits"""
        if not self.config:
            return False
            
        last_state = self.get_alert_state(device, alert_type)
        
        # Only alert on state changes
        if current_state == last_state:
            return False
            
        # Check minimum interval (prevent spam)
        timestamp_file = self.state_dir / f"{device}_{alert_type}.timestamp"
        min_interval = self.config.get('frequency', {}).get('min_interval_minutes', 30) * 60
        
        if timestamp_file.exists():
            try:
                with open(timestamp_file, 'r') as f:
                    last_time = float(f.read().strip())
                if time.time() - last_time < min_interval:
                    return False
            except:
                pass
        
        # Update timestamp
        try:
            with open(timestamp_file, 'w') as f:
                f.write(str(time.time()))
        except:
            pass
            
        return True
    
    def send_notification(self, title, message, severity, device, alert_type=""):
        """Send notification to configured channels"""
        if not self.config:
            return
            
        # Color mapping
        colors = {
            "CRITICAL": "#FF0000",  # Red
            "WARNING": "#FFA500",   # Orange  
            "INFO": "#0066CC",      # Blue
            "RECOVERED": "#00AA00"  # Green
        }
        
        color = colors.get(severity, "#808080")
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        
        # Send to Slack
        slack_config = self.config.get('notifications', {}).get('slack', {})
        if slack_config.get('enabled') and slack_config.get('webhook'):
            self.send_slack_message(title, message, color, device, timestamp, slack_config)
    

    def send_slack_message(self, title, message, color, device, timestamp, slack_config):
        """Send message to Slack"""
        try:
            server_url = self.config.get('notifications', {}).get('server_url', 'http://localhost')
            payload = {
                "channel": slack_config.get('channel', '#network-alerts'),
                "username": slack_config.get('username', 'LLDPq Bot'),
                "icon_emoji": slack_config.get('icon_emoji', ':warning:'),
                "attachments": [{
                    "color": color,
                    "title": title,
                    "text": message,
                    "fields": [
                        {"title": "Device", "value": device, "short": True},
                        {"title": "Time", "value": timestamp, "short": True}
                    ],
                    "actions": [{
                        "type": "button",
                        "text": "View Details",
                        "url": f"{server_url}/monitor-results/{device}.html"
                    }]
                }]
            }
            
            response = requests.post(slack_config['webhook'], json=payload, timeout=10)
            if response.status_code == 200:
                print(f"✅ Slack alert sent: {title}")
            else:
                print(f"❌ Slack alert failed: {response.status_code}")
                
        except Exception as e:
            print(f"❌ Slack notification error: {e}")
    
    def check_hardware_alerts(self, device):
        """Check hardware-related alerts (CPU temp, fans, memory, etc.)"""
        if not self.config.get('alert_types', {}).get('hardware_alerts', True):
            return
            
        hardware_file = self.monitor_results / "hardware-data" / f"{device}_hardware.txt"
        if not hardware_file.exists():
            return
            
        try:
            with open(hardware_file, 'r') as f:
                hardware_data = f.read()
        except:
            return
        
        thresholds = self.config.get('thresholds', {}).get('hardware', {})
        
        # Check CPU temperature
        cpu_temp_match = re.search(r'CPU ACPI temp:\s*\+?([0-9.]+)°C', hardware_data)
        if not cpu_temp_match:
            cpu_temp_match = re.search(r'Core \d+:\s*\+?([0-9.]+)°C', hardware_data)
        
        if cpu_temp_match:
            cpu_temp = float(cpu_temp_match.group(1))
            cpu_critical = thresholds.get('cpu_temp_critical', 85)
            cpu_warning = thresholds.get('cpu_temp_warning', 75)
            
            if cpu_temp >= cpu_critical:
                current_state = "CRITICAL"
            elif cpu_temp >= cpu_warning:
                current_state = "WARNING"
            else:
                current_state = "OK"
            
            if self.should_send_alert(device, "cpu_temp", current_state):
                if current_state == "CRITICAL":
                    self.send_notification(
                        f"🔥 Critical CPU Temperature",
                        f"CPU temperature: {cpu_temp}°C (threshold: {cpu_critical}°C)",
                        "CRITICAL", device, "cpu_temp"
                    )
                elif current_state == "WARNING":
                    self.send_notification(
                        f"⚠️ High CPU Temperature",
                        f"CPU temperature: {cpu_temp}°C (threshold: {cpu_warning}°C)",
                        "WARNING", device, "cpu_temp"
                    )
                elif current_state == "OK" and self.config.get('frequency', {}).get('send_recovery', True):
                    self.send_notification(
                        f"✅ CPU Temperature Recovered",
                        f"CPU temperature: {cpu_temp}°C (back to normal)",
                        "RECOVERED", device, "cpu_temp"
                    )
                
                self.set_alert_state(device, "cpu_temp", current_state)
        
        # Check ASIC temperature
        asic_temp_match = re.search(r'ASIC.*temp.*:\s*\+?([0-9.]+)°C', hardware_data)
        if asic_temp_match:
            asic_temp = float(asic_temp_match.group(1))
            asic_critical = thresholds.get('asic_temp_critical', 90)
            asic_warning = thresholds.get('asic_temp_warning', 80)
            
            if asic_temp >= asic_critical:
                current_state = "CRITICAL"
            elif asic_temp >= asic_warning:
                current_state = "WARNING"
            else:
                current_state = "OK"
                
            if self.should_send_alert(device, "asic_temp", current_state):
                if current_state == "CRITICAL":
                    self.send_notification(
                        f"🔥 Critical ASIC Temperature",
                        f"ASIC temperature: {asic_temp}°C (threshold: {asic_critical}°C)",
                        "CRITICAL", device, "asic_temp"
                    )
                elif current_state == "WARNING":
                    self.send_notification(
                        f"⚠️ High ASIC Temperature",
                        f"ASIC temperature: {asic_temp}°C (threshold: {asic_warning}°C)",
                        "WARNING", device, "asic_temp"
                    )
                elif current_state == "OK" and self.config.get('frequency', {}).get('send_recovery', True):
                    self.send_notification(
                        f"✅ ASIC Temperature Recovered",
                        f"ASIC temperature: {asic_temp}°C (back to normal)",
                        "RECOVERED", device, "asic_temp"
                    )
                
                self.set_alert_state(device, "asic_temp", current_state)
        
        # Check fan speeds
        fan_matches = re.findall(r'fan\d+:\s*(\d+)\s*RPM', hardware_data, re.IGNORECASE)
        if fan_matches:
            fan_critical = thresholds.get('fan_rpm_critical', 3000)
            fan_warning = thresholds.get('fan_rpm_warning', 4000)
            
            failed_fans = []
            warning_fans = []
            
            for i, rpm_str in enumerate(fan_matches, 1):
                rpm = int(rpm_str)
                if rpm < fan_critical:
                    failed_fans.append(f"Fan{i}: {rpm} RPM")
                elif rpm < fan_warning:
                    warning_fans.append(f"Fan{i}: {rpm} RPM")
            
            if failed_fans:
                current_state = "CRITICAL"
            elif warning_fans:
                current_state = "WARNING"
            else:
                current_state = "OK"
            
            if self.should_send_alert(device, "fan_speed", current_state):
                if current_state == "CRITICAL":
                    self.send_notification(
                        f"🌀 Critical Fan Failure",
                        f"Fan(s) below critical threshold: {', '.join(failed_fans)}",
                        "CRITICAL", device, "fan_speed"
                    )
                elif current_state == "WARNING":
                    self.send_notification(
                        f"⚠️ Fan Speed Warning",
                        f"Fan(s) below warning threshold: {', '.join(warning_fans)}",
                        "WARNING", device, "fan_speed"
                    )
                elif current_state == "OK" and self.config.get('frequency', {}).get('send_recovery', True):
                    self.send_notification(
                        f"✅ Fan Speeds Recovered",
                        f"All fans operating normally",
                        "RECOVERED", device, "fan_speed"
                    )
                
                self.set_alert_state(device, "fan_speed", current_state)

    def check_network_alerts(self, device):
        """Check network-related alerts (BGP, link flaps, optical)"""
        if not self.config.get('alert_types', {}).get('network_alerts', True):
            return
            
        # Check BGP status
        bgp_file = self.monitor_results / "bgp-data" / f"{device}_bgp.txt"
        if bgp_file.exists():
            try:
                with open(bgp_file, 'r') as f:
                    bgp_data = f.read()
                
                # Count BGP neighbors that are down
                down_neighbors = re.findall(r'(\d+\.\d+\.\d+\.\d+).*?(Active|Idle|Connect)', bgp_data)
                
                if down_neighbors:
                    current_state = "CRITICAL"
                    neighbor_list = [f"{ip} ({state})" for ip, state in down_neighbors]
                    
                    if self.should_send_alert(device, "bgp_neighbors", current_state):
                        self.send_notification(
                            f"🔴 BGP Neighbors Down",
                            f"BGP neighbors down: {', '.join(neighbor_list)}",
                            "CRITICAL", device, "bgp_neighbors"
                        )
                        self.set_alert_state(device, "bgp_neighbors", current_state)
                else:
                    current_state = "OK"
                    if self.should_send_alert(device, "bgp_neighbors", current_state):
                        if self.config.get('frequency', {}).get('send_recovery', True):
                            self.send_notification(
                                f"✅ BGP Neighbors Recovered",
                                f"All BGP neighbors established",
                                "RECOVERED", device, "bgp_neighbors"
                            )
                        self.set_alert_state(device, "bgp_neighbors", current_state)
            except:
                pass
        
        # Check link flaps
        flap_files = glob.glob(str(self.monitor_results / "flap-data" / f"{device}_*_transitions.txt"))
        if flap_files:
            high_flap_interfaces = []
            critical_flap_interfaces = []
            
            thresholds = self.config.get('thresholds', {}).get('network', {})
            flap_warning = thresholds.get('link_flaps_per_hour', 10)
            flap_critical = thresholds.get('link_flaps_critical', 20)
            
            for flap_file in flap_files:
                try:
                    interface = os.path.basename(flap_file).replace(f"{device}_", "").replace("_transitions.txt", "")
                    with open(flap_file, 'r') as f:
                        flap_count = len(f.readlines())
                    
                    if flap_count >= flap_critical:
                        critical_flap_interfaces.append(f"{interface}: {flap_count}")
                    elif flap_count >= flap_warning:
                        high_flap_interfaces.append(f"{interface}: {flap_count}")
                except:
                    continue
            
            if critical_flap_interfaces:
                current_state = "CRITICAL"
            elif high_flap_interfaces:
                current_state = "WARNING"
            else:
                current_state = "OK"
            
            if self.should_send_alert(device, "link_flaps", current_state):
                if current_state == "CRITICAL":
                    self.send_notification(
                        f"⚡ Critical Link Flapping",
                        f"Interfaces with excessive flaps: {', '.join(critical_flap_interfaces)}",
                        "CRITICAL", device, "link_flaps"
                    )
                elif current_state == "WARNING":
                    self.send_notification(
                        f"⚠️ High Link Flapping",
                        f"Interfaces with high flaps: {', '.join(high_flap_interfaces)}",
                        "WARNING", device, "link_flaps"
                    )
                elif current_state == "OK" and self.config.get('frequency', {}).get('send_recovery', True):
                    self.send_notification(
                        f"✅ Link Flaps Stabilized",
                        f"All interfaces stable",
                        "RECOVERED", device, "link_flaps"
                    )
                
                self.set_alert_state(device, "link_flaps", current_state)

    def check_log_alerts(self, device):
        """Check for critical system logs"""
        if not self.config.get('alert_types', {}).get('log_alerts', True):
            return
            
        log_file = self.monitor_results / "log-data" / f"{device}_logs.txt"
        if not log_file.exists():
            return
            
        try:
            with open(log_file, 'r') as f:
                log_data = f.read()
            
            # Count critical log entries
            critical_patterns = [
                r'CRITICAL|CRIT',
                r'ALERT|EMERG', 
                r'kernel.*panic',
                r'out of memory|oom',
                r'segfault|segmentation fault'
            ]
            
            critical_logs = []
            for pattern in critical_patterns:
                matches = re.findall(pattern, log_data, re.IGNORECASE)
                critical_logs.extend(matches)
            
            if len(critical_logs) > 0:
                current_state = "CRITICAL"
                if self.should_send_alert(device, "system_logs", current_state):
                    self.send_notification(
                        f"📋 Critical System Logs",
                        f"Found {len(critical_logs)} critical log entries",
                        "CRITICAL", device, "system_logs"
                    )
                    self.set_alert_state(device, "system_logs", current_state)
            else:
                current_state = "OK"
                if self.should_send_alert(device, "system_logs", current_state):
                    if self.config.get('frequency', {}).get('send_recovery', True):
                        self.send_notification(
                            f"✅ System Logs Clear",
                            f"No critical system issues detected",
                            "RECOVERED", device, "system_logs"
                        )
                    self.set_alert_state(device, "system_logs", current_state)
        except:
            pass

    def check_all_devices(self):
        """Check alerts for all monitored devices"""
        if not self.config:
            print("ℹ️  Notifications disabled or config error")
            return
            
        # Get alert strategy
        alert_strategy = self.config.get('alert_strategy', {})
        mode = alert_strategy.get('mode', 'summary')
        
        print(f"🔍 Checking alerts for all devices (mode: {mode})...")
        
        # Get list of devices from hardware data
        hardware_dir = self.monitor_results / "hardware-data"
        if not hardware_dir.exists():
            print("❌ No hardware data directory found")
            return
            
        device_files = glob.glob(str(hardware_dir / "*_hardware.txt"))
        devices = [os.path.basename(f).replace('_hardware.txt', '') for f in device_files]
        
        if not devices:
            print("❌ No device hardware files found")
            return
            
        print(f"📊 Found {len(devices)} devices to check")
        
        if mode == "summary":
            self.send_summary_alert(devices)
        elif mode == "change_only":
            self.check_changes_only(devices)  
        else:
            # Immediate mode (original behavior)
            for device in devices:
                print(f"  📍 Checking {device}...")
                try:
                    self.check_hardware_alerts(device)
                    self.check_network_alerts(device)
                    self.check_log_alerts(device)
                except Exception as e:
                    print(f"    ❌ Error checking {device}: {e}")
                    continue
        
        print("✅ Alert check completed")

    def send_summary_alert(self, devices):
        """Send dashboard-style summary alert"""
        print("📊 Generating network health summary...")
        
        # Collect summary statistics
        total_devices = len(devices)
        hardware_stats = {"excellent": 0, "good": 0, "warnings": 0, "critical": 0}
        log_stats = {"critical": 0, "warnings": 0, "errors": 0, "info": 0}
        bgp_stats = {"established": 0, "down": 0}
        asset_stats = {"successful": 0, "failed": 0}
        ber_stats = {"good": 0, "warnings": 0, "critical": 0}
        flap_stats = {"stable": 0, "warnings": 0, "critical": 0}
        optical_stats = {"excellent": 0, "good": 0, "warnings": 0, "critical": 0}
        critical_issues = []
        
        for device in devices:
            try:
                # Check hardware status
                hw_status = self.get_device_hardware_status(device)
                if hw_status:
                    hardware_stats[hw_status.lower()] += 1
                    if hw_status.lower() == "critical":
                        critical_issues.append(f"🔥 {device}: Critical hardware issue")
                
                # Check log status  
                log_counts = self.get_device_log_counts(device)
                if log_counts:
                    log_stats["critical"] += log_counts.get("critical", 0)
                    log_stats["warnings"] += log_counts.get("warnings", 0)
                    log_stats["errors"] += log_counts.get("errors", 0)
                    log_stats["info"] += log_counts.get("info", 0)
                    
                    if log_counts.get("critical", 0) > 0:
                        critical_issues.append(f"📋 {device}: {log_counts['critical']} critical logs")
                
                # Check BGP status
                bgp_status = self.get_device_bgp_status(device)
                if bgp_status == "down":
                    bgp_stats["down"] += 1
                    critical_issues.append(f"🔴 {device}: BGP neighbors down")
                else:
                    bgp_stats["established"] += 1
                
                # Check asset status
                asset_status = self.get_device_asset_status(device)
                if asset_status == "failed":
                    asset_stats["failed"] += 1
                else:
                    asset_stats["successful"] += 1
                
                # Check BER status (simplified)
                ber_status = self.get_device_ber_status(device)
                if ber_status:
                    ber_stats[ber_status.lower()] += 1
                else:
                    ber_stats["good"] += 1
                
                # Check flap status (simplified)
                flap_status = self.get_device_flap_status(device)
                if flap_status:
                    flap_stats[flap_status.lower()] += 1
                else:
                    flap_stats["stable"] += 1
                
                # Check optical status
                optical_status = self.get_device_optical_status(device)
                if optical_status:
                    optical_stats[optical_status.lower()] += 1
                    if optical_status.lower() == "critical":
                        critical_issues.append(f"🔴 {device}: Critical optical issues")
                else:
                    optical_stats["excellent"] += 1
                        
            except Exception as e:
                print(f"    ❌ Error checking {device}: {e}")
                continue
        
        # Analyze LLDP topology (global analysis, not per device)
        lldp_stats = self.analyze_lldp_topology()
        
        # Check for LLDP critical issues
        if lldp_stats['failed'] > 0:
            critical_issues.append(f"🔗 LLDP Topology: {lldp_stats['failed']} failed connections")
        
        # Create summary signature for state tracking (include optical and LLDP)
        summary_signature = f"{total_devices}_{hardware_stats['excellent']}_{hardware_stats['good']}_{hardware_stats['warnings']}_{hardware_stats['critical']}_{log_stats['critical']}_{log_stats['warnings']}_{bgp_stats['down']}_{asset_stats['failed']}_{ber_stats['critical']}_{flap_stats['critical']}_{optical_stats['critical']}_{lldp_stats['failed']}"
        
        # Check if summary changed or it's scheduled time (critical issues don't force immediate send in summary mode)
        if self.should_send_summary_alert(summary_signature):
            server_url = self.config.get('notifications', {}).get('server_url', 'http://localhost')
            
            # Create clean dashboard-style message with spacing
            title = "Network Health Summary"
            message = f"""

Total Devices: {total_devices}

─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

Hardware Health Analysis:


🟢 Excellent: {hardware_stats['excellent']}     🔵 Good: {hardware_stats['good']}     🟡 Warnings: {hardware_stats['warnings']}     🔴 Critical: {hardware_stats['critical']}


─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

Log Analysis Results:


🔴 Critical: {log_stats['critical']}     🟡 Warnings: {log_stats['warnings']}     🔵 Errors: {log_stats['errors']}


─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

Asset Analysis Results:


🟢 Successful: {asset_stats['successful']}     🔴 Failed: {asset_stats['failed']}


─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

LLDP Topology Analysis Results:


🟢 Successful: {lldp_stats['successful']}     🔴 Failed: {lldp_stats['failed']}     🟡 Warnings: {lldp_stats['warnings']}     🔵 No Info: {lldp_stats['no_info']}


─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

BGP Analysis Results:


🟢 Established: {bgp_stats['established']}     🔴 Down: {bgp_stats['down']}


─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

Link Flap Analysis Results:


🟢 Stable: {flap_stats['stable']}     🟡 Warnings: {flap_stats['warnings']}     🔴 Critical: {flap_stats['critical']}

─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

Optical Diagnostics Analysis:


🟢 Excellent: {optical_stats['excellent']}     🟢 Good: {optical_stats['good']}     🟡 Warning: {optical_stats['warnings']}     🔴 Critical: {optical_stats['critical']}


─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─

BER Analysis Results:


🟢 Good: {ber_stats['good']}     🟡 Warnings: {ber_stats['warnings']}     🔴 Critical: {ber_stats['critical']}

"""
            if critical_issues:
                message += f"\n\n─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─\n\nCritical Issues:\n" + "\n".join(critical_issues[:5])
                if len(critical_issues) > 5:
                    message += f"\n... and {len(critical_issues) - 5} more issues"
                    
            message += f"\n\n─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ── ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─\n\n[📊 View Full Dashboard]({server_url})"
            
            # Send notification
            color = "#FF0000" if critical_issues else "#00AA00"
            severity = "CRITICAL" if critical_issues else "INFO"
            self.send_notification(title, message, severity, "Network Summary")
            
            # Save summary state
            self.set_alert_state("network_summary", "last_summary", summary_signature)
            
        print(f"📊 Summary: {total_devices} devices, {len(critical_issues)} critical issues")

    def should_send_summary_alert(self, current_signature):
        """Check if summary should be sent based on changes or schedule"""
        last_signature = self.get_alert_state("network_summary", "last_summary")
        
        # Send if data changed
        if current_signature != last_signature:
            return True
            
        # Send if it's scheduled time and hasn't been sent recently
        if self.is_summary_time():
            last_summary_time = self.get_alert_state("network_summary", "last_summary_time")
            current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
            
            if current_time != last_summary_time:
                self.set_alert_state("network_summary", "last_summary_time", current_time)
                return True
                
        return False

    def get_device_hardware_status(self, device):
        """Get hardware health status for a device"""
        try:
            hardware_file = self.monitor_results / "hardware-data" / f"{device}_hardware.txt"
            if not hardware_file.exists():
                return None
                
            with open(hardware_file, 'r') as f:
                hardware_data = f.read()
            
            # Simple status check based on temperature
            cpu_temp_match = re.search(r'CPU ACPI temp:\s*\+?([0-9.]+)°C', hardware_data)
            if cpu_temp_match:
                cpu_temp = float(cpu_temp_match.group(1))
                if cpu_temp >= 85:
                    return "CRITICAL"
                elif cpu_temp >= 75:
                    return "WARNINGS"
                elif cpu_temp >= 65:
                    return "GOOD"
                else:
                    return "EXCELLENT"
            return "GOOD"
        except:
            return None

    def get_device_log_counts(self, device):
        """Get log severity counts for a device from processed summary"""
        try:
            # Read from processed log_summary.json instead of raw files
            summary_file = self.monitor_results / "log_summary.json"
            if not summary_file.exists():
                return None
                
            with open(summary_file, 'r') as f:
                summary_data = json.load(f)
            
            device_counts = summary_data.get("device_counts", {}).get(device)
            if device_counts:
                # Map to expected format
                return {
                    "critical": device_counts.get("critical", 0),
                    "warnings": device_counts.get("warning", 0), 
                    "errors": device_counts.get("error", 0),
                    "info": device_counts.get("info", 0)
                }
            return None
        except:
            return None

    def get_device_bgp_status(self, device):
        """Get BGP status for a device from processed summary"""
        try:
            # Read from processed bgp_history.json
            bgp_history_file = self.monitor_results / "bgp_history.json"
            if not bgp_history_file.exists():
                return "established"  # Default to healthy if no data
                
            with open(bgp_history_file, 'r') as f:
                bgp_data = json.load(f)
            
            # Get latest BGP stats for this device
            device_bgp = bgp_data.get(device, {})
            if device_bgp:
                latest_stats = device_bgp.get("current_stats", {})
                down_neighbors = latest_stats.get("down_neighbors", 0)
                return "down" if down_neighbors > 0 else "established"
            
            return "established"
        except:
            return "established"

    def get_device_asset_status(self, device):
        """Get asset status for a device"""
        try:
            # Check if device exists in monitoring results (simple check)
            device_file = self.monitor_results / f"{device}.html"
            if device_file.exists():
                return "successful"
            else:
                return "failed"
        except:
            return "failed"

    def get_device_ber_status(self, device):
        """Get BER status for a device"""
        try:
            ber_file = self.monitor_results / "ber-data" / f"{device}_ber.txt"
            if not ber_file.exists():
                return "good"
                
            with open(ber_file, 'r') as f:
                ber_data = f.read()
            
            # Simple BER check - look for high error rates
            if re.search(r'ERROR|CRITICAL|HIGH.*ERROR', ber_data, re.IGNORECASE):
                return "critical"
            elif re.search(r'WARNING|WARN', ber_data, re.IGNORECASE):
                return "warnings"
            
            return "good"
        except:
            return "good"

    def get_device_flap_status(self, device):
        """Get link flap status for a device from processed summary"""
        try:
            # Read from processed flap_history.json
            flap_history_file = self.monitor_results / "flap_history.json"
            if not flap_history_file.exists():
                return "stable"
                
            with open(flap_history_file, 'r') as f:
                flap_data = json.load(f)
            
            # Get flap stats for this device
            device_flap = flap_data.get(device, {})
            if device_flap:
                current_stats = device_flap.get("current_stats", {})
                # Look for flapping or flapped ports
                flapping_count = len(current_stats.get("flapping_ports", []))
                flapped_count = len(current_stats.get("flapped_ports", []))
                
                if flapping_count > 0:
                    return "critical"
                elif flapped_count > 0:
                    return "warnings"
            
            return "stable"
        except:
            return "stable"
    
    def get_device_optical_status(self, device):
        """Get optical diagnostics status for a device from processed summary"""
        try:
            # Read from processed optical_history.json
            optical_history_file = self.monitor_results / "optical_history.json"
            if not optical_history_file.exists():
                return "excellent"  # Default to healthy if no data
                
            with open(optical_history_file, 'r') as f:
                optical_data = json.load(f)
            
            # Get optical stats for this device
            device_optical = optical_data.get(device, {})
            if device_optical:
                current_stats = device_optical.get("current_stats", {})
                
                # Check for critical optical issues
                critical_ports = len(current_stats.get("critical_ports", []))
                warning_ports = len(current_stats.get("warning_ports", []))
                good_ports = len(current_stats.get("good_ports", []))
                excellent_ports = len(current_stats.get("excellent_ports", []))
                
                if critical_ports > 0:
                    return "critical"
                elif warning_ports > 0:
                    return "warnings"
                elif good_ports > 0:
                    return "good"
            
            return "excellent"
        except:
            return "excellent"

    def analyze_lldp_topology(self):
        """Analyze LLDP topology data like the web frontend does"""
        try:
            # Check if lldp_results.ini exists
            lldp_file = self.monitor_results.parent / "html" / "lldp_results.ini"
            if not lldp_file.exists():
                # Fall back to check in monitor-results
                lldp_file = self.monitor_results / "lldp_results.ini"
                if not lldp_file.exists():
                    return {"successful": 0, "failed": 0, "warnings": 0, "no_info": 0}
            
            with open(lldp_file, 'r') as f:
                data = f.read()
            
            # Parse LLDP data similar to the frontend JavaScript
            lines = data.split('\n')
            connections = []
            current_device = ''
            
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                    
                parts = line.split('\t')
                if len(parts) == 1:
                    # Device name line
                    current_device = parts[0]
                elif len(parts) >= 6 and current_device:
                    # Connection line
                    connection = {
                        'localDevice': current_device,
                        'localPort': parts[0],
                        'expectedDevice': parts[1] if parts[1] != 'N/A' else None,
                        'expectedPort': parts[2] if parts[2] != 'N/A' else None,
                        'actualDevice': parts[3] if parts[3] != 'N/A' else None,
                        'actualPort': parts[4] if parts[4] != 'N/A' else None,
                        'lldpStatus': parts[5]
                    }
                    connections.append(connection)
            
            # Count by status (replicate frontend logic)
            stats = {"successful": 0, "failed": 0, "warnings": 0, "no_info": 0}
            
            for connection in connections:
                status = self.determine_lldp_status(connection)
                if status == 'SUCCESS':
                    stats["successful"] += 1
                elif status == 'FAILED':
                    stats["failed"] += 1
                elif status == 'WARNING':
                    stats["warnings"] += 1
                elif status == 'NO INFO':
                    stats["no_info"] += 1
            
            return stats
            
        except Exception as e:
            print(f"    ❌ Error analyzing LLDP topology: {e}")
            return {"successful": 0, "failed": 0, "warnings": 0, "no_info": 0}
    
    def determine_lldp_status(self, connection):
        """Determine LLDP connection status (replicate frontend logic)"""
        lldp_status = connection.get('lldpStatus', '').upper()
        
        if lldp_status == 'SUCCESS':
            return 'SUCCESS'
        elif lldp_status == 'NO LLDP INFO':
            return 'NO INFO'
        elif lldp_status in ['MISSING FROM EXPECTED', 'EXTRA CONNECTION']:
            return 'WARNING'
        else:
            # Check if it's a connection mismatch
            expected_device = connection.get('expectedDevice')
            expected_port = connection.get('expectedPort') 
            actual_device = connection.get('actualDevice')
            actual_port = connection.get('actualPort')
            
            if (expected_device and actual_device and 
                (expected_device != actual_device or expected_port != actual_port)):
                return 'FAILED'
            else:
                return 'WARNING'

    def is_summary_time(self):
        """Check if it's time for scheduled summary"""
        strategy = self.config.get('alert_strategy', {})
        summary_times = strategy.get('summary_times', ['09:00', '17:00'])
        
        current_time = datetime.datetime.now().strftime("%H:%M")
        return current_time in summary_times

    def check_changes_only(self, devices):
        """Check and alert only on significant changes"""
        # This would compare with previous state and only alert on changes
        # For now, fall back to immediate mode
        print("🔄 Change-only mode not fully implemented, using immediate mode")
        for device in devices:
            print(f"  📍 Checking {device}...")
            try:
                self.check_hardware_alerts(device)
                self.check_network_alerts(device)
                self.check_log_alerts(device)
            except Exception as e:
                print(f"    ❌ Error checking {device}: {e}")
                continue

def main():
    """Main function"""
    if len(sys.argv) > 1:
        # Specific device check (for debugging)
        device = sys.argv[1]
        script_dir = os.path.dirname(os.path.abspath(__file__))
        alerts = LLDPqAlerts(script_dir)
        
        print(f"🔍 Checking alerts for device: {device}")
        alerts.check_hardware_alerts(device)
        alerts.check_network_alerts(device)
        alerts.check_log_alerts(device)
    else:
        # Check all devices
        script_dir = os.path.dirname(os.path.abspath(__file__))
        alerts = LLDPqAlerts(script_dir)
        alerts.check_all_devices()

if __name__ == "__main__":
    main()