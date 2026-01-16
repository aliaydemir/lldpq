#!/usr/bin/env python3
"""
parse_devices.py - YAML to Bash Array Converter for LLDPq
========================================================

PURPOSE:
    Converts devices.yaml to bash associative array format.
    Maintains backward compatibility with existing scripts.

USAGE:
    python3 parse_devices.py

OUTPUT:
    Bash associative array declaration that can be sourced.
    Format: declare -A devices=(["IP"]="username hostname")

REQUIREMENTS:
    - Python 3.6+ with PyYAML (pip install pyyaml)
    - devices.yaml in same directory

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""

import yaml
import sys
import os

def load_devices_yaml(yaml_file="devices.yaml"):
    """Load and parse devices.yaml configuration"""
    try:
        with open(yaml_file, 'r') as f:
            config = yaml.safe_load(f)
        return config
    except FileNotFoundError:
        print(f"ERROR: {yaml_file} not found", file=sys.stderr)
        sys.exit(1)
    except yaml.YAMLError as e:
        print(f"ERROR: Invalid YAML in {yaml_file}: {e}", file=sys.stderr)
        sys.exit(1)

def generate_bash_array(config):
    """Convert YAML config to bash array compatible with bash 3.2+"""
    
    # Get default username
    defaults = config.get('defaults', {})
    default_username = defaults.get('username', 'cumulus')
    
    devices = config.get('devices', {})
    if not devices:
        print("ERROR: No devices found in configuration", file=sys.stderr)
        sys.exit(1)
    
    # Generate bash array entries and separate IP list
    device_ips = []
    device_entries = []
    
    for ip, device_config in devices.items():
        if isinstance(device_config, str):
            # Simple format: IP: hostname
            hostname = device_config
            username = default_username
        elif isinstance(device_config, dict):
            # Extended format: IP: {hostname: x, username: y}
            hostname = device_config.get('hostname', 'unknown')
            username = device_config.get('username', default_username)
        else:
            print(f"WARNING: Invalid device config for {ip}, skipping", file=sys.stderr)
            continue
        
        device_ips.append(f'"{ip}"')
        device_entries.append(f'"{username} {hostname}"')
    
    # Generate bash arrays (compatible with older bash)
    bash_output = f"""# Device IPs
device_ips=({' '.join(device_ips)})

# Device info (username hostname)
device_info=({' '.join(device_entries)})

# Create associative array compatible function
declare -A devices
for i in "${{!device_ips[@]}}"; do
    devices["${{device_ips[i]}}"]="${{device_info[i]}}"
done"""
    
    return bash_output

def main():
    """Main function"""
    # Get script directory for relative paths
    script_dir = os.path.dirname(os.path.abspath(__file__))
    yaml_file = os.path.join(script_dir, "devices.yaml")
    
    # Load configuration
    config = load_devices_yaml(yaml_file)
    
    # Generate and print bash array
    bash_array = generate_bash_array(config)
    print(bash_array)

if __name__ == "__main__":
    main()