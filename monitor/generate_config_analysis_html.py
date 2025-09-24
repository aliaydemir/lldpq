#!/usr/bin/env python3
"""
Generate Config Analysis HTML for LLDPq
=======================================

Creates HTML reports from configuration anomaly detection results.

Copyright (c) 2024 LLDPq Project  
Licensed under MIT License - see LICENSE file for details
"""

import os
import json
import glob
from datetime import datetime

def generate_config_analysis_html():
    """Generate HTML report from config analysis results"""
    
    analysis_dir = "monitor-results/config-analysis"
    output_file = "/var/www/html/monitor-results/config-analysis.html"
    
    # Ensure output directory exists
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    
    # Find all anomaly report files
    report_files = glob.glob(f"{analysis_dir}/*_anomalies.txt")
    
    # Parse reports
    devices_data = []
    total_anomalies = 0
    high_severity_total = 0
    medium_severity_total = 0
    
    for report_file in report_files:
        device_name = os.path.basename(report_file).replace('_anomalies.txt', '')
        
        try:
            with open(report_file, 'r') as f:
                content = f.read()
            
            # Parse the text report to extract statistics
            lines = content.split('\n')
            device_data = {
                'name': device_name,
                'total_issues': 0,
                'high_severity': 0,
                'medium_severity': 0,
                'status': 'CLEAN',
                'issues': []
            }
            
            # Extract statistics from report
            for line in lines:
                if 'Total Issues:' in line:
                    device_data['total_issues'] = int(line.split(':')[1].strip())
                    total_anomalies += device_data['total_issues']
                elif 'High Severity:' in line:
                    device_data['high_severity'] = int(line.split(':')[1].strip())
                    high_severity_total += device_data['high_severity']
                elif 'Medium Severity:' in line:
                    device_data['medium_severity'] = int(line.split(':')[1].strip())
                    medium_severity_total += device_data['medium_severity']
                elif line.startswith('Line ') and ':' in line:
                    # Parse individual issues
                    parts = line.split(':', 2)
                    if len(parts) >= 3:
                        line_num = parts[0].replace('Line ', '').strip()
                        error = parts[1].strip()
                        device_data['issues'].append({
                            'line': line_num,
                            'error': error
                        })
            
            # Determine status
            if device_data['high_severity'] > 0:
                device_data['status'] = 'CRITICAL'
            elif device_data['medium_severity'] > 0:
                device_data['status'] = 'WARNING'
            elif device_data['total_issues'] == 0:
                device_data['status'] = 'CLEAN'
            else:
                device_data['status'] = 'INFO'
                
            devices_data.append(device_data)
            
        except Exception as e:
            print(f"Error processing {report_file}: {e}")
    
    # Sort devices by severity (critical first)
    devices_data.sort(key=lambda x: (
        x['status'] != 'CRITICAL',
        x['status'] != 'WARNING', 
        x['status'] != 'INFO',
        x['status'] != 'CLEAN',
        x['name']
    ))
    
    # Generate HTML
    html_content = f"""<!DOCTYPE html>
<html>
<head>
    <link rel="shortcut icon" href="/png/favicon.ico">
    <title>..::LLDPQ::..</title>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8" />
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
        .card-warning {{ border-left-color: #ff9800; }}
        .card-critical {{ border-left-color: #f44336; }}
        .card-total {{ border-left-color: #2196f3; }}
        .card-value {{ font-size: 24px; font-weight: bold; color: #333; }}
        .card-label {{ font-size: 14px; color: #666; margin-top: 5px; }}
        
        .status-clean {{ color: #4caf50; font-weight: bold; }}
        .status-warning {{ color: #ff9800; font-weight: bold; }}
        .status-critical {{ color: #f44336; font-weight: bold; }}
        .status-info {{ color: #2196f3; font-weight: bold; }}
        
        .analysis-table {{ width: 100%; border-collapse: collapse; margin: 20px 0; }}
        .analysis-table th, .analysis-table td {{ border: 1px solid #ddd; padding: 8px; text-align: left; }}
        .analysis-table th {{ background-color: #f2f2f2; }}
        
        .device-link {{
            color: inherit;
            text-decoration: underline;
            transition: all 0.3s ease;
        }}
        
        .device-link:hover {{
            color: #b57614 !important;
            text-shadow: 0 0 8px rgba(181, 118, 20, 0.6);
        }}
        
        .issue-details {{
            font-size: 12px;
            color: #666;
            max-width: 300px;
            word-wrap: break-word;
        }}
    </style>
</head>
<body>
    <h1 style="color: #b57614;">🔍 Configuration Anomaly Analysis</h1>
    <p><strong>Last Updated:</strong> <span id="last-updated">{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</span></p>
    
    <!-- Summary Cards -->
    <div class="summary-grid">
        <div class="summary-card card-total">
            <div class="card-value">{len(devices_data)}</div>
            <div class="card-label">Total Devices</div>
        </div>
        <div class="summary-card card-excellent">
            <div class="card-value">{len([d for d in devices_data if d['status'] == 'CLEAN'])}</div>
            <div class="card-label">Clean Configs</div>
        </div>
        <div class="summary-card card-warning">
            <div class="card-value">{medium_severity_total}</div>
            <div class="card-label">Warnings</div>
        </div>
        <div class="summary-card card-critical">
            <div class="card-value">{high_severity_total}</div>
            <div class="card-label">Critical Issues</div>
        </div>
    </div>
    
    <!-- Devices Table -->
    <table id="analysis-table" class="analysis-table">
        <thead>
            <tr>
                <th>Device</th>
                <th>Status</th>
                <th>Total Issues</th>
                <th>Critical</th>
                <th>Warnings</th>
                <th>Sample Issues</th>
            </tr>
        </thead>
        <tbody>"""
    
    for device in devices_data:
        status_class = f"status-{device['status'].lower()}"
        sample_issues = device['issues'][:3]  # Show first 3 issues
        issues_text = "; ".join([f"Line {issue['line']}: {issue['error']}" for issue in sample_issues])
        if len(device['issues']) > 3:
            issues_text += f" ... (+{len(device['issues']) - 3} more)"
        
        html_content += f"""
            <tr>
                <td><a href="/configs/{device['name']}-nv-set.txt" target="_blank" class="device-link">{device['name']}</a></td>
                <td><span class="{status_class}">{device['status']}</span></td>
                <td>{device['total_issues']}</td>
                <td>{device['high_severity']}</td>
                <td>{device['medium_severity']}</td>
                <td class="issue-details">{issues_text if issues_text else 'No issues detected'}</td>
            </tr>"""
    
    html_content += """
        </tbody>
    </table>
    
    <div style="margin-top: 40px; padding: 20px; background: #f8f9fa; border-radius: 8px;">
        <h3>🔍 Detection Capabilities</h3>
        <ul>
            <li><strong>Subnet Mask Errors:</strong> /31 vs /3, invalid ranges</li>
            <li><strong>VLAN Issues:</strong> Invalid IDs (>4094), common typos (1000 vs 10000)</li>
            <li><strong>Interface Speed:</strong> Suspicious speeds, extra zeros</li>
            <li><strong>BGP ASN Errors:</strong> Invalid ranges, common typos</li>
            <li><strong>Pattern Detection:</strong> Suspicious configurations</li>
        </ul>
        
        <h3>💡 Common Fixes</h3>
        <ul>
            <li><strong>/3 → /30:</strong> Point-to-point links</li>
            <li><strong>10000 → 1000:</strong> VLAN ID typos (extra zero)</li>
            <li><strong>100000 → 10000:</strong> Interface speed (100G vs 10G)</li>
            <li><strong>650000 → 65000:</strong> Private ASN range</li>
        </ul>
    </div>
    
    <script>
        // Auto-refresh every 5 minutes
        setTimeout(function() {{
            location.reload();
        }}, 300000);
        
        // Add sorting capability
        document.querySelectorAll('.analysis-table th').forEach(header => {{
            header.style.cursor = 'pointer';
            header.addEventListener('click', function() {{
                // Simple sorting implementation would go here
            }});
        }});
    </script>
</body>
</html>"""
    
    # Write HTML file
    try:
        with open(output_file, 'w') as f:
            f.write(html_content)
        print(f"✅ Config analysis HTML generated: {output_file}")
        return True
    except Exception as e:
        print(f"❌ Error generating HTML: {e}")
        return False

def main():
    """Main function"""
    generate_config_analysis_html()

if __name__ == "__main__":
    main()
