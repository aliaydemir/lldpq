#!/usr/bin/env bash
# Fabric Table Scanner - Collects MAC/ARP/Route tables from all devices
# Results stored in monitor-results/fabric-tables/ for fast search

# Load config
source /etc/lldpq.conf 2>/dev/null || true
LLDPQ_DIR="${LLDPQ_DIR:-$HOME/lldpq}"
cd "$LLDPQ_DIR"

# Configuration
MAX_PARALLEL=100
SSH_TIMEOUT=10
OUTPUT_DIR="monitor-results/fabric-tables"
DEVICES_FILE="devices.yaml"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Get device list from devices.yaml
get_devices() {
    python3 << 'PYEOF'
import yaml
import sys

try:
    with open('devices.yaml', 'r') as f:
        data = yaml.safe_load(f)
    
    devices = data.get('devices', data)
    for ip, info in devices.items():
        if ip in ['defaults', 'endpoint_hosts']:
            continue
        if isinstance(info, dict):
            hostname = info.get('hostname', ip)
        elif isinstance(info, str):
            hostname = info  # Format: IP: hostname
        else:
            hostname = ip
        print(f"{ip}|{hostname}")
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

# Check if host is reachable
is_reachable() {
    local ip="$1"
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1
}

# Collect data from a single device
collect_device_data() {
    local ip="$1"
    local hostname="$2"
    local output_file="$OUTPUT_DIR/${hostname}.json"
    
    # Skip unreachable hosts
    if ! is_reachable "$ip"; then
        echo "SKIP"
        return
    fi
    
    # Collect raw data via SSH
    local raw_data
    raw_data=$(timeout $SSH_TIMEOUT ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes "$ip" '
        echo "===ARP==="
        /usr/sbin/ip neigh show 2>/dev/null | head -300
        echo "===VRFMAP==="
        /usr/sbin/ip vrf list 2>/dev/null
        echo "===IFACEVRF==="
        for i in /sys/class/net/vlan*/master /sys/class/net/eth*/master; do
            n=$(basename $(dirname $i) 2>/dev/null)
            m=$(readlink $i 2>/dev/null | xargs basename 2>/dev/null)
            [ -n "$m" ] && echo "$n $m"
        done 2>/dev/null
        echo "===MAC==="
        /usr/sbin/bridge fdb show 2>/dev/null | head -500
        echo "===VTEP==="
        /usr/sbin/bridge fdb show 2>/dev/null | grep "dst " | head -100
        echo "===BOND==="
        for b in /sys/class/net/*/bonding/slaves; do
            [ -f "$b" ] && echo "$(basename $(dirname $(dirname $b))):$(cat $b)"
        done 2>/dev/null
        echo "===ROUTES==="
        echo "VRF:default"
        /usr/sbin/ip route show 2>/dev/null | head -300
        for vrf in $(/usr/sbin/ip vrf list 2>/dev/null | awk "NR>1 {print \$1}"); do
            echo "VRF:$vrf"
            /usr/sbin/ip route show vrf "$vrf" 2>/dev/null | head -300
        done
        echo "===END==="
    ' 2>/dev/null)
    
    if [ -z "$raw_data" ]; then
        echo "FAIL"
        return
    fi
    
    # Parse with Python
    python3 << PYEOF
import json
import re

raw = '''$raw_data'''

# Parse sections
sections = {}
current = None
for line in raw.split('\n'):
    if line.startswith('===') and line.endswith('==='):
        current = line.strip('=')
        sections[current] = []
    elif current:
        sections[current].append(line)

# Build VRF mapping
vrf_list = set()
iface_vrf = {}
for line in sections.get('VRFMAP', []):
    if line and not line.startswith('Name') and not line.startswith('-'):
        parts = line.split()
        if parts:
            vrf_list.add(parts[0])

for line in sections.get('IFACEVRF', []):
    parts = line.split()
    if len(parts) >= 2 and parts[1] in vrf_list:
        iface_vrf[parts[0]] = parts[1]

# Parse ARP
arp_entries = []
for line in sections.get('ARP', []):
    if not line.strip():
        continue
    parts = line.split()
    if len(parts) < 4:
        continue
    ip_addr = parts[0]
    iface = mac = state = ''
    for i, p in enumerate(parts):
        if p == 'dev' and i+1 < len(parts): iface = parts[i+1]
        if p == 'lladdr' and i+1 < len(parts): mac = parts[i+1]
    if parts[-1] in ['REACHABLE', 'STALE', 'DELAY', 'PROBE', 'FAILED', 'PERMANENT']:
        state = parts[-1]
    if mac and not re.search(r'-v\d+$', iface):
        vrf = iface_vrf.get(iface, 'default')
        arp_entries.append({'ip': ip_addr, 'mac': mac, 'interface': iface, 'vrf': vrf, 'state': state})

# Parse MAC
mac_entries = []
for line in sections.get('MAC', []):
    if not line.strip():
        continue
    # Skip permanent entries that are switch's own MACs (usually on bridge interface)
    # But keep physical port entries even if marked permanent
    if 'permanent' in line and 'dev br' in line:
        continue
    parts = line.split()
    if len(parts) < 3:
        continue
    mac = parts[0]
    iface = vlan = ''
    is_permanent = 'permanent' in line
    for i, p in enumerate(parts):
        if p == 'dev' and i+1 < len(parts): iface = parts[i+1]
        if p == 'vlan' and i+1 < len(parts): vlan = parts[i+1]
    # Skip bridge interface entries (switch's own MACs)
    if iface and iface.startswith('br'):
        continue
    if mac and iface:
        entry = {'mac': mac, 'interface': iface, 'vlan': vlan}
        if is_permanent:
            entry['type'] = 'static'
        mac_entries.append(entry)

# Parse VTEP
vtep_entries = []
for line in sections.get('VTEP', []):
    if not line.strip():
        continue
    parts = line.split()
    mac = dst = vni = ''
    if parts:
        mac = parts[0]
    for i, p in enumerate(parts):
        if p == 'dst' and i+1 < len(parts): dst = parts[i+1]
        if p in ['vni', 'src_vni'] and i+1 < len(parts): vni = parts[i+1]
    if dst:
        vtep_entries.append({'mac': mac, 'remote_vtep': dst, 'vni': vni})

# Parse BOND members (format: bondname:swp1 swp2)
bond_members = {}
for line in sections.get('BOND', []):
    if not line.strip() or ':' not in line:
        continue
    bond_name, members = line.split(':', 1)
    if members.strip():
        bond_members[bond_name] = members.strip().split()

# Add bond_ports to MAC entries
for entry in mac_entries:
    iface = entry.get('interface', '')
    if iface in bond_members:
        entry['bond_ports'] = bond_members[iface]

# Parse ROUTES (per VRF)
route_entries = {}  # vrf -> list of routes
current_vrf = 'default'
for line in sections.get('ROUTES', []):
    line = line.strip()
    if not line:
        continue
    if line.startswith('VRF:'):
        current_vrf = line[4:]
        if current_vrf not in route_entries:
            route_entries[current_vrf] = []
        continue
    
    # Parse route line: prefix [via nexthop] [nhid X] [dev interface] [proto protocol] [metric X]
    parts = line.split()
    if not parts:
        continue
    
    prefix = parts[0]
    
    # Convert 'default' to '0.0.0.0/0'
    if prefix == 'default':
        prefix = '0.0.0.0/0'
    
    nexthop = ''
    nhid = ''
    interface = ''
    protocol = ''
    metric = ''
    
    for i, p in enumerate(parts):
        if p == 'via' and i+1 < len(parts): nexthop = parts[i+1]
        if p == 'nhid' and i+1 < len(parts): nhid = parts[i+1]
        if p == 'dev' and i+1 < len(parts): interface = parts[i+1]
        if p == 'proto' and i+1 < len(parts): protocol = parts[i+1]
        if p == 'metric' and i+1 < len(parts): metric = parts[i+1]
    
    # If no via but has nhid, it's ECMP (mark as such)
    if not nexthop and nhid:
        nexthop = 'ECMP'
    
    # Skip local routes, linkdown, unreachable
    if protocol in ['kernel', 'redirect'] or 'linkdown' in line or 'unreachable' in line:
        continue
    
    if current_vrf not in route_entries:
        route_entries[current_vrf] = []
    
    route_entries[current_vrf].append({
        'prefix': prefix,
        'nexthop': nexthop,
        'interface': interface,
        'protocol': protocol,
        'metric': metric
    })

result = {
    'arp': arp_entries,
    'mac': mac_entries,
    'vtep': vtep_entries,
    'bonds': bond_members,
    'routes': route_entries,
    'lldp': []  # Skip LLDP for now to keep it simple
}

with open('$output_file', 'w') as f:
    json.dump(result, f)

print('OK')
PYEOF
}

# Main execution
echo "Fabric Scan - Collecting network tables"
echo "========================================"

# Get devices into array
devices_list=$(get_devices)
device_count=$(echo "$devices_list" | wc -l)

echo "Devices: $device_count"
echo "Collecting..."

# Parallel collection using temp file for device list
tmp_devices=$(mktemp)
echo "$devices_list" > "$tmp_devices"

job_count=0
while IFS='|' read -r ip hostname; do
    [ -z "$ip" ] && continue
    
    (
        result=$(collect_device_data "$ip" "$hostname" 2>/dev/null)
        case "$result" in
            OK) echo -n "." ;;
            SKIP) echo -n "-" ;;
            *) echo -n "x" ;;
        esac
    ) &
    
    job_count=$((job_count + 1))
    
    if [ $job_count -ge $MAX_PARALLEL ]; then
        wait -n 2>/dev/null || wait
        job_count=$((job_count - 1))
    fi
done < "$tmp_devices"

# Wait for ALL remaining jobs
wait

rm -f "$tmp_devices"
echo ""

# Create summary file with timestamp
python3 << PYEOF
import os
import json
from datetime import datetime

output_dir = "$OUTPUT_DIR"
summary = {
    "timestamp": datetime.now().isoformat(),
    "devices": []
}

for f in os.listdir(output_dir):
    if f.endswith('.json') and f != 'summary.json':
        hostname = f.replace('.json', '')
        filepath = os.path.join(output_dir, f)
        try:
            with open(filepath) as fp:
                data = json.load(fp)
            summary["devices"].append({
                "hostname": hostname,
                "arp_count": len(data.get("arp", [])),
                "mac_count": len(data.get("mac", [])),
                "vtep_count": len(data.get("vtep", [])),
                "lldp_count": len(data.get("lldp", []))
            })
        except:
            pass

with open(os.path.join(output_dir, "summary.json"), "w") as f:
    json.dump(summary, f, indent=2)

print(f"Scan complete: {len(summary['devices'])} devices")
print(f"Results: {output_dir}/")
PYEOF

exit 0
