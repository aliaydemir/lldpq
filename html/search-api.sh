#!/bin/bash
# Search API - MAC/ARP Table Backend
# Backend for search.html

# Load config
if [[ -f /etc/lldpq.conf ]]; then
    source /etc/lldpq.conf
fi

# Set defaults (use $HOME for portable fallback)
LLDPQ_DIR="${LLDPQ_DIR:-$HOME/lldpq}"
LLDPQ_USER="${LLDPQ_USER:-$(whoami)}"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Export for Python scripts
export LLDPQ_DIR LLDPQ_USER

# Output JSON header
echo "Content-Type: application/json"
echo ""

# Parse query string
parse_query() {
    local query="$QUERY_STRING"
    ACTION=$(echo "$query" | grep -oP 'action=\K[^&]*' | head -1)
    DEVICE=$(echo "$query" | grep -oP 'device=\K[^&]*' | head -1 | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
    SEARCH=$(echo "$query" | grep -oP 'search=\K[^&]*' | head -1 | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
}

# List available devices from devices.yaml
list_devices() {
    python3 << 'PYTHON'
import json
import yaml
import os

lldpq_dir = os.environ.get('LLDPQ_DIR', os.path.expanduser('~/lldpq'))
devices_file = f"{lldpq_dir}/devices.yaml"

# Fallback paths
if not os.path.exists(devices_file):
    devices_file = os.path.expanduser("~/lldpq/devices.yaml")

try:
    with open(devices_file, 'r') as f:
        devices_data = yaml.safe_load(f)
    
    devices = []
    
    # Get devices from 'devices' section
    devices_section = devices_data.get('devices', {})
    if not devices_section:
        # Fallback: treat entire file as devices (old format)
        devices_section = devices_data
    
    for ip, info in devices_section.items():
        # Skip non-device entries
        if ip in ['defaults', 'endpoint_hosts']:
            continue
        
        if isinstance(info, dict):
            hostname = info.get('hostname', ip)
        else:
            # Format: hostname as string
            hostname = str(info) if info else ip
        
        devices.append({"ip": ip, "hostname": hostname})
    
    # Sort by hostname
    devices.sort(key=lambda x: x['hostname'])
    
    print(json.dumps({"success": True, "devices": devices}))
except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
PYTHON
}

# Get MAC table from a device
get_mac_table() {
    local device="$1"
    local search="$2"
    
    if [[ -z "$device" ]]; then
        echo '{"success": false, "error": "Device not specified"}'
        return
    fi
    
    # SSH to device using LLDPQ user's SSH keys
    local ssh_output
    ssh_output=$(sudo -u "$LLDPQ_USER" timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$device" '
        # Get bridge FDB (MAC table)
        /usr/sbin/bridge fdb show 2>/dev/null | grep -v "permanent\|self" | head -500
    ' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo '{"success": false, "error": "Failed to connect to device"}'
        return
    fi
    
    # Parse output with Python
    python3 << PYTHON
import json
import sys

output = '''$ssh_output'''
search = '''$search'''.lower()

entries = []
for line in output.strip().split('\n'):
    if not line.strip():
        continue
    
    parts = line.split()
    if len(parts) >= 3:
        mac = parts[0]
        # Find interface (usually after 'dev')
        iface = ""
        vlan = ""
        for i, p in enumerate(parts):
            if p == "dev" and i + 1 < len(parts):
                iface = parts[i + 1]
            if p == "vlan" and i + 1 < len(parts):
                vlan = parts[i + 1]
        
        entry = {
            "mac": mac,
            "interface": iface,
            "vlan": vlan,
            "type": "dynamic"
        }
        
        # Apply search filter
        if search:
            if search in mac.lower() or search in iface.lower() or search in vlan.lower():
                entries.append(entry)
        else:
            entries.append(entry)

print(json.dumps({"success": True, "entries": entries[:200], "total": len(entries)}))
PYTHON
}

# Get ARP table from a device
get_arp_table() {
    local device="$1"
    local search="$2"
    
    if [[ -z "$device" ]]; then
        echo '{"success": false, "error": "Device not specified"}'
        return
    fi
    
    # SSH to device - get ARP entries and interface VRF mappings
    local ssh_output
    ssh_output=$(sudo -u "$LLDPQ_USER" timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$device" '
        # Get ARP table (single query, no duplicates)
        /usr/sbin/ip neigh show 2>/dev/null | head -300
        echo "---VRF_MAP---"
        # Get VRF list
        /usr/sbin/ip vrf list 2>/dev/null
        echo "---IFACE_VRF---"
        # Get interface to VRF mappings
        for i in /sys/class/net/*/master; do
            n=$(echo $i | cut -d/ -f5)
            m=$(readlink $i 2>/dev/null | xargs basename 2>/dev/null)
            [ -n "$m" ] && echo "$n $m"
        done
    ' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo '{"success": false, "error": "Failed to connect to device"}'
        return
    fi
    
    # Parse output with Python
    python3 << PYTHON
import json
import re

output = '''$ssh_output'''
search = '''$search'''.lower()

# Parse sections
sections = output.split("---VRF_MAP---")
arp_lines = sections[0].strip().split('\n') if len(sections) > 0 else []

vrf_list = set()
iface_to_vrf = {}

if len(sections) > 1:
    rest = sections[1].split("---IFACE_VRF---")
    # Parse VRF list
    for line in rest[0].strip().split('\n'):
        if line and not line.startswith("Name") and not line.startswith("-"):
            parts = line.split()
            if parts:
                vrf_list.add(parts[0])
    # Parse interface to VRF mappings
    if len(rest) > 1:
        for line in rest[1].strip().split('\n'):
            parts = line.split()
            if len(parts) >= 2:
                iface, master = parts[0], parts[1]
                if master in vrf_list:
                    iface_to_vrf[iface] = master

entries = []
for line in arp_lines:
    if not line.strip():
        continue
    
    parts = line.split()
    if len(parts) >= 4:
        ip_addr = parts[0]
        mac = ""
        iface = ""
        state = ""
        
        for i, p in enumerate(parts):
            if p == "dev" and i + 1 < len(parts):
                iface = parts[i + 1]
            if p == "lladdr" and i + 1 < len(parts):
                mac = parts[i + 1]
        
        if parts[-1] in ["REACHABLE", "STALE", "DELAY", "PROBE", "FAILED", "PERMANENT"]:
            state = parts[-1]
        
        if mac:
            # Skip VRR interfaces
            if iface and re.search(r'-v\d+$', iface):
                continue
            vrf = iface_to_vrf.get(iface, "default")
            entry = {
                "ip": ip_addr,
                "mac": mac,
                "interface": iface,
                "vrf": vrf,
                "state": state
            }
            
            if search:
                if (search in ip_addr.lower() or search in mac.lower() or 
                    search in iface.lower() or search in vrf.lower()):
                    entries.append(entry)
            else:
                entries.append(entry)

print(json.dumps({"success": True, "entries": entries[:500], "total": len(entries)}))
PYTHON
}

# Get all MAC/ARP from all devices (parallel)
get_all_tables() {
    local table_type="$1"  # mac or arp
    local search="$2"
    
    python3 << PYTHON
import json
import yaml
import subprocess
import concurrent.futures
import os
import re

lldpq_dir = os.environ.get('LLDPQ_DIR', os.path.expanduser('~/lldpq'))
devices_file = f"{lldpq_dir}/devices.yaml"

if not os.path.exists(devices_file):
    devices_file = os.path.expanduser("~/lldpq/devices.yaml")

table_type = "$table_type"
search = "$search".lower()

def get_device_table(device_info):
    ip, info = device_info
    if isinstance(info, dict):
        hostname = info.get('hostname', ip)
    else:
        hostname = str(info) if info else ip
    
    try:
        lldpq_user = os.environ.get('LLDPQ_USER', os.environ.get('USER', 'root'))
        if table_type == "mac":
            cmd = f"sudo -u {lldpq_user} timeout 15 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes {ip} '/usr/sbin/bridge fdb show 2>/dev/null | grep -v permanent | head -200'"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=20)
        else:  # arp - get ARP with interface VRF mappings
            remote_script = '/usr/sbin/ip neigh show 2>/dev/null | head -200; echo ---VRF_MAP---; /usr/sbin/ip vrf list 2>/dev/null; echo ---IFACE_VRF---; for i in /sys/class/net/vlan*/master /sys/class/net/eth*/master; do n=\$(basename \$(dirname \$i)); m=\$(readlink \$i | xargs basename); [ -n "\$m" ] && echo \$n \$m; done 2>/dev/null'
            cmd_parts = [
                "sudo", "-u", lldpq_user, "timeout", "15", "ssh",
                "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", ip,
                remote_script
            ]
            result = subprocess.run(cmd_parts, capture_output=True, text=True, timeout=20)
        
        entries = []
        
        if table_type == "mac":
            for line in result.stdout.strip().split('\n'):
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) >= 3:
                    mac = parts[0]
                    iface = ""
                    vlan = ""
                    for i, p in enumerate(parts):
                        if p == "dev" and i + 1 < len(parts):
                            iface = parts[i + 1]
                        if p == "vlan" and i + 1 < len(parts):
                            vlan = parts[i + 1]
                    
                    entry = {"device": hostname, "mac": mac, "interface": iface, "vlan": vlan}
                    if not search or search in mac.lower() or search in iface.lower() or search in hostname.lower():
                        entries.append(entry)
        
        elif table_type == "arp":
            # Parse ARP with VRF info from interface masters
            output = result.stdout.strip()
            sections = output.split("---VRF_MAP---")
            arp_lines = sections[0].strip().split('\n') if sections else []
            
            vrf_list = set()
            iface_to_vrf = {}
            
            if len(sections) > 1:
                rest = sections[1].split("---IFACE_VRF---")
                for line in rest[0].strip().split('\n'):
                    if line and not line.startswith("Name") and not line.startswith("-"):
                        parts = line.split()
                        if parts:
                            vrf_list.add(parts[0])
                if len(rest) > 1:
                    for line in rest[1].strip().split('\n'):
                        parts = line.split()
                        # Check if second part is a VRF (skip bridge masters like br_default)
                        if len(parts) >= 2 and parts[1] in vrf_list:
                            iface_to_vrf[parts[0]] = parts[1]
            
            for line in arp_lines:
                if not line.strip():
                    continue
                parts = line.split()
                if len(parts) < 4:
                    continue
                    
                ip_addr = parts[0]
                mac = ""
                iface = ""
                for i, p in enumerate(parts):
                    if p == "dev" and i + 1 < len(parts):
                        iface = parts[i + 1]
                    if p == "lladdr" and i + 1 < len(parts):
                        mac = parts[i + 1]
                
                if mac:
                    if iface and re.search(r'-v\d+$', iface):
                        continue
                    vrf = iface_to_vrf.get(iface, "default")
                    entry = {"device": hostname, "ip": ip_addr, "mac": mac, "interface": iface, "vrf": vrf}
                    if not search or search in ip_addr.lower() or search in mac.lower() or search in hostname.lower():
                        entries.append(entry)
        
        return entries
    except Exception as e:
        return []

try:
    with open(devices_file, 'r') as f:
        devices_data = yaml.safe_load(f)
    
    # Get devices from 'devices' section
    devices_section = devices_data.get('devices', {})
    if not devices_section:
        devices_section = devices_data
    
    # Filter out non-device entries
    device_list = [(ip, info) for ip, info in devices_section.items() 
                   if ip not in ['defaults', 'endpoint_hosts']]
    
    all_entries = []
    
    # Parallel execution - increase workers for faster search
    with concurrent.futures.ThreadPoolExecutor(max_workers=50) as executor:
        results = executor.map(get_device_table, device_list)
        for entries in results:
            all_entries.extend(entries)
    
    print(json.dumps({"success": True, "entries": all_entries[:500], "total": len(all_entries)}))

except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
PYTHON
}

# Get VXLAN VTEPs from a device
get_vtep_table() {
    local device="$1"
    local search="$2"
    
    if [[ -z "$device" ]]; then
        echo '{"success": false, "error": "Device not specified"}'
        return
    fi
    
    local ssh_output
    ssh_output=$(sudo -u "$LLDPQ_USER" timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$device" '
        /usr/sbin/bridge fdb show 2>/dev/null | grep "dst " | head -1000
    ' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo '{"success": false, "error": "Failed to connect to device"}'
        return
    fi
    
    python3 << PYTHON
import json

output = '''$ssh_output'''
search = '''$search'''.lower()

entries = []
vtep_summary = {}  # VTEP IP -> {vni_count, mac_count}

for line in output.strip().split('\n'):
    if not line.strip():
        continue
    
    parts = line.split()
    mac = parts[0] if parts else ""
    vtep_ip = ""
    vni = ""
    iface = ""
    state = ""
    
    for i, p in enumerate(parts):
        if p == "dst" and i + 1 < len(parts):
            vtep_ip = parts[i + 1]
        # Handle both "vni" and "src_vni" formats
        if p in ("vni", "src_vni") and i + 1 < len(parts):
            vni = parts[i + 1]
        if p == "dev" and i + 1 < len(parts):
            iface = parts[i + 1]
    
    # Determine state from flags in the line
    if "permanent" in line:
        state = "permanent"
    elif "offload" in line:
        state = "offload"
    elif "extern_learn" in line:
        state = "learned"
    else:
        state = "dynamic"
    
    # Determine if it's a BUM entry (00:00:00:00:00:00)
    entry_type = "BUM" if mac == "00:00:00:00:00:00" else "MAC"
    
    if vtep_ip:
        # Track summary
        if vtep_ip not in vtep_summary:
            vtep_summary[vtep_ip] = {"vnis": set(), "macs": 0}
        vtep_summary[vtep_ip]["vnis"].add(vni)
        vtep_summary[vtep_ip]["macs"] += 1
        
        entry = {
            "vtep": vtep_ip, 
            "vni": vni, 
            "mac": mac, 
            "interface": iface,
            "state": state,
            "type": entry_type
        }
        if not search or search in vtep_ip.lower() or search in vni.lower() or search in mac.lower():
            entries.append(entry)

# Sort by VTEP IP, then VNI, then MAC
def ip_sort_key(ip):
    try:
        return tuple(int(x) for x in ip.split('.'))
    except:
        return (255, 255, 255, 255)

entries.sort(key=lambda x: (ip_sort_key(x['vtep']), x['vni'], x['mac']))

# Build summary for header
summary = {
    "unique_vteps": len(vtep_summary),
    "total_entries": len(entries)
}

print(json.dumps({"success": True, "entries": entries[:500], "total": len(entries), "summary": summary}))
PYTHON
}

# Get Route table from a device
get_route_table() {
    local device="$1"
    local search="$2"
    
    if [[ -z "$device" ]]; then
        echo '{"success": false, "error": "Device not specified"}'
        return
    fi
    
    local ssh_output
    ssh_output=$(sudo -u "$LLDPQ_USER" timeout 45 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$device" '
        sudo vtysh -c "show ip route vrf all" 2>/dev/null | head -5000
    ' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo '{"success": false, "error": "Failed to connect to device"}'
        return
    fi
    
    python3 << PYTHON
import json
import re

output = '''$ssh_output'''
search = '''$search'''.lower()

# Parse vtysh output
# Format: VRF xxx:
# B>* 10.128.128.1/32 [20/0] via fe80::..., swp33s0, weight 1, 01w6d20h
# Route codes: B=BGP, C=connected, S=static, K=kernel, O=OSPF, etc.

vrf_data = {}  # {vrf_name: [routes]}
current_vrf = "default"
current_prefix = None
current_entry = None

route_codes = {
    'B': 'BGP', 'C': 'connected', 'S': 'static', 'K': 'kernel',
    'O': 'OSPF', 'R': 'RIP', 'I': 'IS-IS', 'E': 'EIGRP',
    'L': 'local', 'A': 'Babel', 'D': 'SHARP'
}

last_entry = None

for line in output.strip().split('\n'):
    line = line.rstrip()
    if not line:
        continue
    
    # Skip header lines (Codes:, etc.)
    if line.startswith('Codes:') or line.startswith('       '):
        if 'VRF' not in line:
            continue
    
    # VRF header: "VRF xxx:" or "VRF default:"
    vrf_match = re.match(r'^VRF\s+(\S+):', line)
    if vrf_match:
        current_vrf = vrf_match.group(1)
        if current_vrf not in vrf_data:
            vrf_data[current_vrf] = []
        last_entry = None
        continue
    
    # ECMP continuation line: starts with spaces and * (must check before route match)
    if line.startswith('  ') and '*' in line[:10] and last_entry:
        last_entry['ecmp'] += 1
        continue
    
    # New route line: starts with route code (B, C, S, K, L, etc.)
    # Format with metric: B>* 10.128.128.1/32 [20/0] via fe80::..., swp33s0, weight 1, 01w6d20h
    # Format without metric: C>* 192.168.58.0/24 is directly connected, eth0, 01w6d20h
    
    # First try: route with [AD/metric]
    route_match = re.match(r'^([BCSKORIEALT])([>*\s]+)\s*(\d+\.\d+\.\d+\.\d+(?:/\d+)?)\s+\[(\d+)/(\d+)\]', line)
    
    # Second try: route without [AD/metric] (connected, local)
    if not route_match:
        route_match_simple = re.match(r'^([BCSKORIEALT])([>*\s]+)\s*(\d+\.\d+\.\d+\.\d+(?:/\d+)?)\s+', line)
        if route_match_simple:
            code = route_match_simple.group(1)
            prefix = route_match_simple.group(3)
            ad = "0"
            metric = "0"
        else:
            continue
    else:
        code = route_match.group(1)
        prefix = route_match.group(3)
        ad = route_match.group(4)  # Administrative distance
        metric = route_match.group(5)
    
    # Add /32 if no mask
    if '/' not in prefix:
        prefix = prefix + '/32'
    
    # Extract next hop and interface
    nexthop = ""
    iface = ""
    age = ""
    
    # Parse "via X, interface, ..." or "is directly connected, interface"
    via_match = re.search(r'via\s+(\S+),\s*(\S+)', line)
    if via_match:
        nh = via_match.group(1)
        # Skip IPv6 link-local as nexthop, use interface instead
        if nh.startswith('fe80::'):
            nexthop = "link-local"
        else:
            nexthop = nh.rstrip(',')
        iface = via_match.group(2).rstrip(',')
    
    connected_match = re.search(r'directly connected,\s*(\S+)', line)
    if connected_match:
        nexthop = "connected"
        iface = connected_match.group(1).rstrip(',')
    
    # Handle unreachable routes
    if 'unreachable' in line:
        nexthop = "unreachable"
    
    # Extract age if present (e.g., 01w6d20h)
    age_match = re.search(r',\s*(\d+[wdhms]\d*[wdhms]*\d*[wdhms]*)$', line)
    if age_match:
        age = age_match.group(1)
    
    protocol = route_codes.get(code, code)
    
    # Skip kernel routes (unreachable, blackhole, etc.) - they are confusing
    if protocol == 'kernel':
        continue
    
    last_entry = {
        "prefix": prefix,
        "nexthop": nexthop or "-",
        "interface": iface or "-",
        "protocol": protocol,
        "ad": ad,
        "metric": metric,
        "age": age or "-",
        "ecmp": 1  # ECMP path count
    }
    
    if current_vrf not in vrf_data:
        vrf_data[current_vrf] = []
    vrf_data[current_vrf].append(last_entry)

# Build flat entries list for filtering and sorting
entries = []
for vrf, routes in vrf_data.items():
    for r in routes:
        r['vrf'] = vrf
        entries.append(r)

# Apply search filter
if search:
    filtered = []
    for e in entries:
        # Search in prefix, nexthop, interface, protocol
        if (search in e['prefix'].lower() or 
            search in e['nexthop'].lower() or 
            search in e['interface'].lower() or
            search in e['protocol'].lower()):
            filtered.append(e)
        # VRF exact match or starts with
        elif e['vrf'].lower() == search or e['vrf'].lower().startswith(search):
            filtered.append(e)
    entries = filtered

# Sort: default VRF first, then alphabetical, mgmt last
def prefix_to_sortable(prefix):
    if prefix == "0.0.0.0/0":
        return (0, 0, 0, 0, 0)
    try:
        if '/' in prefix:
            ip_part, mask = prefix.rsplit('/', 1)
            mask = int(mask)
        else:
            ip_part = prefix
            mask = 32
        octets = tuple(int(o) for o in ip_part.split('.'))
        return (1,) + octets + (mask,)
    except:
        return (2, 255, 255, 255, 255, 32)

def vrf_sort_key(e):
    vrf = e['vrf']
    prefix_key = prefix_to_sortable(e['prefix'])
    if vrf == 'default':
        return (0, vrf, prefix_key)
    elif vrf == 'mgmt':
        return (2, vrf, prefix_key)
    else:
        return (1, vrf, prefix_key)

entries.sort(key=vrf_sort_key)

# Group by VRF for UI display
vrf_tables = {}
for e in entries:
    vrf = e['vrf']
    if vrf not in vrf_tables:
        vrf_tables[vrf] = []
    vrf_tables[vrf].append(e)

# Order VRF list: default first, mgmt last
vrf_order = []
if 'default' in vrf_tables:
    vrf_order.append('default')
for v in sorted(vrf_tables.keys()):
    if v not in ('default', 'mgmt'):
        vrf_order.append(v)
if 'mgmt' in vrf_tables:
    vrf_order.append('mgmt')

print(json.dumps({
    "success": True, 
    "vrf_tables": {v: vrf_tables[v][:100] for v in vrf_order},
    "vrf_order": vrf_order,
    "total": len(entries)
}))
PYTHON
}

# Get bond members for an interface
get_bond_members() {
    local device="$1"
    local bond="$2"
    
    if [[ -z "$device" ]] || [[ -z "$bond" ]]; then
        echo '{"success": false, "error": "Device and bond not specified"}'
        return
    fi
    
    local ssh_output
    ssh_output=$(sudo -u "$LLDPQ_USER" timeout 10 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "$device" "
        cat /sys/class/net/$bond/bonding/slaves 2>/dev/null || echo ''
    " 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo '{"success": false, "error": "Failed to get bond members"}'
        return
    fi
    
    # Convert space-separated list to JSON array
    local members=$(echo "$ssh_output" | tr ' ' '\n' | grep -v '^$' | sed 's/^/"/;s/$/"/' | tr '\n' ',' | sed 's/,$//')
    echo "{\"success\": true, \"members\": [$members]}"
}

# Get LLDP neighbors from a device
get_lldp_neighbors() {
    local device="$1"
    local search="$2"
    
    if [[ -z "$device" ]]; then
        echo '{"success": false, "error": "Device not specified"}'
        return
    fi
    
    local ssh_output
    ssh_output=$(sudo -u "$LLDPQ_USER" timeout 30 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$device" '
        sudo lldpctl -f json 2>/dev/null || echo "{}"
    ' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        echo '{"success": false, "error": "Failed to connect to device"}'
        return
    fi
    
    python3 << PYTHON
import json

output = '''$ssh_output'''
search = '''$search'''.lower()

entries = []

try:
    data = json.loads(output)
    lldp_data = data.get('lldp', [])
    
    # Handle array format from lldpctl
    if isinstance(lldp_data, list):
        for item in lldp_data:
            interfaces = item.get('interface', [])
            if isinstance(interfaces, list):
                for iface in interfaces:
                    iface_name = iface.get('name', '')
                    chassis_list = iface.get('chassis', [])
                    port_list = iface.get('port', [])
                    
                    neighbor = ""
                    mgmt_ip = ""
                    remote_port = ""
                    
                    # Parse chassis info
                    if chassis_list and isinstance(chassis_list, list):
                        chassis = chassis_list[0]
                        name_list = chassis.get('name', [])
                        if name_list and isinstance(name_list, list):
                            neighbor = name_list[0].get('value', '')
                        
                        mgmt_list = chassis.get('mgmt-ip', [])
                        if mgmt_list and isinstance(mgmt_list, list):
                            mgmt_ip = mgmt_list[0].get('value', '')
                    
                    # Parse port info
                    if port_list and isinstance(port_list, list):
                        port = port_list[0]
                        id_list = port.get('id', [])
                        if id_list and isinstance(id_list, list):
                            remote_port = id_list[0].get('value', '')
                        if not remote_port:
                            descr_list = port.get('descr', [])
                            if descr_list and isinstance(descr_list, list):
                                remote_port = descr_list[0].get('value', '')
                    
                    if neighbor:
                        entry = {
                            "local_port": iface_name,
                            "neighbor": neighbor,
                            "remote_port": remote_port,
                            "mgmt_ip": mgmt_ip
                        }
                        
                        if not search or search in neighbor.lower() or search in iface_name.lower() or search in str(mgmt_ip).lower():
                            entries.append(entry)
    
    # Sort by local port
    entries.sort(key=lambda x: x['local_port'])
    
except Exception as e:
    pass

print(json.dumps({"success": True, "entries": entries, "total": len(entries)}))
PYTHON
}

# Get fabric scan status
get_scan_status() {
    python3 << 'PYTHON'
import json
import os
from datetime import datetime

lldpq_dir = os.environ.get('LLDPQ_DIR', os.path.expanduser('~/lldpq'))
summary_file = f"{lldpq_dir}/monitor-results/fabric-tables/summary.json"

try:
    if os.path.exists(summary_file):
        with open(summary_file) as f:
            data = json.load(f)
        
        timestamp = data.get('timestamp', '')
        device_count = len(data.get('devices', []))
        
        # Calculate age
        if timestamp:
            scan_time = datetime.fromisoformat(timestamp)
            age_seconds = (datetime.now() - scan_time).total_seconds()
            age_minutes = int(age_seconds / 60)
        else:
            age_minutes = -1
        
        print(json.dumps({
            "success": True,
            "timestamp": timestamp,
            "device_count": device_count,
            "age_minutes": age_minutes
        }))
    else:
        print(json.dumps({
            "success": True,
            "timestamp": None,
            "device_count": 0,
            "age_minutes": -1,
            "message": "No scan data available"
        }))
except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
PYTHON
}

# Trigger fabric scan
run_fabric_scan() {
    local lldpq_dir="${LLDPQ_DIR:-$HOME/lldpq}"
    local scan_script="$lldpq_dir/fabric-scan.sh"
    
    if [[ ! -f "$scan_script" ]]; then
        echo '{"success": false, "error": "fabric-scan.sh not found"}'
        return
    fi
    
    # Check if already running
    if pgrep -f "fabric-scan.sh" > /dev/null; then
        echo '{"success": false, "error": "Scan already in progress"}'
        return
    fi
    
    # Run scan in background
    cd "$lldpq_dir"
    sudo -u "$LLDPQ_USER" nohup bash "$scan_script" > /tmp/fabric-scan.log 2>&1 &
    
    echo '{"success": true, "message": "Fabric scan started"}'
}

# Search cached routes (VRF-grouped structure)
search_cached_routes() {
    local search_ip="$1"
    
    python3 << PYTHON
import json
import os
import struct
import socket

lldpq_dir = os.environ.get('LLDPQ_DIR', os.path.expanduser('~/lldpq'))
tables_dir = f"{lldpq_dir}/monitor-results/fabric-tables"
search_ip = "$search_ip"

def ip_to_int(ip):
    try:
        return struct.unpack("!I", socket.inet_aton(ip))[0]
    except:
        return 0

def is_ip_in_prefix(ip, prefix):
    try:
        if '/' not in prefix:
            return ip == prefix
        network, mask = prefix.split('/')
        mask = int(mask)
        ip_int = ip_to_int(ip)
        net_int = ip_to_int(network)
        mask_bits = (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF if mask > 0 else 0
        return (ip_int & mask_bits) == (net_int & mask_bits)
    except:
        return False

def get_prefix_len(prefix):
    try:
        if '/' in prefix:
            return int(prefix.split('/')[1])
        return 32
    except:
        return 0

results = {}  # vrf -> [routes with best match]
all_vrfs = set()  # Collect all unique VRFs
device_vrfs = {}  # Track which VRFs each device has

try:
    if not os.path.exists(tables_dir):
        print(json.dumps({"success": False, "error": "No cached data. Run Fabric Scan first."}))
        exit()
    
    # First pass: collect all VRFs and find best matches
    for filename in os.listdir(tables_dir):
        if not filename.endswith('.json') or filename == 'summary.json':
            continue
        
        hostname = filename.replace('.json', '')
        filepath = os.path.join(tables_dir, filename)
        
        try:
            with open(filepath) as f:
                data = json.load(f)
            
            routes = data.get('routes', {})
            device_vrfs[hostname] = set()
            
            for vrf, vrf_routes in routes.items():
                # Skip invalid VRF names
                if vrf.startswith('-') or not vrf.strip():
                    continue
                    
                all_vrfs.add(vrf)
                device_vrfs[hostname].add(vrf)
                
                best_match = None
                best_prefix_len = -1
                
                for route in vrf_routes:
                    prefix = route.get('prefix', '')
                    if is_ip_in_prefix(search_ip, prefix):
                        prefix_len = get_prefix_len(prefix)
                        if prefix_len > best_prefix_len:
                            best_prefix_len = prefix_len
                            best_match = route.copy()
                            best_match['device'] = hostname
                            best_match['vrf'] = vrf
                
                if best_match:
                    if vrf not in results:
                        results[vrf] = []
                    results[vrf].append(best_match)
        except Exception as e:
            continue
    
    # Second pass: add "No Route" for VRFs without any match
    for vrf in all_vrfs:
        if vrf not in results:
            # Count devices that have this VRF
            devices_with_vrf = [d for d, vrfs in device_vrfs.items() if vrf in vrfs]
            results[vrf] = [{
                'device': 'all',
                'vrf': vrf,
                'prefix': 'No Route',
                'nexthop': '-',
                'interface': '-',
                'protocol': '-',
                'no_route': True,
                'device_count': len(devices_with_vrf)
            }]
    
    print(json.dumps({
        "success": True,
        "vrf_routes": results,
        "cached": True
    }))

except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
PYTHON
}

# Search cached fabric tables (fast)
search_cached_tables() {
    local table_type="$1"
    local search="$2"
    
    python3 << PYTHON
import json
import os
import re

lldpq_dir = os.environ.get('LLDPQ_DIR', os.path.expanduser('~/lldpq'))
tables_dir = f"{lldpq_dir}/monitor-results/fabric-tables"
table_type = "$table_type"
search = "$search".lower()

entries = []

try:
    if not os.path.exists(tables_dir):
        print(json.dumps({"success": False, "error": "No cached data. Run Fabric Scan first."}))
        exit()
    
    for filename in os.listdir(tables_dir):
        if not filename.endswith('.json') or filename == 'summary.json':
            continue
        
        hostname = filename.replace('.json', '')
        filepath = os.path.join(tables_dir, filename)
        
        try:
            with open(filepath) as f:
                data = json.load(f)
            
            table_data = data.get(table_type, [])
            
            for entry in table_data:
                entry['device'] = hostname
                
                # Filter by search term
                if search:
                    match = False
                    for val in entry.values():
                        if search in str(val).lower():
                            match = True
                            break
                    if not match:
                        continue
                
                # Skip VRR interfaces for ARP
                if table_type == 'arp':
                    iface = entry.get('interface', '')
                    if re.search(r'-v\d+$', iface):
                        continue
                
                entries.append(entry)
        except:
            continue
    
    print(json.dumps({
        "success": True,
        "entries": entries[:500],
        "total": len(entries),
        "cached": True
    }))

except Exception as e:
    print(json.dumps({"success": False, "error": str(e)}))
PYTHON
}

# Main routing
parse_query

case "$ACTION" in
    "list-devices")
        list_devices
        ;;
    "get-mac")
        get_mac_table "$DEVICE" "$SEARCH"
        ;;
    "get-arp")
        get_arp_table "$DEVICE" "$SEARCH"
        ;;
    "get-all-mac")
        get_all_tables "mac" "$SEARCH"
        ;;
    "get-all-arp")
        get_all_tables "arp" "$SEARCH"
        ;;
    "get-vtep")
        get_vtep_table "$DEVICE" "$SEARCH"
        ;;
    "get-route")
        get_route_table "$DEVICE" "$SEARCH"
        ;;
    "get-lldp")
        get_lldp_neighbors "$DEVICE" "$SEARCH"
        ;;
    "get-bond-members")
        BOND=$(echo "$QUERY_STRING" | grep -oE 'bond=[^&]+' | cut -d= -f2 | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))")
        get_bond_members "$DEVICE" "$BOND"
        ;;
    "scan-status")
        get_scan_status
        ;;
    "run-scan")
        run_fabric_scan
        ;;
    "search-cached-mac")
        search_cached_tables "mac" "$SEARCH"
        ;;
    "search-cached-arp")
        search_cached_tables "arp" "$SEARCH"
        ;;
    "search-cached-vtep")
        search_cached_tables "vtep" "$SEARCH"
        ;;
    "search-cached-lldp")
        search_cached_tables "lldp" "$SEARCH"
        ;;
    "search-cached-routes")
        search_cached_routes "$SEARCH"
        ;;
    *)
        echo '{"success": false, "error": "Invalid action"}'
        ;;
esac
