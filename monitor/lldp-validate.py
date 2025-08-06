#!/usr/bin/python3
"""
lldp-validate.py - LLDP Validation for LLDPq
==========================================

PURPOSE:
    Validates LLDP data and generates a report.
    Maintains backward compatibility with existing scripts.

Copyright (c) 2024 LLDPq Project
Licensed under MIT License - see LICENSE file for details
"""
import os
import re
import subprocess
import yaml

def load_topology_config(config_path="topology_config.yaml"):
    """Load topology configuration to determine which script to use"""
    if os.path.exists(config_path):
        try:
            with open(config_path, 'r') as f:
                config = yaml.safe_load(f)
                return config.get('topology', 'minimal')  # Default to minimal
        except Exception as e:
            print(f"Warning: Could not read topology config: {e}")
            return 'minimal'
    else:
        print("Warning: topology_config.yaml not found, using minimal topology")
        return 'minimal'

def get_topology_script_name(config_path="topology_config.yaml"):
    """Determine which topology script to use based on config"""
    topology_type = load_topology_config(config_path)
    
    if topology_type == 'full':
        script_name = "generate_topology_full.py"
        print("Using full topology generation")
    else:
        script_name = "generate_topology.py"
        print("Using minimal topology generation")
    
    return script_name

def parse_lldp_output(filename):
    neighbors = []
    port_status = {}
    
    with open(filename, 'r') as file:
        content = file.read()
        
        # Parse LLDP neighbors (existing logic)
        interfaces = re.split(r'-------------------------------------------------------------------------------', content)[1:-1]
        for interface in interfaces:
            data = {}
            interface_match = re.search(r'Interface:\s+(\S+)', interface)
            sys_name_match = re.search(r'SysName:\s+([^\n]+)', interface)
            if "Cumulus" in interface:
                port_id_match = re.search(r'PortID:\s+ifname\s+(\S+)', interface)
            else:
                # For HGX devices, extract just the interface name from "Interface 4 as enp157s0f0np0"
                port_descr_match = re.search(r'PortDescr:\s+(.+)', interface)
                if port_descr_match:
                    port_descr = port_descr_match.group(1).strip()
                    # Extract interface name from patterns like "Interface 4 as enp157s0f0np0"
                    interface_name_match = re.search(r'as\s+(\S+)', port_descr)
                    if interface_name_match:
                        port_id_match = type('Match', (), {'group': lambda self, n: interface_name_match.group(1)})()
                    else:
                        port_id_match = port_descr_match
                else:
                    port_id_match = None
            if interface_match and sys_name_match and port_id_match:
                sys_name = sys_name_match.group(1).strip()
                if not "Cumulus" in interface:
                    sys_name = sys_name.split(".cm.cluster")[0]
                data['interface'] = interface_match.group(1).strip(',')
                data['sys_name'] = sys_name
                data['port_id'] = port_id_match.group(1).strip()
                neighbors.append(data)
            elif interface_match and port_id_match:
                data['interface'] = interface_match.group(1).strip(',')
                data['sys_name'] = "Unknown"
                data['port_id'] = port_id_match.group(1).strip()
                neighbors.append(data)
        
        # Parse port status (NEW) - Use findall to get all sections and take the LAST one
        port_status_matches = re.findall(r'===PORT_STATUS_START===(.*?)===PORT_STATUS_END===', content, re.DOTALL)
        if port_status_matches:
            # Take the LAST section (most recent port status)
            port_status_section = port_status_matches[-1]
            port_status_lines = port_status_section.strip().split('\n')
            for line in port_status_lines:
                line = line.strip()
                if line:  # Remove colon check since format is "swp1s0  UP"
                    parts = line.split()
                    if len(parts) >= 2:
                        port_name = parts[0]  # Port name (no colon to remove)
                        status = parts[-1]  # Take the last word (UP/DOWN)
                        port_status[port_name] = status
    
    return neighbors, port_status

def get_device_neighbors(lldp_dir):
    device_neighbors = {}
    device_port_status = {}
    files_in_order = sorted(os.listdir(lldp_dir))
    for filename in files_in_order:
        if filename.endswith("_lldp_result.ini"):
            device_name = filename.replace("_lldp_result.ini", "")
            filepath = os.path.join(lldp_dir, filename)
            neighbors, port_status = parse_lldp_output(filepath)
            device_neighbors[device_name] = neighbors
            device_port_status[device_name] = port_status
    return device_neighbors, device_port_status, files_in_order

def check_connections(topology_file, device_neighbors, device_port_status):
    with open(topology_file, 'r') as file:
        expected_connections = file.readlines()
    results = {}
    valid_devices = device_neighbors.keys()
    for device, neighbors in device_neighbors.items():
        port_status = device_port_status.get(device, {})
        device_results = []
        for connection in expected_connections:
            if '--' not in connection:
                continue
            connection = re.sub(r'\[.*?\]', '', connection)
            left_port, right_port = connection.strip().split('--')
            left, left_interface = left_port.replace('"', '').strip().split(':')
            right, right_interface = right_port.replace('"', '').strip().split(':')
            if left != device and right != device:
                continue
            expected_interface = left_interface if left == device else right_interface
            expected_neighbor_sys_name = right if left == device else left
            expected_neighbor_port = right_interface if left == device else left_interface
            active_neighbor = next((n for n in neighbors if n['interface'] == expected_interface), None)
            active_neighbor_sys_name = 'None'
            active_neighbor_port = 'None'
            if not active_neighbor:
                status = 'No-Info'
            else:
                if expected_neighbor_sys_name == 'None':
                    status = 'Fail'
                    active_neighbor_sys_name = active_neighbor['sys_name']
                    active_neighbor_port = active_neighbor['port_id']
                elif active_neighbor['sys_name'] == expected_neighbor_sys_name and active_neighbor['port_id'] == expected_neighbor_port:
                    status = 'Pass'
                    active_neighbor_sys_name = active_neighbor['sys_name']
                    active_neighbor_port = active_neighbor['port_id']
                else:
                    status = 'Fail'
                    active_neighbor_sys_name = active_neighbor['sys_name']
                    active_neighbor_port = active_neighbor['port_id']
            if expected_interface == 'eth0' or active_neighbor_port == 'eth0':
                continue
            # Get port status for this interface
            interface_port_status = port_status.get(expected_interface, 'N/A')
            device_results.append({
                'Port': expected_interface,
                'interface': expected_interface,
                'Status': status,
                'Exp-Nbr': expected_neighbor_sys_name,
                'Exp-Nbr-Port': expected_neighbor_port,
                'Act-Nbr': active_neighbor_sys_name,
                'Act-Nbr-Port': active_neighbor_port,
                'Port-Status': interface_port_status
            })
        for neighbor in neighbors:
            if neighbor['interface'] == 'eth0' or neighbor['port_id'] == 'eth0':
                continue
            if neighbor['sys_name'] not in valid_devices:
                continue
            if not any(n['interface'] == neighbor['interface'] for n in device_results):
                # Get port status for this interface
                interface_port_status = port_status.get(neighbor['interface'], 'N/A')
                device_results.append({
                    'Port': neighbor['interface'],
                    'interface': neighbor['interface'],
                    'Status': 'Fail',
                    'Exp-Nbr': 'None',
                    'Exp-Nbr-Port': 'None',
                    'Act-Nbr': neighbor['sys_name'],
                    'Act-Nbr-Port': neighbor['port_id'],
                    'Port-Status': interface_port_status
                })
        results[device] = device_results
    return results

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    lldp_results_folder = os.path.join(script_dir, "lldp-results")
    topology_file = os.path.join(script_dir, "topology.dot")
    device_neighbors, device_port_status, files_in_order = get_device_neighbors(lldp_results_folder)
    results = check_connections(topology_file, device_neighbors, device_port_status)
    output_file_path = os.path.join(lldp_results_folder, "lldp_results.ini")
    date_str = subprocess.getoutput("date '+%Y-%m-%d %H-%M-%S'")
    script_name = get_topology_script_name()
    generate_topology_script = os.path.join(os.path.dirname(__file__), script_name)
    with open(output_file_path, 'w') as output_file:
        output_file.write(f"Created on {date_str}\n\n")
        for filename in files_in_order:
            if filename.endswith("_lldp_result.ini"):
                device = filename.replace("_lldp_result.ini", "")
                if device in results:
                    total_length = 96
                    device_length = len(device)
                    equal_count = (total_length - device_length - 2) // 2
                    equal_str = "=" * equal_count
                    header = f"{equal_str} {device} {equal_str}"
                    if len(header) < total_length:
                        header += "=" * (total_length - len(header))
                    output_file.write(header + "\n\n")
                    output_file.write("--------------------------------------------------------------------------------------------------------------------------\n")
                    output_file.write(f"{'Port':<10} {'Status':<10} {'Exp-Nbr':<28} {'Exp-Nbr-Port':<16} {'Act-Nbr':<28} {'Act-Nbr-Port':<12} {'Port-Status'}\n")
                    output_file.write("--------------------------------------------------------------------------------------------------------------------------\n")
                    for res in results[device]:
                        output_file.write(f"{res['Port']:<10} {res['Status']:<10} {res['Exp-Nbr']:<28} {res['Exp-Nbr-Port']:<16} {res['Act-Nbr']:<28} {res['Act-Nbr-Port']:<12} {res['Port-Status']}\n")
                    output_file.write("\n\n")
    subprocess.run(["sudo", "python3", generate_topology_script], check=True)
    # DEBUG: Keep raw files for debugging
    # for filename in files_in_order:
    #     if filename.endswith("_lldp_result.ini"):
    #         os.remove(os.path.join(lldp_results_folder, filename))
