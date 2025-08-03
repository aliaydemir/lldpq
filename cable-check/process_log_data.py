#!/usr/bin/env python3
"""
Log Analysis Script
Processes collected log data and generates severity-based analysis
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
    
    def process_device_logs(self, device_name, log_file_path):
        """Process logs for a single device"""
        if not os.path.exists(log_file_path):
            print(f"⚠️  Log file not found: {log_file_path}")
            return
        
        print(f"📊 Processing logs for {device_name}")
        
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
                if line.startswith('No ') or line == '' or len(line) < 10:
                    continue
                
                if current_section:
                    sections[current_section].append(line)
            
            # Process each section
            for section_name, lines in sections.items():
                for line in lines:
                    if len(line.strip()) < 5:  # Skip very short lines
                        continue
                    
                    severity = self.categorize_log_line(line)
                    timestamp = self.parse_timestamp(line)
                    
                    log_entry = {
                        'timestamp': timestamp,
                        'section': section_name,
                        'message': line.strip(),
                        'severity': severity
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
        
        /* Card labels light theme */
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
        
        /* Sortable table styling - light theme like other analysis pages */
        .sortable {{ cursor: pointer; user-select: none; position: relative; padding-right: 20px; }}
        .sortable:hover {{ background-color: #f5f5f5; }}
        .sort-arrow {{ font-size: 10px; color: #999; margin-left: 5px; opacity: 0.5; }}
        .sortable.asc .sort-arrow::before {{ content: '▲'; color: #b57614; opacity: 1; }}
        .sortable.desc .sort-arrow::before {{ content: '▼'; color: #b57614; opacity: 1; }}
        .sortable.asc .sort-arrow, .sortable.desc .sort-arrow {{ opacity: 1; }}
        
        .log-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; table-layout: fixed; }}
        .log-table th, .log-table td {{ border: 1px solid #43453B; padding: 8px; text-align: left; word-wrap: break-word; }}
        .log-table th {{ background-color: #2a2a2a; font-weight: bold; color: #cccccc; }}
        .log-table tbody tr {{ background-color: #1a1a1a; }}
        .log-table tbody tr:nth-child(even) {{ background-color: #252525; }}
        
        /* Column width specifications */
        .log-table th:nth-child(1), .log-table td:nth-child(1) {{ width: 20%; }} /* Device */
        .log-table th:nth-child(2), .log-table td:nth-child(2) {{ width: 15%; }} /* Critical */
        .log-table th:nth-child(3), .log-table td:nth-child(3) {{ width: 15%; }} /* Warning */
        .log-table th:nth-child(4), .log-table td:nth-child(4) {{ width: 15%; }} /* Error */
        .log-table th:nth-child(5), .log-table td:nth-child(5) {{ width: 15%; }} /* Info */
        .log-table th:nth-child(6), .log-table td:nth-child(6) {{ width: 20%; }} /* Total */
        
        .device-name {{
            font-weight: 600;
            color: #2d3748;
        }}
        
        /* Ensure all table text is dark on light background - like other analysis pages */
        .log-table td {{
            color: #333333;
            background-color: inherit;
        }}
        
        /* Device names should be clearly visible */
        .log-table .device-name {{
            color: #2d3748;
            font-weight: 600;
        }}
        
        .severity-count {{
            display: inline-block;
            padding: 4px 8px;
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
            color: #333333;
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
    </style>
</head>
<body>
    <h1></h1>
    <h1><font color="#b57614">Log Analysis Results</font></h1>
    <p><strong>Last Updated:</strong> {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
    
    <h2>Log Summary</h2>
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
                <th class="sortable" data-column="0" data-type="string">Device Name <span class="sort-arrow">▲▼</span></th>
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
                        <td class="device-name">{device_name}</td>
                        <td>
                            <span class="severity-count critical {'zero' if counts['critical'] == 0 else ''}" 
                                  onclick="toggleLogDetails('{device_name}', 'critical')" 
                                  id="critical-{device_name}">
                                {counts['critical']}
                            </span>
                        </td>
                        <td>
                            <span class="severity-count warning {'zero' if counts['warning'] == 0 else ''}" 
                                  onclick="toggleLogDetails('{device_name}', 'warning')"
                                  id="warning-{device_name}">
                                {counts['warning']}
                            </span>
                        </td>
                        <td>
                            <span class="severity-count error {'zero' if counts['error'] == 0 else ''}" 
                                  onclick="toggleLogDetails('{device_name}', 'error')"
                                  id="error-{device_name}">
                                {counts['error']}
                            </span>
                        </td>
                        <td>
                            <span class="severity-count info {'zero' if counts['info'] == 0 else ''}" 
                                  onclick="toggleLogDetails('{device_name}', 'info')"
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
    
    <script>
        // Log data embedded in the page
        const logData = """ + json.dumps(dict(self.log_analysis), indent=2) + """;
        
        // Initialize page functionality
        document.addEventListener('DOMContentLoaded', function() {
            initSummaryCardFilters();
            initTableSorting();
        });
        
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
        
        function toggleLogDetails(deviceName, severity) {
            const detailsRow = document.getElementById(`details-${deviceName}-${severity}`);
            const contentDiv = document.getElementById(`content-${deviceName}-${severity}`);
            
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
                    // For severity count columns, get the number from the span
                    const aSpan = a.cells[columnIndex].querySelector('.severity-count');
                    const bSpan = b.cells[columnIndex].querySelector('.severity-count');
                    aVal = aSpan ? parseInt(aSpan.textContent) || 0 : 0;
                    bVal = bSpan ? parseInt(bSpan.textContent) || 0 : 0;
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
            
            // Clear tbody and add sorted rows back
            tbody.innerHTML = '';
            rows.forEach(row => {
                tbody.appendChild(row);
                // Re-append any log details rows that belong to this device
                const deviceName = row.cells[0].textContent.trim();
                const detailRows = Array.from(document.querySelectorAll('.log-details')).filter(
                    detailRow => detailRow.id.includes(deviceName)
                );
                detailRows.forEach(detailRow => tbody.appendChild(detailRow));
            });
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