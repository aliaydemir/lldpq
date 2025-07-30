#!/usr/bin/python3

import os
import re
import subprocess

def parse_lldp_output(filename):
    neighbors = []
    with open(filename, 'r') as file:
        content = file.read()
        interfaces = re.split(r'-------------------------------------------------------------------------------', content)[1:-1]
        for interface in interfaces:
            data = {}
            interface_match = re.search(r'Interface:\s+(\S+)', interface)
            sys_name_match = re.search(r'SysName:\s+([^\n]+)', interface)
            if "Cumulus" in interface:
                port_id_match = re.search(r'PortID:\s+ifname\s+(\S+)', interface)
            else:
                port_id_match = re.search(r'PortDescr:\s+(.+)', interface)
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
    return neighbors

def get_device_neighbors(lldp_dir):
    device_neighbors = {}
    files_in_order = sorted(os.listdir(lldp_dir))
    for filename in files_in_order:
        if filename.endswith("_lldp_result.ini"):
            device_name = filename.replace("_lldp_result.ini", "")
            filepath = os.path.join(lldp_dir, filename)
            device_neighbors[device_name] = parse_lldp_output(filepath)
    return device_neighbors, files_in_order

def check_connections(topology_file, device_neighbors):
    with open(topology_file, 'r') as file:
        expected_connections = file.readlines()
    results = {}
    valid_devices = device_neighbors.keys()
    for device, neighbors in device_neighbors.items():
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
            device_results.append({
                'Port': expected_interface,
                'interface': expected_interface,
                'Status': status,
                'Exp-Nbr': expected_neighbor_sys_name,
                'Exp-Nbr-Port': expected_neighbor_port,
                'Act-Nbr': active_neighbor_sys_name,
                'Act-Nbr-Port': active_neighbor_port
            })
        for neighbor in neighbors:
            if neighbor['interface'] == 'eth0' or neighbor['port_id'] == 'eth0':
                continue
            if neighbor['sys_name'] not in valid_devices:
                continue
            if not any(n['interface'] == neighbor['interface'] for n in device_results):
                device_results.append({
                    'Port': neighbor['interface'],
                    'interface': neighbor['interface'],
                    'Status': 'Fail',
                    'Exp-Nbr': 'None',
                    'Exp-Nbr-Port': 'None',
                    'Act-Nbr': neighbor['sys_name'],
                    'Act-Nbr-Port': neighbor['port_id']
                })
        results[device] = device_results
    return results

if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    lldp_results_folder = os.path.join(script_dir, "lldp-results")
    topology_file = os.path.join(script_dir, "topology.dot")
    device_neighbors, files_in_order = get_device_neighbors(lldp_results_folder)
    results = check_connections(topology_file, device_neighbors)
    output_file_path = os.path.join(lldp_results_folder, "lldp_results.ini")
    date_str = subprocess.getoutput("date '+%Y-%m-%d %H-%M'")
    generate_topology_script = os.path.join(os.path.dirname(__file__), "generate_topology.py")
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
                    output_file.write("-----------------------------------------------------------------------------------------------------------------\n")
                    output_file.write(f"{'Port':<10} {'Status':<10} {'Exp-Nbr':<28} {'Exp-Nbr-Port':<16} {'Act-Nbr':<28} {'Act-Nbr-Port'}\n")
                    output_file.write("-----------------------------------------------------------------------------------------------------------------\n")
                    for res in results[device]:
                        output_file.write(f"{res['Port']:<10} {res['Status']:<10} {res['Exp-Nbr']:<28} {res['Exp-Nbr-Port']:<16} {res['Act-Nbr']:<28} {res['Act-Nbr-Port']}\n")
                    output_file.write("\n\n")
    subprocess.run(["sudo", "python3", generate_topology_script], check=True)
    for filename in files_in_order:
        if filename.endswith("_lldp_result.ini"):
            os.remove(os.path.join(lldp_results_folder, filename))
