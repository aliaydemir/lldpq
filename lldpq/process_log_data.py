#!/usr/bin/env python3
"""
Log Analysis Script
Processes collected log data and generates severity-based analysis

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import os
import re
import json
from datetime import datetime, timedelta
from collections import defaultdict

class LogAnalyzer:
    def __init__(self, data_dir="monitor-results"):
        self.data_dir = data_dir
        self.log_data_dir = os.path.join(data_dir, "log-data")
        self.log_analysis = defaultdict(lambda: {"critical": [], "warning": [], "error": [], "info": []})
        self.log_counts = defaultdict(lambda: {"critical": 0, "warning": 0, "error": 0, "info": 0})
        
        # Patterns that should NOT be critical (demoted to warning)
        # These are transient issues, not real critical problems
        self.excluded_from_critical = [
            r'sx_sdk.*bulk_counter',           # ASIC counter read errors
            r'bulk-cntr.*ioctl.*failed',       # Driver busy errors
            r'bulk-read.*transaction',         # Transaction errors
            r'device or resource busy',        # Resource busy
            r'port-counter-transaction',       # Port counter transaction errors
        ]
        
        # Patterns to completely ignore (not even counted as info)
        # These are our own monitoring commands or noise
        self.skip_patterns = [
            r'ethtool -m swp',               # Our optical monitoring commands
            r'cumulus.*sudo.*ethtool',       # sudo logs from our monitoring
            r'cumulus.*COMMAND=.*ethtool',   # sudo command logs
            r'cumulus.*COMMAND=.*l1-show',   # sudo l1-show commands
            r'cumulus.*COMMAND=.*sensors',   # sudo sensors commands
            r'pam_unix.*session opened',     # PAM session logs
            r'pam_unix.*session closed',     # PAM session logs
            r'connection collision resolution',  # Normal BGP behavior
        ]
        
        # Enhanced severity patterns for network infrastructure
        self.severity_patterns = {
            'critical': [
                r'\b(critical|emergency|panic|fatal|disaster|catastrophic)\b',
                r'\b(failed|failure|error|exception|crash|abort)\b.*\b(critical|severe)\b',
                r'\b(down|offline|unreachable|disconnected)\b.*\b(interface|link|connection|peer|neighbor)\b',
                r'\b(kernel panic|segmentation fault|out of memory|disk full)\b',
                r'priority:\s*[0-2]',  # Emergency, Alert, Critical
                # Network-specific critical patterns
                r'\b(bgp.*down|ospf.*down|routing.*failed|switching.*failed)\b',
                r'\b(mlag.*failed|clag.*conflict|spanning.*tree.*blocked)\b',
                r'\b(switchd.*died|nvued.*crashed|frr.*stopped)\b',
                r'\b(hardware.*fault|transceiver.*failed|port.*failed)\b',
            ],
            'warning': [
                r'\b(warning|warn|caution|alert)\b',
                r'\b(high|elevated|unusual|abnormal)\b.*\b(usage|load|temperature|traffic)\b',
                r'\b(timeout|retry|retransmit|flap|unstable)\b',
                r'\b(deprecat|obsolet|unsupport)\b',
                r'priority:\s*[3-4]',  # Error, Warning
                # Network-specific warning patterns
                r'\b(bgp.*flap|neighbor.*timeout|routing.*convergence)\b',
                r'\b(stp.*topology.*change|vlan.*inconsistent)\b',
                r'\b(mlag.*mismatch|bond.*degraded|link.*unstable)\b',
                r'\b(high.*utilization|buffer.*full|queue.*overflow)\b',
                r'\b(authentication.*failed|permission.*denied)\b',
            ],
            'error': [
                r'\b(error|err|exception|fault|fail)\b',
                r'\b(invalid|illegal|unauthorized|forbidden|denied)\b',
                r'\b(corrupt|damaged|broken|malformed)\b',
                r'\b(cannot|unable|refused|rejected)\b',
                r'priority:\s*[5-6]',  # Notice, Info (errors in context)
                # Network-specific error patterns
                r'\b(config.*error|nv.*set.*failed|commit.*failed)\b',
                r'\b(route.*unreachable|arp.*failed|mac.*learning.*failed)\b',
                r'\b(vxlan.*error|tunnel.*failed|encap.*error)\b',
            ],
            'info': [
                r'\b(info|information|notice|debug|trace)\b',
                r'\b(start|started|stop|stopped|restart|reload)\b',
                r'\b(up|online|connected|established|ready)\b',
                r'\b(configured|enabled|disabled|updated)\b',
                r'priority:\s*[7]',  # Debug
                # Network-specific info patterns
                r'\b(bgp.*established|neighbor.*up|route.*learned)\b',
                r'\b(interface.*up|link.*up|carrier.*detected)\b',
                r'\b(mlag.*sync|clag.*active|stp.*forwarding)\b',
                r'\b(config.*applied|nv.*set.*success|commit.*complete)\b',
            ]
        }
    
    def categorize_log_line(self, line):
        """Categorize a log line by severity"""
        line_lower = line.lower()
        
        # First check if this should be completely skipped (our own monitoring noise)
        for pattern in self.skip_patterns:
            if re.search(pattern, line_lower):
                return None  # Skip completely, don't count at all
        
        # Then check if this should be excluded from critical
        # These are transient issues that look critical but aren't
        for pattern in self.excluded_from_critical:
            if re.search(pattern, line_lower):
                return 'info'     # These are just noise, not real warnings
        
        # Check critical patterns first (highest priority)
        for pattern in self.severity_patterns['critical']:
            if re.search(pattern, line_lower):
                return 'critical'
        
        # Then warning patterns
        for pattern in self.severity_patterns['warning']:
            if re.search(pattern, line_lower):
                return 'warning'
        
        # Then error patterns
        for pattern in self.severity_patterns['error']:
            if re.search(pattern, line_lower):
                return 'error'
        
        # Default to info if no specific pattern matches
        return 'info'
    
    def parse_timestamp(self, line):
        """Extract timestamp from log line if available"""
        # Common timestamp patterns
        timestamp_patterns = [
            r'(\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2})',  # Nov 15 14:30:22
            r'(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})',  # 2024-11-15T14:30:22
            r'(\d{2}:\d{2}:\d{2})',                     # 14:30:22
        ]
        
        for pattern in timestamp_patterns:
            match = re.search(pattern, line)
            if match:
                return match.group(1)
        return None
    
    def parse_timestamp_to_datetime(self, line):
        """Extract timestamp from log line and convert to datetime object"""
        now = datetime.now()
        
        # Pattern 1: "Jan 13 18:37:49" format
        match = re.search(r'(\w{3})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})', line)
        if match:
            try:
                month_str, day, hour, minute, second = match.groups()
                month_map = {'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
                            'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12}
                month = month_map.get(month_str, 1)
                year = now.year
                log_dt = datetime(year, month, int(day), int(hour), int(minute), int(second))
                # Handle year rollover (if log is from December and now is January)
                if log_dt > now + timedelta(days=1):
                    log_dt = datetime(year - 1, month, int(day), int(hour), int(minute), int(second))
                return log_dt
            except:
                pass
        
        # Pattern 2: "2024-01-13T18:37:49" format
        match = re.search(r'(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})', line)
        if match:
            try:
                year, month, day, hour, minute, second = match.groups()
                return datetime(int(year), int(month), int(day), int(hour), int(minute), int(second))
            except:
                pass
        
        # Pattern 3: Just time "18:37:49" - assume today
        match = re.search(r'(\d{2}):(\d{2}):(\d{2})', line)
        if match:
            try:
                hour, minute, second = match.groups()
                return datetime(now.year, now.month, now.day, int(hour), int(minute), int(second))
            except:
                pass
        
        return None
    
    def adjust_severity_by_age(self, severity, log_datetime):
        """Adjust severity based on log age - older logs are less critical"""
        if log_datetime is None:
            return severity  # Can't determine age, keep original
        
        now = datetime.now()
        age = now - log_datetime
        age_minutes = age.total_seconds() / 60
        
        # Time-based severity adjustment:
        # - Last 30 minutes: Keep original severity
        # - 30 min to 2 hours: Demote critical → warning
        # - Over 2 hours: Demote critical/warning → info
        
        if age_minutes < 30:
            return severity  # Fresh log, keep original
        elif age_minutes < 120:  # 30 min - 2 hours
            if severity == 'critical':
                return 'warning'  # Demote critical to warning
            return severity
        else:  # Over 2 hours
            if severity in ('critical', 'warning'):
                return 'info'  # Demote to info (historical)
            return severity
    
    def process_device_logs(self, device_name, log_file_path):
        """Process logs for a single device"""
        if not os.path.exists(log_file_path):
            print(f"⚠️  Log file not found: {log_file_path}")
            return
        
        
        try:
            with open(log_file_path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
                
            # Split into sections based on log type markers
            sections = {
                'FRR_ROUTING_LOGS': [],
                'SWITCHD_LOGS': [],
                'NVUE_CONFIG_LOGS': [],
                'MSTPD_STP_LOGS': [],
                'CLAGD_MLAG_LOGS': [],
                'AUTH_SECURITY_LOGS': [],
                'SYSTEM_CRITICAL_LOGS': [],
                'JOURNALCTL_PRIORITY_LOGS': [],
                'DMESG_HARDWARE_LOGS': [],
                'NETWORK_INTERFACE_LOGS': []
            }
            
            current_section = None
            for line in content.split('\n'):
                line = line.strip()
                if not line:
                    continue
                
                # Check for section markers
                if line.startswith('===') or line.endswith(':'):
                    if 'FRR_ROUTING_LOGS' in line:
                        current_section = 'FRR_ROUTING_LOGS'
                    elif 'SWITCHD_LOGS' in line:
                        current_section = 'SWITCHD_LOGS'
                    elif 'NVUE_CONFIG_LOGS' in line:
                        current_section = 'NVUE_CONFIG_LOGS'
                    elif 'MSTPD_STP_LOGS' in line:
                        current_section = 'MSTPD_STP_LOGS'
                    elif 'CLAGD_MLAG_LOGS' in line:
                        current_section = 'CLAGD_MLAG_LOGS'
                    elif 'AUTH_SECURITY_LOGS' in line:
                        current_section = 'AUTH_SECURITY_LOGS'
                    elif 'SYSTEM_CRITICAL_LOGS' in line:
                        current_section = 'SYSTEM_CRITICAL_LOGS'
                    elif 'JOURNALCTL_PRIORITY_LOGS' in line:
                        current_section = 'JOURNALCTL_PRIORITY_LOGS'
                    elif 'DMESG_HARDWARE_LOGS' in line:
                        current_section = 'DMESG_HARDWARE_LOGS'
                    elif 'NETWORK_INTERFACE_LOGS' in line:
                        current_section = 'NETWORK_INTERFACE_LOGS'
                    continue
                
                # Skip non-informative lines
                if (line.startswith('No ') or line == '' or len(line) < 10 or 
                    'No entries' in line or line.strip() == '-- No entries --' or
                    'not found' in line.lower() or 'log not found' in line):
                    continue
                
                if current_section:
                    sections[current_section].append(line)
            
            # Process each section
            for section_name, lines in sections.items():
                for line in lines:
                    if len(line.strip()) < 5:  # Skip very short lines
                        continue
                    
                    severity = self.categorize_log_line(line)
                    
                    # Skip if severity is None (monitoring noise)
                    if severity is None:
                        continue
                    
                    timestamp = self.parse_timestamp(line)
                    
                    # Adjust severity based on log age (older logs are less critical)
                    log_datetime = self.parse_timestamp_to_datetime(line)
                    original_severity = severity
                    severity = self.adjust_severity_by_age(severity, log_datetime)
                    
                    log_entry = {
                        'timestamp': timestamp,
                        'section': section_name,
                        'message': line.strip(),
                        'severity': severity,
                        'original_severity': original_severity if original_severity != severity else None
                    }
                    
                    self.log_analysis[device_name][severity].append(log_entry)
                    self.log_counts[device_name][severity] += 1
        
        except Exception as e:
            print(f"❌ Error processing logs for {device_name}: {e}")
    
    def generate_html_report(self):
        """Generate HTML report for log analysis"""
        print("🎨 Generating log analysis HTML report...")
        
        # Calculate totals
        total_devices = len(self.log_counts)
        totals = {"critical": 0, "warning": 0, "error": 0, "info": 0}
        
        for device_counts in self.log_counts.values():
            for severity in totals:
                totals[severity] += device_counts[severity]
        
        html_content = f"""
<!DOCTYPE html>
<html>
<head>
    <title>Log Analysis Results</title>
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
            cursor: pointer;
            transition: all 0.3s ease;
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
        
        /* Card labels - visible on light card background */
        .summary-card div:not(.metric) {{ color: #666; }}
        
        .log-excellent {{ color: #4caf50; font-weight: bold; }}
        .log-good {{ color: #8bc34a; font-weight: bold; }}
        .log-warning {{ color: #ff9800; font-weight: bold; }}
        .log-critical {{ color: #f44336; font-weight: bold; }}
        
        /* Total log count color coding like other analysis pages */
        .total-excellent {{ color: #4caf50; font-weight: bold; }}
        .total-good {{ color: #8bc34a; font-weight: bold; }}
        .total-warning {{ color: #ff9800; font-weight: bold; }}
        .total-critical {{ color: #f44336; font-weight: bold; }}
        
        /* Sortable table styling - same as Hardware Analysis */
        .sortable {{ cursor: pointer; user-select: none; position: relative; padding-right: 20px; }}
        .sortable:hover {{ background-color: #f5f5f5; }}
        .sort-arrow {{ font-size: 10px; color: #999; margin-left: 5px; opacity: 0.5; }}
        .sortable.asc .sort-arrow::before {{ content: '▲'; color: #b57614; opacity: 1; }}
        .sortable.desc .sort-arrow::before {{ content: '▼'; color: #b57614; opacity: 1; }}
        .sortable.asc .sort-arrow, .sortable.desc .sort-arrow {{ opacity: 1; }}
        
        .log-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; table-layout: fixed; }}
        .log-table th, .log-table td {{ border: 1px solid #ddd; padding: 5px 8px; text-align: left; word-wrap: break-word; }}
        .log-table th {{ background-color: #f2f2f2; font-weight: bold; padding: 8px 8px; }}
        
        /* Column width specifications */
        .log-table th:nth-child(1), .log-table td:nth-child(1) {{ width: 20%; }} /* Device */
        .log-table th:nth-child(2), .log-table td:nth-child(2) {{ width: 15%; }} /* Critical */
        .log-table th:nth-child(3), .log-table td:nth-child(3) {{ width: 15%; }} /* Warning */
        .log-table th:nth-child(4), .log-table td:nth-child(4) {{ width: 15%; }} /* Error */
        .log-table th:nth-child(5), .log-table td:nth-child(5) {{ width: 15%; }} /* Info */
        .log-table th:nth-child(6), .log-table td:nth-child(6) {{ width: 20%; }} /* Total */
        
        .severity-count {{
            display: inline-block;
            padding: 2px 6px;
            border-radius: 4px;
            font-weight: bold;
            cursor: pointer;
            transition: all 0.3s ease;
            min-width: 25px;
            text-align: center;
        }}
        
        .severity-count:hover {{
            transform: scale(1.05);
            box-shadow: 0 2px 4px rgba(0,0,0,0.2);
        }}
        
        .severity-count.critical {{
            background: #ffebee;
            color: #f44336;
            border: 1px solid #f44336;
        }}
        
        .severity-count.warning {{
            background: #fff3e0;
            color: #ff9800;
            border: 1px solid #ff9800;
        }}
        
        .severity-count.error {{
            background: #fff3e0;
            color: #ff9800;
            border: 1px solid #ff9800;
        }}
        
        .severity-count.info {{
            background: #e3f2fd;
            color: #2196f3;
            border: 1px solid #2196f3;
        }}
        
        .severity-count.zero {{
            background: #f5f5f5;
            color: #9e9e9e;
            border: 1px solid #e0e0e0;
            cursor: default;
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
        
        .log-details {{
            display: none;
            background: #f8f9fa;
            border: 1px solid #e2e8f0;
            border-radius: 8px;
            margin: 10px 0;
            max-height: 400px;
            overflow-y: auto;
        }}
        
        .log-entry {{
            padding: 10px 15px;
            border-bottom: 1px solid #e2e8f0;
            font-family: 'Courier New', monospace;
            font-size: 0.9em;
        }}
        
        .log-entry:last-child {{
            border-bottom: none;
        }}
        
        .log-timestamp {{
            color: #666;
            margin-right: 10px;
        }}
        
        .log-section {{
            background: #e2e8f0;
            color: #2d3748;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.8em;
            margin-right: 10px;
        }}
        
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
    <h1><font color="#b57614">Log Analysis Results</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px;">
        <h2 style="margin: 0;">Log Summary</h2>
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
        <div class="summary-card card-total" id="total-devices-card">
            <div class="metric" id="total-devices">{total_devices}</div>
            <div>Total Devices</div>
        </div>
        <div class="summary-card card-critical" id="critical-card">
            <div class="metric log-critical" id="critical-logs">{totals['critical']}</div>
            <div>Critical Issues</div>
        </div>
        <div class="summary-card card-warning" id="warning-card">
            <div class="metric log-warning" id="warning-logs">{totals['warning']}</div>
            <div>Warning Messages</div>
        </div>
        <div class="summary-card card-warning" id="error-card">
            <div class="metric log-warning" id="error-logs">{totals['error']}</div>
            <div>Error Messages</div>
        </div>
        <div class="summary-card card-excellent" id="info-card">
            <div class="metric log-good" id="info-logs">{totals['info']}</div>
            <div>Info Messages</div>
        </div>
    </div>
    
    <div id="filter-info" class="filter-info">
        <span id="filter-text"></span>
        <button onclick="clearFilter()" style="margin-left: 10px; padding: 2px 8px; background: #1976d2; color: white; border: none; border-radius: 3px; cursor: pointer;">Show All</button>
    </div>
    
    <h2>Device Log Details</h2>
    <table class="log-table" id="log-table">
        <thead>
            <tr>
                <th class="sortable" data-column="0" data-type="string">Device <span class="sort-arrow">▲▼</span></th>
                <th class="sortable" data-column="1" data-type="number">Critical <span class="sort-arrow">▲▼</span></th>
                <th class="sortable" data-column="2" data-type="number">Warning <span class="sort-arrow">▲▼</span></th>
                <th class="sortable" data-column="3" data-type="number">Error <span class="sort-arrow">▲▼</span></th>
                <th class="sortable" data-column="4" data-type="number">Info <span class="sort-arrow">▲▼</span></th>
                <th class="sortable" data-column="5" data-type="number">Total <span class="sort-arrow">▲▼</span></th>
            </tr>
        </thead>
        <tbody>"""
        
        # Sort devices by total log count (descending)
        sorted_devices = sorted(self.log_counts.items(), 
                              key=lambda x: sum(x[1].values()), reverse=True)
        
        for device_name, counts in sorted_devices:
            total_count = sum(counts.values())
            
            # Color code total count like other analysis pages
            if total_count == 0:
                total_class = "total-excellent"
            elif total_count <= 50:
                total_class = "total-good" 
            elif total_count <= 100:
                total_class = "total-warning"
            else:
                total_class = "total-critical"
            
            html_content += f"""
                    <tr>
                        <td>{device_name}</td>
                        <td>
                            <span class="severity-count critical {'zero' if counts['critical'] == 0 else ''}" 
                                  data-device="{device_name}" data-severity="critical"
                                  id="critical-{device_name}">
                                {counts['critical']}
                            </span>
                        </td>
                        <td>
                            <span class="severity-count warning {'zero' if counts['warning'] == 0 else ''}" 
                                  data-device="{device_name}" data-severity="warning"
                                  id="warning-{device_name}">
                                {counts['warning']}
                            </span>
                        </td>
                        <td>
                            <span class="severity-count error {'zero' if counts['error'] == 0 else ''}" 
                                  data-device="{device_name}" data-severity="error"
                                  id="error-{device_name}">
                                {counts['error']}
                            </span>
                        </td>
                        <td>
                            <span class="severity-count info {'zero' if counts['info'] == 0 else ''}" 
                                  data-device="{device_name}" data-severity="info"
                                  id="info-{device_name}">
                                {counts['info']}
                            </span>
                        </td>
                        <td><span class="{total_class}">{total_count}</span></td>
                    </tr>
                    <tr id="details-{device_name}-critical" class="log-details">
                        <td colspan="6">
                            <div id="content-{device_name}-critical"></div>
                        </td>
                    </tr>
                    <tr id="details-{device_name}-warning" class="log-details">
                        <td colspan="6">
                            <div id="content-{device_name}-warning"></div>
                        </td>
                    </tr>
                    <tr id="details-{device_name}-error" class="log-details">
                        <td colspan="6">
                            <div id="content-{device_name}-error"></div>
                        </td>
                    </tr>
                    <tr id="details-{device_name}-info" class="log-details">
                        <td colspan="6">
                            <div id="content-{device_name}-info"></div>
                        </td>
                    </tr>"""
        
        html_content += """
        </tbody>
    </table>
    
    <!-- jQuery and Select2 for device search -->
    <script src="/css/jquery-3.5.1.min.js"></script>
    <script src="/css/select2.min.js"></script>
    
    <script>
        // Log data embedded in the page
        const logData = """ + json.dumps(dict(self.log_analysis), indent=2) + """;
        
        // Initialize page functionality
        let deviceSearchActive = false;
        let selectedDevice = '';
        
        document.addEventListener('DOMContentLoaded', function() {
            initSummaryCardFilters();
            initTableSorting();
            initLogDetailsClickHandlers();
            
            // Initialize device search
            populateDeviceList();
            initDeviceSearch();
        });
        
        function initLogDetailsClickHandlers() {
            // Event delegation for severity count clicks (survives table sorting)
            const table = document.getElementById('log-table');
            table.addEventListener('click', function(event) {
                if (event.target.classList.contains('severity-count') && !event.target.classList.contains('zero')) {
                    const deviceName = event.target.getAttribute('data-device');
                    const severity = event.target.getAttribute('data-severity');
                    if (deviceName && severity) {
                        toggleLogDetails(deviceName, severity);
                    }
                }
            });
        }
        
        function initSummaryCardFilters() {
            // Add click handlers to summary cards
            document.getElementById('total-devices-card').addEventListener('click', () => clearFilter());
            document.getElementById('critical-card').addEventListener('click', () => filterTable('critical'));
            document.getElementById('warning-card').addEventListener('click', () => filterTable('warning'));  
            document.getElementById('error-card').addEventListener('click', () => filterTable('error'));
            document.getElementById('info-card').addEventListener('click', () => filterTable('info'));
        }
        
        function filterTable(severity) {
            const table = document.querySelector('.log-table');
            const rows = table.querySelectorAll('tbody tr');
            const filterInfo = document.getElementById('filter-info');
            const filterText = document.getElementById('filter-text');
            
            // Clear device search when using card filters
            if (deviceSearchActive) {
                selectedDevice = '';
                deviceSearchActive = false;
                $('#deviceSearch').val('').trigger('change');
                document.getElementById('clearSearchBtn').style.display = 'none';
            }
            
            // Remove active class from all cards
            document.querySelectorAll('.summary-card').forEach(card => card.classList.remove('active'));
            
            // Add active class to clicked card
            document.getElementById(severity + '-card').classList.add('active');
            
            let visibleCount = 0;
            
            // Filter table rows
            rows.forEach(row => {
                if (row.classList.contains('log-details')) {
                    row.style.display = 'none';
                    return;
                }
                
                const severityCell = getSeverityCellValue(row, severity);
                
                if (severityCell > 0) {
                    row.style.display = '';
                    visibleCount++;
                } else {
                    row.style.display = 'none';
                }
            });
            
            // Show filter info
            const severityLabels = {
                'critical': 'Critical Issues',
                'warning': 'Warning Messages', 
                'error': 'Error Messages',
                'info': 'Info Messages'
            };
            
            filterText.textContent = `Showing ${visibleCount} devices with ${severityLabels[severity]}`;
            filterInfo.style.display = 'block';
        }
        
        function getSeverityCellValue(row, severity) {
            const severityMap = {
                'critical': 1, // Column index for Critical
                'warning': 2,  // Column index for Warning  
                'error': 3,    // Column index for Error
                'info': 4      // Column index for Info
            };
            
            const cellIndex = severityMap[severity];
            if (!cellIndex) return 0;
            
            const cell = row.cells[cellIndex];
            if (!cell) return 0;
            
            const countElement = cell.querySelector('.severity-count');
            if (!countElement) return 0;
            
            return parseInt(countElement.textContent) || 0;
        }
        
        function clearFilter() {
            const table = document.querySelector('.log-table');
            const allRows = table.querySelectorAll('tbody tr');
            const filterInfo = document.getElementById('filter-info');
            
            // Also clear device search
            if (deviceSearchActive) {
                selectedDevice = '';
                deviceSearchActive = false;
                $('#deviceSearch').val('').trigger('change');
                document.getElementById('clearSearchBtn').style.display = 'none';
            }
            
            // Remove active class from all cards
            document.querySelectorAll('.summary-card').forEach(card => card.classList.remove('active'));
            
            // Add active class to total card
            document.getElementById('total-devices-card').classList.add('active');
            
            // Hide filter info
            filterInfo.style.display = 'none';
            
            // Show all rows (except detail rows)
            allRows.forEach(row => {
                if (row.classList.contains('log-details')) {
                    row.style.display = 'none';
                } else {
                    row.style.display = '';
                }
            });
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
            const table = document.querySelector('.log-table');
            const rows = table.querySelectorAll('tbody tr');
            const deviceSet = new Set();
            
            rows.forEach(row => {
                if (!row.classList.contains('log-details')) {
                    const deviceName = row.cells[0]?.textContent?.trim();
                    if (deviceName) deviceSet.add(deviceName);
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
            document.querySelectorAll('.summary-card').forEach(card => card.classList.remove('active'));
            
            const table = document.querySelector('.log-table');
            const rows = table.querySelectorAll('tbody tr');
            const filterInfo = document.getElementById('filter-info');
            const filterText = document.getElementById('filter-text');
            
            // Filter table rows
            let matchCount = 0;
            rows.forEach(row => {
                if (row.classList.contains('log-details')) {
                    row.style.display = 'none';
                    return;
                }
                
                const rowDeviceName = row.cells[0]?.textContent?.trim();
                if (rowDeviceName === deviceName) {
                    row.style.display = '';
                    matchCount++;
                } else {
                    row.style.display = 'none';
                }
            });
            
            // Show filter info
            filterText.textContent = 'Showing logs for device: ' + deviceName;
            filterInfo.style.display = 'block';
            document.getElementById('clearSearchBtn').style.display = 'inline-block';
        }
        
        function clearDeviceSearch() {
            selectedDevice = '';
            deviceSearchActive = false;
            $('#deviceSearch').val('').trigger('change');
            document.getElementById('clearSearchBtn').style.display = 'none';
            
            const table = document.querySelector('.log-table');
            const allRows = table.querySelectorAll('tbody tr');
            const filterInfo = document.getElementById('filter-info');
            
            filterInfo.style.display = 'none';
            allRows.forEach(row => {
                if (row.classList.contains('log-details')) {
                    row.style.display = 'none';
                } else {
                    row.style.display = '';
                }
            });
        }
        
        function toggleLogDetails(deviceName, severity) {
            const detailsRow = document.getElementById(`details-${deviceName}-${severity}`);
            const contentDiv = document.getElementById(`content-${deviceName}-${severity}`);
            
            // Check if elements exist (should always exist now)
            if (!detailsRow || !contentDiv) {
                return;
            }
            
            // Hide all other details first
            document.querySelectorAll('.log-details').forEach(row => {
                if (row.id !== `details-${deviceName}-${severity}`) {
                    row.style.display = 'none';
                }
            });
            
            if (detailsRow.style.display === 'table-row') {
                detailsRow.style.display = 'none';
                return;
            }
            
            // Check if logs exist for this severity
            const logs = logData[deviceName] && logData[deviceName][severity];
            if (!logs || logs.length === 0) {
                return; // Don't show anything for zero counts
            }
            
            // Populate content if not already done
            if (contentDiv.innerHTML === '') {
                contentDiv.innerHTML = logs.map(log => `
                    <div class="log-entry">
                        ${log.timestamp ? `<span class="log-timestamp">${log.timestamp}</span>` : ''}
                        <span class="log-section">${log.section}</span>
                        <span class="log-message">${log.message}</span>
                    </div>
                `).join('');
            }
            
            detailsRow.style.display = 'table-row';
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
                    sortLogTable(column, tableSortState.direction, type);
                });
            });
        }
        
        function sortLogTable(columnIndex, direction, type) {
            const table = document.getElementById('log-table');
            const tbody = table.querySelector('tbody');
            const rows = Array.from(tbody.rows).filter(row => !row.classList.contains('log-details'));
            
            rows.sort((a, b) => {
                let aVal, bVal;
                
                if (type === 'number' && columnIndex > 0) {
                    // For severity count columns, try to get number from span first, then fallback to direct text
                    const aSpan = a.cells[columnIndex].querySelector('.severity-count');
                    const bSpan = b.cells[columnIndex].querySelector('.severity-count');
                    
                    if (aSpan && bSpan) {
                        // Severity columns with spans
                        aVal = parseInt(aSpan.textContent) || 0;
                        bVal = parseInt(bSpan.textContent) || 0;
                    } else {
                        // Total column (direct text content)
                        aVal = parseInt(a.cells[columnIndex].textContent.trim()) || 0;
                        bVal = parseInt(b.cells[columnIndex].textContent.trim()) || 0;
                    }
                } else {
                    // For device names and other text
                    aVal = a.cells[columnIndex].textContent.trim();
                    bVal = b.cells[columnIndex].textContent.trim();
                }
                
                let result = 0;
                
                switch(type) {
                    case 'number':
                        result = aVal - bVal;
                        break;
                    case 'string':
                    default:
                        result = aVal.localeCompare(bVal, undefined, { numeric: true, sensitivity: 'base' });
                        break;
                }
                
                return direction === 'desc' ? -result : result;
            });
            
            // DIFFERENT APPROACH: Move existing DOM nodes instead of destroying them
            rows.forEach((row, index) => {
                const deviceName = row.cells[0].textContent.trim();
                
                // Move the device row to its new position
                tbody.appendChild(row);
                
                // Move the associated log-details rows right after the device row
                const logDetailsRows = Array.from(tbody.querySelectorAll('.log-details')).filter(
                    detailRow => detailRow.id.includes(deviceName)
                );
                logDetailsRows.forEach(detailRow => tbody.appendChild(detailRow));
            });
        }
        
        // reattachClickHandlers function removed - no longer needed since we don't destroy DOM nodes
        
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
                const filename = `Log_Analysis_Report_${dateStr}_${timeStr}.csv`;
                
                // Create CSV header
                const headers = [
                    'Device',
                    'Critical',
                    'Warning',
                    'Error',
                    'Info',
                    'Total'
                ];
                
                let csvContent = headers.join(',') + '\\n';
                
                // Get table data (only visible rows)
                const table = document.getElementById('log-table');
                const tbody = table.querySelector('tbody');
                const rows = tbody.querySelectorAll('tr');
                
                // Add summary stats as comments
                csvContent += `# Log Analysis Summary Report\\n`;
                csvContent += `# Generated: ${now.toLocaleString()}\\n`;
                csvContent += `# Total Devices: ${document.getElementById('total-devices').textContent}\\n`;
                csvContent += `# Critical Issues: ${document.getElementById('critical-logs').textContent}\\n`;
                csvContent += `# Warning Messages: ${document.getElementById('warning-logs').textContent}\\n`;
                csvContent += `# Error Messages: ${document.getElementById('error-logs').textContent}\\n`;
                csvContent += `# Info Messages: ${document.getElementById('info-logs').textContent}\\n`;
                csvContent += `#\\n`;
                
                // Process each visible row (skip log-details rows)
                rows.forEach(row => {
                    if (row.style.display !== 'none' && !row.classList.contains('log-details')) {
                        const cells = row.querySelectorAll('td');
                        if (cells.length >= 6) {
                            const rowData = [
                                cells[0].textContent.trim(), // Device
                                cells[1].querySelector('.severity-count') ? cells[1].querySelector('.severity-count').textContent.trim() : '0', // Critical
                                cells[2].querySelector('.severity-count') ? cells[2].querySelector('.severity-count').textContent.trim() : '0', // Warning
                                cells[3].querySelector('.severity-count') ? cells[3].querySelector('.severity-count').textContent.trim() : '0', // Error
                                cells[4].querySelector('.severity-count') ? cells[4].querySelector('.severity-count').textContent.trim() : '0', // Info
                                cells[5].textContent.trim()  // Total
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
        
        # Write HTML file
        output_file = os.path.join(self.data_dir, "log-analysis.html")
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(html_content)
        
        print(f"✅ Log analysis HTML generated: {output_file}")
    
    def save_summary_data(self):
        """Save summary data for dashboard integration"""
        summary_data = {
            "timestamp": datetime.now().isoformat(),
            "total_devices": len(self.log_counts),
            "totals": {
                "critical": sum(device["critical"] for device in self.log_counts.values()),
                "warning": sum(device["warning"] for device in self.log_counts.values()),
                "error": sum(device["error"] for device in self.log_counts.values()),
                "info": sum(device["info"] for device in self.log_counts.values())
            },
            "device_counts": dict(self.log_counts)
        }
        
        summary_file = os.path.join(self.data_dir, "log_summary.json")
        with open(summary_file, 'w') as f:
            json.dump(summary_data, f, indent=2)
        
        print(f"✅ Log summary data saved: {summary_file}")
    
    def run_analysis(self):
        """Main analysis function"""
        print("🚀 Starting log analysis...")
        
        if not os.path.exists(self.log_data_dir):
            print(f"❌ Log data directory not found: {self.log_data_dir}")
            return False
        
        # Process all log files
        log_files = [f for f in os.listdir(self.log_data_dir) if f.endswith('_logs.txt')]
        
        if not log_files:
            print("⚠️  No log files found")
            return False
        
        for log_file in log_files:
            device_name = log_file.replace('_logs.txt', '')
            log_file_path = os.path.join(self.log_data_dir, log_file)
            
            # Ensure device is initialized in counts (even if no logs)
            if device_name not in self.log_counts:
                self.log_counts[device_name] = {"critical": 0, "warning": 0, "error": 0, "info": 0}
                self.log_analysis[device_name] = {"critical": [], "warning": [], "error": [], "info": []}
            
            self.process_device_logs(device_name, log_file_path)
        
        print(f"📊 Processed {len(log_files)} devices")
        
        # Generate outputs
        self.generate_html_report()
        self.save_summary_data()
        
        # Print summary
        total_logs = sum(sum(device.values()) for device in self.log_counts.values())
        total_critical = sum(device["critical"] for device in self.log_counts.values())
        total_warning = sum(device["warning"] for device in self.log_counts.values())
        
        print(f"📈 Analysis complete:")
        print(f"   • Total devices: {len(self.log_counts)}")
        print(f"   • Total log entries: {total_logs}")
        print(f"   • Critical issues: {total_critical}")
        print(f"   • Warnings: {total_warning}")
        
        return True

def main():
    """Main entry point"""
    try:
        analyzer = LogAnalyzer()
        success = analyzer.run_analysis()
        return 0 if success else 1
    except Exception as e:
        print(f"❌ Log analysis failed: {e}")
        return 1

if __name__ == "__main__":
    exit(main())