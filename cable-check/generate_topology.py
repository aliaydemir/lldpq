import os
import re
import json

def parse_assets_file(assets_file_path):
    device_info = {}
    try:
        with open(assets_file_path, 'r') as file:
            lines = file.readlines()
            for line in lines[1:]:
                parts = line.split()
                if len(parts) >= 6:
                    device_name = parts[0]
                    device_info[device_name] = {
                        "primaryIP": parts[1],
                        "mac": parts[2],
                        "serial_number": parts[3],
                        "model": parts[4],
                        "version": parts[5]
                    }
    except FileNotFoundError:
        pass
    return device_info

def parse_hosts_file(hosts_file_path):
    host_names = set()
    try:
        with open(hosts_file_path, 'r') as file:
            for line in file:
                line = line.strip()
                if line and not line.startswith('[') and not line.startswith('#'):
                    host_names.add(line)
    except FileNotFoundError:
        pass
    return host_names

def get_lldp_field(section, field_name, regex_pattern=None):
    if regex_pattern:
        match = re.search(regex_pattern, section, re.DOTALL | re.IGNORECASE)
    else:
        match = re.search(rf'{field_name}:\s*(.+?)(?:\n\s*\S+\s*:|\Z)', section, re.DOTALL | re.IGNORECASE)

    return match.group(1).strip() if match else None

def normalize_interface_name(iface_name, known_device_names):
    best_match_device_name = None
    for device_name in known_device_names:
        if iface_name.startswith(f"{device_name}-"):
            if best_match_device_name is None or len(device_name) > len(best_match_device_name):
                best_match_device_name = device_name

    if best_match_device_name:
        normalized_name = iface_name[len(f"{best_match_device_name}-"):]
        return normalized_name
    return iface_name


def parse_lldp_results(directory, device_info, hosts_only_devices):
    topology_data = {
        "links": [],
        "nodes": []
    }

    device_nodes = {}
    device_id = 0

    all_lldp_links_found = set()

    known_device_names_for_normalization = set(device_info.keys())

    for device_name, info in device_info.items():
        if "OOB-MGMT" in device_name:
            continue

        lower = device_name.lower()

        if "border" in lower:
            layer_sort_preference = 1
            dev_icon = "switch"
        elif "superspine" in lower:
            layer_sort_preference = 2
            dev_icon = "switch"
        elif "spine" in lower:
            layer_sort_preference = 3
            dev_icon = "switch"
        elif "leaf" in lower:
            layer_sort_preference = 4
            dev_icon = "switch"
        elif "oobswitch" in lower:
            layer_sort_preference = 5
            dev_icon = "switch"
        else:
            layer_sort_preference = 9
            dev_icon = "server"

        device_node = {
            "icon": dev_icon,
            "id": device_id,
            "layerSortPreference": layer_sort_preference,
            "name": device_name,
            "primaryIP": info.get("primaryIP", "N/A"),
            "model": info.get("model", "N/A"),
            "serial_number": info.get("serial_number", "N/A"),
            "version": info.get("version", "N/A")
        }
        topology_data["nodes"].append(device_node)
        device_nodes[device_name] = device_id
        device_id += 1

    link_id = 0
    reachable_devices = set()

    for filename in os.listdir(directory):
        filepath = os.path.join(directory, filename)

        if not filename.endswith("_lldp_result.ini"):
            continue

        device_name_from_lldp = filename.split("_lldp_result.ini")[0]
        reachable_devices.add(device_name_from_lldp)
        try:
            with open(filepath, 'r') as file:
                data = file.read()
        except FileNotFoundError:
            continue

        interface_sections = re.split(r'-------------------------------------------------------------------------------', data)
        interface_sections = [s.strip() for s in interface_sections if s.strip()]

        for section in interface_sections:
            interface_name = get_lldp_field(section, "Interface", r'Interface:\s*(\S+),')
            neighbor_device = get_lldp_field(section, "SysName", r'SysName:\s*(\S+)')

            raw_port_id_ifname = get_lldp_field(section, "PortID", r'PortID:\s+ifname\s+(\S+)')
            raw_port_descr = get_lldp_field(section, "PortDescr", r'PortDescr:\s*(\S+)')

            if not interface_name or not neighbor_device:
                continue

            tgt_ifname = ""
            if raw_port_id_ifname:
                tgt_ifname = normalize_interface_name(raw_port_id_ifname, known_device_names_for_normalization)
            elif raw_port_descr:
                tgt_ifname = normalize_interface_name(raw_port_descr, known_device_names_for_normalization)

            if not tgt_ifname:
                continue

            if interface_name.lower() == "eth0" or tgt_ifname.lower() == "eth0":
                continue

            if device_name_from_lldp in device_nodes and neighbor_device in device_nodes:
                link = {
                    "id": link_id,
                    "source": device_nodes[device_name_from_lldp],
                    "srcDevice": device_name_from_lldp,
                    "srcIfName": interface_name,
                    "target": device_nodes[neighbor_device],
                    "tgtDevice": neighbor_device,
                    "tgtIfName": tgt_ifname,
                    "is_missing": "no"
                }
                topology_data["links"].append(link)
                link_id += 1

                all_lldp_links_found.add((device_name_from_lldp, interface_name, neighbor_device, tgt_ifname))
                all_lldp_links_found.add((neighbor_device, tgt_ifname, device_name_from_lldp, interface_name))
            else:
                pass


    for node in topology_data["nodes"]:
        if node["name"] in device_info and \
           node["name"] not in hosts_only_devices and \
           node["name"] not in reachable_devices:
            node["icon"] = "unknown"

    return topology_data, device_nodes, link_id, all_lldp_links_found

def parse_topology_dot_file(dot_file_path):
    defined_links = set()
    try:
        with open(dot_file_path, 'r') as file:
            for line in file:
                line = line.strip()
                if line.startswith('"') and '--' in line:
                    parts = re.findall(r'"(.*?)"', line)
                    if len(parts) == 4:
                        src_device, src_ifname, tgt_device, tgt_ifname = parts
                        defined_links.add((src_device, src_ifname, tgt_device, tgt_ifname))
    except FileNotFoundError:
        pass
    return defined_links

def generate_topology_file(output_filename, directory, assets_file_path, hosts_file_path, dot_file_path):
    device_info = parse_assets_file(assets_file_path)
    host_names = parse_hosts_file(hosts_file_path)

    hosts_only_devices = host_names - set(device_info.keys())

    for host in host_names:
        if host not in device_info:
            device_info[host] = {
                "primaryIP": "N/A",
                "mac": "N/A",
                "serial_number": "N/A",
                "model": "N/A",
                "version": "N/A"
            }

    topology_data, device_nodes, current_link_id, all_lldp_links_found = parse_lldp_results(directory, device_info, hosts_only_devices)

    defined_links = parse_topology_dot_file(dot_file_path)

    for link in topology_data["links"]:
        src_device = link["srcDevice"]
        tgt_device = link["tgtDevice"]
        src_ifname = link["srcIfName"]
        tgt_ifname = link["tgtIfName"]

        forward_link_tuple = (src_device, src_ifname, tgt_device, tgt_ifname)
        reverse_link_tuple = (tgt_device, tgt_ifname, src_device, src_ifname)

        if forward_link_tuple not in defined_links and reverse_link_tuple not in defined_links:
            link["is_missing"] = "fail"

    final_links_to_add = []

    for defined_link in defined_links:
        src_device, src_ifname, tgt_device, tgt_ifname = defined_link
        forward_link_tuple = (src_device, src_ifname, tgt_device, tgt_ifname)
        reverse_link_tuple = (tgt_device, tgt_ifname, src_device, src_ifname)

        if forward_link_tuple not in all_lldp_links_found and reverse_link_tuple not in all_lldp_links_found:

            if src_device in device_nodes and tgt_device in device_nodes:
                link = {
                    "id": current_link_id,
                    "source": device_nodes[src_device],
                    "srcDevice": src_device,
                    "srcIfName": src_ifname,
                    "target": device_nodes[tgt_device],
                    "tgtDevice": tgt_device,
                    "tgtIfName": tgt_ifname,
                    "is_missing": "yes"
                }
                final_links_to_add.append(link)
                current_link_id += 1
            else:
                pass

    topology_data["links"].extend(final_links_to_add)

    unique_links_filtered = []
    seen_links_for_dedup = set()

    for link in topology_data["links"]:
        src_device = link["srcDevice"]
        tgt_device = link["tgtDevice"]
        src_ifname = link["srcIfName"]
        tgt_ifname = link["tgtIfName"]

        current_link_tuple = (src_device, src_ifname, tgt_device, tgt_ifname)
        reverse_link_tuple = (tgt_device, tgt_ifname, src_device, src_ifname)

        if current_link_tuple not in seen_links_for_dedup and reverse_link_tuple not in seen_links_for_dedup:
            unique_links_filtered.append(link)
            seen_links_for_dedup.add(current_link_tuple)
        else:
            pass

    topology_data["links"] = unique_links_filtered

    final_nodes_set = set(device_info.keys())

    for link in topology_data["links"]:
        final_nodes_set.add(link["srcDevice"])
        final_nodes_set.add(link["tgtDevice"])

    topology_data["nodes"] = [node for node in topology_data["nodes"] if node["name"] in final_nodes_set]

    topology_data["nodes"].sort(key=lambda x: x["name"])

    id_map = {node["id"]: new_id for new_id, node in enumerate(topology_data["nodes"])}

    for node in topology_data["nodes"]:
        node["id"] = id_map[node["id"]]

    for link in topology_data["links"]:
        link["source"] = id_map[link["source"]]
        link["target"] = id_map[link["target"]]

    try:
        with open(output_filename, "w") as file:
            file.write("var topologyData = ")
            json.dump(topology_data, file, indent=4)
            file.write(";")
    except IOError as e:
        pass

if __name__ == "__main__":
    lldp_results_directory = "lldp-results"
    assets_file_path = "assets.ini"
    hosts_file_path = "hosts.ini"
    dot_file_path = "topology.dot"
    output_file = "/var/www/html/topology/topology.js"

    if not os.path.isdir(lldp_results_directory):
        exit(1)

    generate_topology_file(output_file, lldp_results_directory, assets_file_path, hosts_file_path, dot_file_path)



