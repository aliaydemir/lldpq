#!/usr/bin/env python3
"""
Config Anomaly Detector for LLDPq
==================================

Detects common network configuration errors and typos.
Focuses on human errors like /31 vs /3, VLAN typos, etc.

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import json
import re
import os
from datetime import datetime
from collections import defaultdict, Counter

class NetworkConfigAnalyzer:
    def __init__(self):
        # Common human error patterns
        self.common_typos = {
            'subnet_masks': {
                '/3': '/30',     # Point-to-point link
                '/1': '/31',     # Point-to-point link  
                '/6': '/16',     # Network prefix
                '/8': '/28',     # Small subnet
                '/2': '/32',     # Host route
                '/0': '/30',     # Default route confusion
                '/33': '/30',    # Invalid subnet
                '/40': '/24'     # Typo in common /24
            },
            'vlan_ids': {
                '10000': '1000',   # Extra zero
                '5000': '500',     # Extra zero
                '20000': '2000',   # Extra zero
                '40000': '4000',   # Beyond 4096 limit
                '50000': '500',    # Way too big
                '99999': '999'     # Impossible VLAN
            },
            'interface_speeds': {
                '100000': '10000',   # 100G vs 10G confusion
                '1000000': '100000', # Extra zeros
                '400000': '40000',   # 400G vs 40G
                '250000': '25000'    # 250G vs 25G
            },
            'bgp_asn': {
                '650000': '65000',     # Private ASN range error
                '4294967295': '65535', # 32-bit vs 16-bit ASN
                '650001': '65001',     # Private ASN typo
                '1000000': '10000'     # Extra zeros
            }
        }
        
        # Suspicious patterns (regex)
        self.suspicious_patterns = {
            'ip_addresses': [
                r'192\.168\.1\.256',  # Invalid IP (256)
                r'10\.0\.0\.256',     # Invalid IP 
                r'172\.16\.256',      # Invalid subnet
                r'255\.255\.255\.256' # Invalid subnet mask
            ],
            'interface_names': [
                r'swp\d{3,}',        # Too many digits (swp1000 suspicious)
                r'Ethernet\d/\d{3,}', # Suspicious interface numbers
                r'swp[0-9]+[a-z]{2,}' # Too many letters after numbers
            ],
            'descriptions': [
                r'test.*test',        # Multiple "test" words
                r'temp.*temp',        # Multiple "temp" words  
                r'\b\w{1,2}\b.*\b\w{1,2}\b', # Too many short words
            ]
        }
        
        # Configuration consistency rules
        self.consistency_rules = [
            'trunk_native_vlan_mismatch',
            'speed_duplex_mismatch', 
            'vlan_range_overlap',
            'ip_subnet_mismatch',
            'bgp_neighbor_asn_mismatch'
        ]
        
        self.anomalies = []
        
    def analyze_config_text(self, config_text, device_name):
        """Analyze raw configuration text for anomalies"""
        self.anomalies = []
        self.device_name = device_name
        
        lines = config_text.split('\n')
        
        for line_num, line in enumerate(lines, 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
                
            # Check different types of anomalies
            self._check_subnet_mask_errors(line, line_num)
            self._check_vlan_errors(line, line_num)
            self._check_interface_speed_errors(line, line_num)
            self._check_bgp_asn_errors(line, line_num)
            self._check_suspicious_patterns(line, line_num)
            
        return self.anomalies
    
    def _check_subnet_mask_errors(self, line, line_num):
        """Check for common subnet mask typos"""
        # Match patterns like "ip address 192.168.1.1/3"
        subnet_pattern = r'ip\s+address\s+[\d.]+(/\d+)'
        matches = re.findall(subnet_pattern, line)
        
        for subnet in matches:
            if subnet in self.common_typos['subnet_masks']:
                suggested = self.common_typos['subnet_masks'][subnet]
                self.anomalies.append({
                    'type': 'subnet_mask_typo',
                    'severity': 'HIGH',
                    'line': line_num,
                    'content': line.strip(),
                    'error': f'Suspicious subnet mask {subnet}',
                    'suggestion': f'Did you mean {suggested}?',
                    'pattern': 'common_typo'
                })
    
    def _check_vlan_errors(self, line, line_num):
        """Check for VLAN ID errors"""
        # Match VLAN configurations
        vlan_patterns = [
            r'vlan\s+(\d+)',
            r'switchport\s+access\s+vlan\s+(\d+)',
            r'native\s+vlan\s+(\d+)'
        ]
        
        for pattern in vlan_patterns:
            matches = re.findall(pattern, line)
            for vlan_id in matches:
                # Check for impossible VLAN IDs
                vlan_num = int(vlan_id)
                if vlan_num > 4094:
                    self.anomalies.append({
                        'type': 'invalid_vlan',
                        'severity': 'HIGH', 
                        'line': line_num,
                        'content': line.strip(),
                        'error': f'VLAN {vlan_id} exceeds maximum (4094)',
                        'suggestion': f'Check VLAN ID - maximum is 4094',
                        'pattern': 'range_violation'
                    })
                
                # Check for common typos
                if vlan_id in self.common_typos['vlan_ids']:
                    suggested = self.common_typos['vlan_ids'][vlan_id]
                    self.anomalies.append({
                        'type': 'vlan_typo',
                        'severity': 'MEDIUM',
                        'line': line_num, 
                        'content': line.strip(),
                        'error': f'Suspicious VLAN ID {vlan_id}',
                        'suggestion': f'Did you mean VLAN {suggested}?',
                        'pattern': 'common_typo'
                    })
    
    def _check_interface_speed_errors(self, line, line_num):
        """Check for interface speed configuration errors"""
        speed_pattern = r'speed\s+(\d+)'
        matches = re.findall(speed_pattern, line)
        
        for speed in matches:
            if speed in self.common_typos['interface_speeds']:
                suggested = self.common_typos['interface_speeds'][speed] 
                self.anomalies.append({
                    'type': 'interface_speed_typo',
                    'severity': 'MEDIUM',
                    'line': line_num,
                    'content': line.strip(), 
                    'error': f'Suspicious interface speed {speed}Mbps',
                    'suggestion': f'Did you mean {suggested}Mbps?',
                    'pattern': 'common_typo'
                })
    
    def _check_bgp_asn_errors(self, line, line_num):
        """Check for BGP ASN errors"""
        asn_patterns = [
            r'router\s+bgp\s+(\d+)',
            r'neighbor\s+[\d.]+\s+remote-as\s+(\d+)'
        ]
        
        for pattern in asn_patterns:
            matches = re.findall(pattern, line)
            for asn in matches:
                asn_num = int(asn)
                
                # Check for invalid ASN ranges
                if asn_num > 4294967295:
                    self.anomalies.append({
                        'type': 'invalid_asn',
                        'severity': 'HIGH',
                        'line': line_num,
                        'content': line.strip(),
                        'error': f'ASN {asn} exceeds maximum (4294967295)',
                        'suggestion': 'Check ASN - maximum is 4294967295',
                        'pattern': 'range_violation'
                    })
                
                # Check for common typos
                if asn in self.common_typos['bgp_asn']:
                    suggested = self.common_typos['bgp_asn'][asn]
                    self.anomalies.append({
                        'type': 'bgp_asn_typo',
                        'severity': 'MEDIUM',
                        'line': line_num,
                        'content': line.strip(),
                        'error': f'Suspicious BGP ASN {asn}',
                        'suggestion': f'Did you mean ASN {suggested}?',
                        'pattern': 'common_typo'
                    })
    
    def _check_suspicious_patterns(self, line, line_num):
        """Check for suspicious regex patterns"""
        for category, patterns in self.suspicious_patterns.items():
            for pattern in patterns:
                if re.search(pattern, line):
                    self.anomalies.append({
                        'type': f'suspicious_{category}',
                        'severity': 'MEDIUM',
                        'line': line_num,
                        'content': line.strip(),
                        'error': f'Suspicious {category} pattern detected',
                        'suggestion': f'Review {category} configuration',
                        'pattern': 'regex_match'
                    })
    
    def generate_report(self, output_file=None):
        """Generate anomaly detection report"""
        if not self.anomalies:
            return "✅ No configuration anomalies detected!"
        
        # Group by severity
        high_severity = [a for a in self.anomalies if a['severity'] == 'HIGH']
        medium_severity = [a for a in self.anomalies if a['severity'] == 'MEDIUM']
        
        report = []
        report.append(f"🔍 Configuration Anomaly Report for {self.device_name}")
        report.append("=" * 60)
        report.append(f"📊 Total Issues: {len(self.anomalies)}")
        report.append(f"🔴 High Severity: {len(high_severity)}")
        report.append(f"🟡 Medium Severity: {len(medium_severity)}")
        report.append("")
        
        # High severity issues first
        if high_severity:
            report.append("🔴 HIGH SEVERITY ISSUES:")
            report.append("-" * 30)
            for anomaly in high_severity:
                report.append(f"Line {anomaly['line']}: {anomaly['error']}")
                report.append(f"   Config: {anomaly['content']}")
                report.append(f"   💡 {anomaly['suggestion']}")
                report.append("")
        
        # Medium severity issues
        if medium_severity:
            report.append("🟡 MEDIUM SEVERITY ISSUES:")
            report.append("-" * 30)
            for anomaly in medium_severity:
                report.append(f"Line {anomaly['line']}: {anomaly['error']}")
                report.append(f"   Config: {anomaly['content']}")
                report.append(f"   💡 {anomaly['suggestion']}")
                report.append("")
        
        report_text = "\n".join(report)
        
        if output_file:
            with open(output_file, 'w') as f:
                f.write(report_text)
        
        return report_text

def main():
    """Main function with command line argument support"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Network Configuration Anomaly Detector')
    parser.add_argument('--config-file', required=True, help='Configuration file to analyze')
    parser.add_argument('--device-name', required=True, help='Device name for reporting')
    parser.add_argument('--output', help='Output file for report (optional)')
    parser.add_argument('--format', choices=['text', 'json'], default='text', help='Output format')
    
    # Test mode for development
    parser.add_argument('--test', action='store_true', help='Run with sample configuration')
    
    args = parser.parse_args()
    
    if args.test:
        # Test with sample configuration
        sample_config = """
        interface swp1
            ip address 192.168.1.1/3
            speed 100000
            description Test Link
        
        vlan 10000
        
        router bgp 650000
            neighbor 192.168.1.2 remote-as 4294967295
        """
        
        analyzer = NetworkConfigAnalyzer()
        anomalies = analyzer.analyze_config_text(sample_config, "test-device")
        print(analyzer.generate_report())
        return
    
    # Production mode - analyze actual config file
    try:
        with open(args.config_file, 'r') as f:
            config_content = f.read()
    except FileNotFoundError:
        print(f"❌ Error: Configuration file not found: {args.config_file}")
        return
    except Exception as e:
        print(f"❌ Error reading configuration file: {e}")
        return
    
    analyzer = NetworkConfigAnalyzer()
    anomalies = analyzer.analyze_config_text(config_content, args.device_name)
    
    if args.format == 'json':
        import json
        result = {
            'device': args.device_name,
            'timestamp': datetime.now().isoformat(),
            'total_anomalies': len(anomalies),
            'high_severity': len([a for a in anomalies if a['severity'] == 'HIGH']),
            'medium_severity': len([a for a in anomalies if a['severity'] == 'MEDIUM']),
            'anomalies': anomalies
        }
        output = json.dumps(result, indent=2)
    else:
        output = analyzer.generate_report()
    
    if args.output:
        try:
            with open(args.output, 'w') as f:
                f.write(output)
            print(f"✅ Report saved to: {args.output}")
        except Exception as e:
            print(f"❌ Error saving report: {e}")
    else:
        print(output)

if __name__ == "__main__":
    main()
