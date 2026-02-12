#!/bin/bash
# provision-api.sh - Provision API (ZTP + Base Config)
# Backend for provision.html
# Called by nginx fcgiwrap

# Load config
if [[ -f /etc/lldpq.conf ]]; then
    source /etc/lldpq.conf
fi

LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
LLDPQ_USER="${LLDPQ_USER:-lldpq}"
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

# DHCP config paths
DHCP_HOSTS_FILE="${DHCP_HOSTS_FILE:-/etc/dhcp/dhcpd.hosts}"
DHCP_CONF_FILE="${DHCP_CONF_FILE:-/etc/dhcp/dhcpd.conf}"
DHCP_LEASES_FILE="${DHCP_LEASES_FILE:-/var/lib/dhcp/dhcpd.leases}"
ZTP_SCRIPT_FILE="${ZTP_SCRIPT_FILE:-${WEB_ROOT}/cumulus-ztp.sh}"
BASE_CONFIG_DIR="${BASE_CONFIG_DIR:-${LLDPQ_DIR}/sw-base}"

# Output JSON header
echo "Content-Type: application/json"
echo ""

# Parse query string
ACTION=$(echo "$QUERY_STRING" | grep -oP 'action=\K[^&]*' | head -1)

# Read POST data if present
POST_DATA=""
if [ "$REQUEST_METHOD" = "POST" ] && [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
fi

# Discovery config
DISCOVERY_RANGE="${DISCOVERY_RANGE:-}"
AUTO_BASE_CONFIG="${AUTO_BASE_CONFIG:-true}"
AUTO_ZTP_DISABLE="${AUTO_ZTP_DISABLE:-true}"
AUTO_SET_HOSTNAME="${AUTO_SET_HOSTNAME:-true}"

# Export for Python
export LLDPQ_DIR LLDPQ_USER WEB_ROOT
export DHCP_HOSTS_FILE DHCP_CONF_FILE DHCP_LEASES_FILE ZTP_SCRIPT_FILE BASE_CONFIG_DIR
export DISCOVERY_RANGE AUTO_BASE_CONFIG AUTO_ZTP_DISABLE AUTO_SET_HOSTNAME
export POST_DATA ACTION

python3 << 'PYTHON_SCRIPT'
import json
import sys
import os
import re
import subprocess
from concurrent.futures import ThreadPoolExecutor, as_completed

import time

ACTION = os.environ.get('ACTION', '')
POST_DATA = os.environ.get('POST_DATA', '')
LLDPQ_DIR = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
LLDPQ_USER = os.environ.get('LLDPQ_USER', 'lldpq')
WEB_ROOT = os.environ.get('WEB_ROOT', '/var/www/html')
DHCP_HOSTS_FILE = os.environ.get('DHCP_HOSTS_FILE', '/etc/dhcp/dhcpd.hosts')
DHCP_LEASES_FILE = os.environ.get('DHCP_LEASES_FILE', '/var/lib/dhcp/dhcpd.leases')
ZTP_SCRIPT_FILE = os.environ.get('ZTP_SCRIPT_FILE', f'{WEB_ROOT}/cumulus-ztp.sh')
BASE_CONFIG_DIR = os.environ.get('BASE_CONFIG_DIR', f'{LLDPQ_DIR}/sw-base')
DISCOVERY_RANGE = os.environ.get('DISCOVERY_RANGE', '')
AUTO_BASE_CONFIG = os.environ.get('AUTO_BASE_CONFIG', 'true') == 'true'
AUTO_ZTP_DISABLE = os.environ.get('AUTO_ZTP_DISABLE', 'true') == 'true'
AUTO_SET_HOSTNAME = os.environ.get('AUTO_SET_HOSTNAME', 'true') == 'true'
DISCOVERY_CACHE_FILE = f'{WEB_ROOT}/discovery-cache.json'

def update_lldpq_conf(key, value):
    """Update or add a key=value in /etc/lldpq.conf."""
    conf = '/etc/lldpq.conf'
    try:
        with open(conf, 'r') as f:
            lines = f.readlines()
    except Exception:
        lines = []
    found = False
    for i, line in enumerate(lines):
        if line.startswith(f'{key}='):
            lines[i] = f'{key}={value}\n'
            found = True
            break
    if not found:
        lines.append(f'{key}={value}\n')
    content = ''.join(lines)
    try:
        with open(conf, 'w') as f:
            f.write(content)
    except PermissionError:
        subprocess.run(['sudo', 'tee', conf], input=content, capture_output=True, text=True, timeout=5)

def read_lldpq_conf_key(key, default=''):
    """Read a single key from /etc/lldpq.conf."""
    try:
        with open('/etc/lldpq.conf', 'r') as f:
            for line in f:
                if line.startswith(f'{key}='):
                    return line.strip().split('=', 1)[1]
    except Exception:
        pass
    return default

def ip_range_to_list(range_str):
    """Parse comma-separated IP ranges to list of IPs.
    Supports: '192.168.100.10-192.168.100.249'
              '192.168.100.11-192.168.100.199,192.168.100.201-192.168.100.252'
    """
    if not range_str:
        return []
    result = []
    for segment in range_str.split(','):
        segment = segment.strip()
        if not segment or '-' not in segment:
            continue
        try:
            start_s, end_s = segment.split('-', 1)
            start_parts = list(map(int, start_s.strip().split('.')))
            end_parts = list(map(int, end_s.strip().split('.')))
            if start_parts[:3] == end_parts[:3]:
                prefix = '.'.join(map(str, start_parts[:3]))
                result.extend(f'{prefix}.{i}' for i in range(start_parts[3], end_parts[3] + 1))
            else:
                import ipaddress
                start = int(ipaddress.IPv4Address(start_s.strip()))
                end = int(ipaddress.IPv4Address(end_s.strip()))
                result.extend(str(ipaddress.IPv4Address(i)) for i in range(start, end + 1))
        except Exception:
            continue
    return result

# Also check alternate path for dhcpd.hosts (some setups use dhcpd.host)
DHCP_HOSTS_ALT = DHCP_HOSTS_FILE.replace('dhcpd.hosts', 'dhcpd.host')

def get_dhcp_hosts_path():
    """Find the actual dhcpd.hosts file"""
    for p in [DHCP_HOSTS_FILE, DHCP_HOSTS_ALT]:
        if os.path.exists(p):
            return p
    # Default to primary path (will be created if needed)
    return DHCP_HOSTS_FILE

def result_json(data):
    print(json.dumps(data))
    sys.exit(0)

def error_json(msg):
    result_json({"success": False, "error": msg})

# ======================== BINDINGS ========================

def parse_dhcp_hosts(filepath):
    """Parse ISC dhcpd.hosts file into a list of bindings.
    Format: host HOSTNAME {hardware ethernet MAC; fixed-address IP; ...}
    Also handles commented-out lines (starting with #).
    """
    bindings = []
    if not os.path.exists(filepath):
        return bindings
    
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Match host entries (both active and commented)
    pattern = re.compile(
        r'^(\s*#?\s*)'                            # optional comment marker
        r'host\s+(\S+)\s*\{'                      # host HOSTNAME {
        r'[^}]*hardware\s+ethernet\s+([\w:]+)\s*;' # hardware ethernet MAC;
        r'[^}]*fixed-address\s+([\d.]+)\s*;'       # fixed-address IP;
        r'[^}]*\}',                                 # }
        re.MULTILINE
    )
    
    for m in pattern.finditer(content):
        prefix = m.group(1).strip()
        commented = prefix.startswith('#')
        hostname = m.group(2)
        mac = m.group(3).lower()
        ip = m.group(4)
        bindings.append({
            'hostname': hostname,
            'mac': mac,
            'ip': ip,
            'commented': commented
        })
    
    return bindings

def generate_dhcp_hosts(bindings, orig_filepath):
    """Generate ISC dhcpd.hosts file content from bindings list.
    Preserves the group header from original file if present.
    """
    lines = []
    
    # Try to preserve header from original file
    header = ""
    if os.path.exists(orig_filepath):
        with open(orig_filepath, 'r') as f:
            orig = f.read()
        # Extract everything before first 'host' line
        first_host = re.search(r'^#?\s*host\s+', orig, re.MULTILINE)
        if first_host:
            header = orig[:first_host.start()]
    
    if not header.strip():
        # Default header — use gateway from dhcpd.conf if available
        server_ip = get_server_ip()
        gw = server_ip.rsplit('.', 1)[0] + '.1' if '.' in server_ip else server_ip
        header = f"""group {{

  option domain-name "nvidia";
  option domain-name-servers {gw};
  option routers {gw};

"""
    
    lines.append(header.rstrip() + '\n')
    
    for b in bindings:
        # Auto-comment entries with placeholder MACs (contain 'x')
        is_placeholder = 'x' in b.get('mac', '').lower()
        prefix = '#' if (b.get('commented') or is_placeholder) else ''
        line = (
            f'{prefix}host {b["hostname"]} '
            f'{{hardware ethernet {b["mac"]}; '
            f'fixed-address {b["ip"]}; '
            f'option host-name "{b["hostname"]}"; '
            f'option fqdn.hostname "{b["hostname"]}"; '
            f'option cumulus-provision-url "http://{get_server_ip()}/cumulus-ztp.sh";}}'
        )
        lines.append(line)
    
    # Close group if header had one
    if 'group {' in header or 'group{' in header:
        lines.append('\n}')
    
    return '\n'.join(lines) + '\n'

def get_server_ip():
    """Try to determine this server's IP for ZTP URL.
    Falls back to reading from existing dhcpd.conf or hosts file.
    """
    # Try to get from dhcpd.conf
    conf_path = os.environ.get('DHCP_CONF_FILE', '/etc/dhcp/dhcpd.conf')
    if os.path.exists(conf_path):
        with open(conf_path, 'r') as f:
            content = f.read()
        m = re.search(r'cumulus-provision-url\s+"http://([^/]+)/', content)
        if m:
            return m.group(1)
    
    # Try existing hosts file
    hosts_path = get_dhcp_hosts_path()
    if os.path.exists(hosts_path):
        with open(hosts_path, 'r') as f:
            content = f.read()
        m = re.search(r'cumulus-provision-url\s+"http://([^/]+)/', content)
        if m:
            return m.group(1)
    
    # Fallback: try to get our own IP
    try:
        result = subprocess.run(
            ['hostname', '-I'], capture_output=True, text=True, timeout=5
        )
        ips = result.stdout.strip().split()
        if ips:
            return ips[0]
    except Exception:
        pass
    
    return '127.0.0.1'

def action_list_bindings():
    filepath = get_dhcp_hosts_path()
    bindings = parse_dhcp_hosts(filepath)
    result_json({"success": True, "bindings": bindings, "file": filepath})

def action_save_bindings():
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    bindings = data.get('bindings', [])
    filepath = get_dhcp_hosts_path()
    
    # Generate new content
    content = generate_dhcp_hosts(bindings, filepath)
    
    # Write file (may need sudo)
    try:
        # Try direct write first
        with open(filepath, 'w') as f:
            f.write(content)
    except PermissionError:
        # Use sudo via tee
        try:
            proc = subprocess.run(
                ['sudo', 'tee', filepath],
                input=content, capture_output=True, text=True, timeout=10
            )
            if proc.returncode != 0:
                error_json(f"Failed to write {filepath}: {proc.stderr}")
        except Exception as e:
            error_json(f"Failed to write {filepath}: {e}")
    
    # Restart DHCP
    restart_ok, restart_msg = restart_dhcp()
    
    result_json({
        "success": True,
        "message": f"Saved {len(bindings)} bindings",
        "dhcp_restart": restart_ok,
        "dhcp_message": restart_msg
    })

def restart_dhcp():
    """Restart ISC DHCP server. Returns (success, message)."""
    for svc in ['isc-dhcp-server', 'dhcpd']:
        try:
            result = subprocess.run(
                ['sudo', 'systemctl', 'restart', svc],
                capture_output=True, text=True, timeout=15
            )
            if result.returncode == 0:
                return True, f"{svc} restarted"
        except Exception:
            continue
    
    # Try direct dhcpd restart (Docker)
    try:
        # Kill existing
        subprocess.run(['sudo', 'pkill', '-x', 'dhcpd'], capture_output=True, timeout=5)
        # Find interface
        iface = 'eth0'
        isc_default = '/etc/default/isc-dhcp-server'
        if os.path.exists(isc_default):
            with open(isc_default) as f:
                m = re.search(r'INTERFACES="(\S+)"', f.read())
                if m:
                    iface = m.group(1)
        # Start
        result = subprocess.run(
            ['sudo', 'dhcpd', '-cf', os.environ.get('DHCP_CONF_FILE', '/etc/dhcp/dhcpd.conf'), iface],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            return True, "dhcpd restarted"
        return False, result.stderr.strip()[:200]
    except Exception as e:
        return False, str(e)

# ======================== DISCOVERED ========================

def action_discovered():
    """Cross-reference fabric ARP/LLDP data with DHCP bindings.
    
    Data sources (in priority order):
    1. fabric-tables/*.json — per-device ARP tables from fabric-scan.sh
       Contains eth0/mgmt ARP entries with IP→MAC mappings
    2. device-cache.json — assets data with hostname→MAC
    3. devices.yaml — known devices with IP→hostname mapping
    
    Cross-reference approach:
    - Build IP→MAC map from all ARP tables (eth0 interface = mgmt MAC)
    - For each DHCP binding (hostname, IP, MAC), look up discovered MAC by IP
    - Compare binding MAC vs discovered MAC
    """
    import glob
    
    # Load bindings
    bindings = parse_dhcp_hosts(get_dhcp_hosts_path())
    binding_ip_map = {b['ip']: b for b in bindings}
    
    entries = []
    discovered_ips = {}   # ip -> mac (from ARP)
    discovered_hosts = {} # hostname -> mac (from device-cache)
    
    # --- Source 1: fabric-tables ARP data ---
    # Each fabric-table JSON has "arp" list with entries like:
    # {"ip": "192.168.100.11", "mac": "54:9b:24:aa:68:16", "interface": "eth0", "vrf": "mgmt"}
    fabric_tables_dir = os.path.join(LLDPQ_DIR, 'monitor-results', 'fabric-tables')
    if os.path.isdir(fabric_tables_dir):
        for fpath in glob.glob(os.path.join(fabric_tables_dir, '*.json')):
            try:
                with open(fpath, 'r') as f:
                    data = json.load(f)
                for arp_entry in data.get('arp', []):
                    iface = arp_entry.get('interface', '')
                    ip = arp_entry.get('ip', '')
                    mac = arp_entry.get('mac', '').lower()
                    # Only mgmt interface ARP = management MAC (used in DHCP bindings)
                    if iface == 'eth0' and ip and mac and ip.startswith('192.168.'):
                        # Keep the entry (last writer wins, but they should all agree)
                        discovered_ips[ip] = mac
            except Exception:
                continue
    
    # --- Source 2: device-cache.json ---
    device_cache = os.path.join(WEB_ROOT, 'device-cache.json')
    if os.path.exists(device_cache):
        try:
            with open(device_cache, 'r') as f:
                dc = json.load(f)
            if isinstance(dc, dict):
                for hostname, info in dc.items():
                    if isinstance(info, dict):
                        mac = info.get('mac', '').lower()
                        ip = info.get('ip', '')
                        if mac:
                            discovered_hosts[hostname] = mac
                        if ip and mac:
                            discovered_ips[ip] = mac
        except Exception:
            pass
    
    # --- Source 3: devices.yaml for hostname→IP mapping ---
    devices_file = os.path.join(LLDPQ_DIR, 'devices.yaml')
    hostname_to_ip = {}
    if os.path.exists(devices_file):
        try:
            import yaml
            with open(devices_file, 'r') as f:
                dev_data = yaml.safe_load(f)
            devices_section = dev_data.get('devices', dev_data)
            for ip, info in devices_section.items():
                if ip in ('defaults', 'endpoint_hosts'):
                    continue
                if isinstance(info, dict):
                    hostname = info.get('hostname', str(ip))
                elif isinstance(info, str):
                    hostname = info.strip().split('@')[0].strip()
                else:
                    hostname = str(info) if info else str(ip)
                hostname_to_ip[hostname] = str(ip)
        except Exception:
            pass
    
    # --- Cross-reference ---
    seen_hostnames = set()
    
    for b in bindings:
        hostname = b['hostname']
        binding_mac = b['mac'].lower()
        binding_ip = b['ip']
        seen_hostnames.add(hostname)
        
        # Try to find discovered MAC: by IP first, then by hostname
        disc_mac = discovered_ips.get(binding_ip, '')
        source = 'ARP' if disc_mac else ''
        
        if not disc_mac:
            disc_mac = discovered_hosts.get(hostname, '')
            source = 'Cache' if disc_mac else ''
        
        entry = {
            'hostname': hostname,
            'binding_mac': b['mac'],
            'binding_ip': binding_ip,
            'discovered_mac': disc_mac,
            'source': source,
            'status': 'missing'
        }
        
        if disc_mac:
            if disc_mac == binding_mac:
                entry['status'] = 'match'
            else:
                entry['status'] = 'mismatch'
        
        entries.append(entry)
    
    # Discovered IPs not in bindings (devices seen in ARP but no DHCP binding)
    # Determine subnet from bindings to filter relevant IPs
    binding_subnets = set()
    for b in bindings:
        parts = b['ip'].split('.')
        if len(parts) == 4:
            binding_subnets.add('.'.join(parts[:3]) + '.')
    
    for ip, mac in discovered_ips.items():
        if ip not in binding_ip_map and any(ip.startswith(s) for s in binding_subnets):
            # Try to find hostname from devices.yaml
            hostname = ''
            for h, h_ip in hostname_to_ip.items():
                if h_ip == ip:
                    hostname = h
                    break
            if not hostname:
                hostname = ip  # fallback to IP
            
            if hostname not in seen_hostnames:
                entries.append({
                    'hostname': hostname,
                    'binding_mac': '',
                    'binding_ip': '',
                    'discovered_mac': mac,
                    'source': 'ARP',
                    'status': 'unbound'
                })
                seen_hostnames.add(hostname)
    
    result_json({"success": True, "entries": entries})

def action_ping_scan():
    """Parallel ping all binding IPs, then read local ARP for MAC cross-reference.
    Much more accurate than fabric-tables — gives real-time reachability + MAC match.
    """
    bindings = parse_dhcp_hosts(get_dhcp_hosts_path())
    if not bindings:
        error_json("No bindings to scan")
    
    # Step 1: Parallel ping all binding IPs (all-at-once, like pping)
    def ping_one(ip):
        try:
            r = subprocess.run(
                ['ping', '-c', '1', '-W', '1', '-i', '0.2', ip],
                capture_output=True, text=True, timeout=2
            )
            return ip, r.returncode == 0
        except Exception:
            return ip, False
    
    ping_results = {}  # ip -> True/False
    with ThreadPoolExecutor(max_workers=250) as executor:
        futures = {executor.submit(ping_one, b['ip']): b['ip'] for b in bindings}
        for future in as_completed(futures):
            ip, alive = future.result()
            ping_results[ip] = alive
    
    # Step 2: Read local ARP table (populated by the pings we just did)
    local_arp = {}  # ip -> mac
    try:
        r = subprocess.run(['ip', 'neigh', 'show'], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            for line in r.stdout.strip().split('\n'):
                parts = line.split()
                # Format: IP dev IFACE lladdr MAC state
                if 'lladdr' in parts:
                    ip = parts[0]
                    mac_idx = parts.index('lladdr') + 1
                    if mac_idx < len(parts):
                        local_arp[ip] = parts[mac_idx].lower()
    except Exception:
        pass
    
    # Step 3: Cross-reference
    entries = []
    for b in bindings:
        hostname = b['hostname']
        binding_mac = b['mac'].lower()
        binding_ip = b['ip']
        alive = ping_results.get(binding_ip, False)
        disc_mac = local_arp.get(binding_ip, '')
        
        entry = {
            'hostname': hostname,
            'binding_mac': b['mac'],
            'binding_ip': binding_ip,
            'discovered_mac': disc_mac,
            'source': 'Ping+ARP' if disc_mac else ('Ping' if alive else ''),
            'status': 'unreachable'
        }
        
        if alive and disc_mac:
            if disc_mac == binding_mac:
                entry['status'] = 'match'
            else:
                entry['status'] = 'mismatch'
        elif alive and not disc_mac:
            entry['status'] = 'match'  # alive but ARP not captured (rare)
            entry['source'] = 'Ping'
        # else: unreachable
        
        entries.append(entry)
    
    result_json({"success": True, "entries": entries, "scan_type": "ping"})

def action_subnet_scan():
    """Full subnet discovery: ping all IPs in range, ARP for MACs, SSH probe for classification,
    post-provision actions (sw-base, ztp disable, hostname set) for newly provisioned devices."""
    
    # Get discovery range
    disc_range = read_lldpq_conf_key('DISCOVERY_RANGE', DISCOVERY_RANGE)
    if not disc_range:
        # Auto-detect from dhcpd.conf subnet
        conf_path = os.environ.get('DHCP_CONF_FILE', '/etc/dhcp/dhcpd.conf')
        try:
            with open(conf_path, 'r') as f:
                content = f.read()
            m = re.search(r'subnet\s+([\d.]+)', content)
            if m:
                prefix = '.'.join(m.group(1).split('.')[:3])
                disc_range = f'{prefix}.10-{prefix}.249'
        except Exception:
            pass
    
    if not disc_range:
        error_json("No discovery range configured. Set it in DHCP Server Configuration.")
    
    all_ips = ip_range_to_list(disc_range)
    if not all_ips:
        error_json(f"Invalid discovery range: {disc_range}")
    
    # Load bindings for cross-reference
    bindings = parse_dhcp_hosts(get_dhcp_hosts_path())
    binding_by_ip = {b['ip']: b for b in bindings}
    binding_by_hostname = {b['hostname']: b for b in bindings}
    
    # Load devices.yaml for hostname resolution
    devices_yaml = {}
    try:
        devices_path = os.path.join(LLDPQ_DIR, 'devices.yaml')
        if os.path.exists(devices_path):
            import yaml
            with open(devices_path, 'r') as f:
                data = yaml.safe_load(f) or {}
            for section in data.values():
                if isinstance(section, dict):
                    for host, info in section.items():
                        if isinstance(info, dict) and 'ip' in info:
                            devices_yaml[info['ip']] = host
    except Exception:
        pass
    
    # Step 1: Parallel ping all IPs in discovery range
    def ping_one(ip):
        try:
            r = subprocess.run(['ping', '-c', '1', '-W', '1', '-i', '0.2', ip],
                             capture_output=True, text=True, timeout=3)
            return ip, r.returncode == 0
        except Exception:
            return ip, False
    
    ping_results = {}
    with ThreadPoolExecutor(max_workers=250) as executor:
        futures = {executor.submit(ping_one, ip): ip for ip in all_ips}
        for future in as_completed(futures):
            ip, alive = future.result()
            ping_results[ip] = alive
    
    # Step 2: Read local ARP table
    local_arp = {}
    try:
        r = subprocess.run(['ip', 'neigh', 'show'], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            for line in r.stdout.strip().split('\n'):
                parts = line.split()
                if 'lladdr' in parts:
                    ip = parts[0]
                    mac_idx = parts.index('lladdr') + 1
                    if mac_idx < len(parts):
                        local_arp[ip] = parts[mac_idx].lower()
    except Exception:
        pass
    
    reachable_ips = [ip for ip, alive in ping_results.items() if alive]
    
    # Step 3: SSH probe reachable IPs for device classification
    def ssh_probe(ip):
        """Try SSH with key auth as cumulus user (runs as LLDPQ_USER to use correct SSH keys).
        Returns: 'provisioned', 'not_provisioned', 'other'"""
        try:
            r = subprocess.run(
                ['sudo', '-u', LLDPQ_USER, 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                 '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                 '-o', 'LogLevel=ERROR', f'cumulus@{ip}', 'echo OK'],
                capture_output=True, text=True, timeout=8
            )
            if r.returncode == 0 and 'OK' in r.stdout:
                return ip, 'provisioned'
            stderr = r.stderr.lower()
            if 'permission denied' in stderr:
                return ip, 'not_provisioned'
            if 'connection refused' in stderr:
                return ip, 'other'
            return ip, 'not_provisioned'
        except subprocess.TimeoutExpired:
            return ip, 'other'
        except Exception:
            return ip, 'other'
    
    ssh_results = {}
    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = {executor.submit(ssh_probe, ip): ip for ip in reachable_ips}
        for future in as_completed(futures):
            ip, device_type = future.result()
            ssh_results[ip] = device_type
    
    # Step 4: Build entries with cross-reference
    entries = []
    for ip in all_ips:
        alive = ping_results.get(ip, False)
        disc_mac = local_arp.get(ip, '')
        binding = binding_by_ip.get(ip)
        
        hostname = ''
        binding_mac = ''
        binding_ip = ip
        mac_status = ''
        
        if binding:
            hostname = binding['hostname']
            binding_mac = binding['mac']
            if alive and disc_mac:
                mac_status = 'match' if disc_mac == binding_mac.lower() else 'mismatch'
            elif alive:
                mac_status = 'match'
            else:
                mac_status = 'unreachable'
        else:
            hostname = devices_yaml.get(ip, '')
            mac_status = 'no_binding'
        
        if not alive:
            device_type = 'unreachable'
        else:
            device_type = ssh_results.get(ip, 'other')
        
        entry = {
            'ip': ip,
            'hostname': hostname,
            'binding_mac': binding_mac,
            'discovered_mac': disc_mac,
            'device_type': device_type,
            'mac_status': mac_status,
            'source': 'Ping+ARP' if disc_mac else ('Ping' if alive else ''),
            'has_binding': binding is not None,
            'post_provision': None,
        }
        entries.append(entry)
    
    # Step 5: Post-provision actions for newly provisioned devices
    auto_base = read_lldpq_conf_key('AUTO_BASE_CONFIG', 'true') == 'true'
    auto_ztp = read_lldpq_conf_key('AUTO_ZTP_DISABLE', 'true') == 'true'
    auto_host = read_lldpq_conf_key('AUTO_SET_HOSTNAME', 'true') == 'true'
    
    if auto_base or auto_ztp or auto_host:
        provisioned_entries = [e for e in entries if e['device_type'] == 'provisioned' and e['has_binding']]
        
        def post_provision_one(entry):
            ip = entry['ip']
            hostname = entry['hostname']
            
            # Check marker
            try:
                r = subprocess.run(
                    ['sudo', '-u', LLDPQ_USER, 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                     '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                     '-o', 'LogLevel=ERROR', f'cumulus@{ip}',
                     'test -f /etc/lldpq-base-deployed && echo DONE || echo NEW'],
                    capture_output=True, text=True, timeout=8
                )
                if 'DONE' in r.stdout:
                    return ip, 'already'
            except Exception:
                return ip, None
            
            # Execute post-provision actions
            cmds = []
            
            # sw-base deploy via SCP + SSH
            if auto_base and os.path.isdir(BASE_CONFIG_DIR):
                files_map = {
                    'bash.bashrc': '/etc/bash.bashrc',
                    'motd.sh': '/etc/profile.d/motd.sh',
                    'tmux.conf': '/home/cumulus/.tmux.conf',
                    'nanorc': '/home/cumulus/.nanorc',
                    'cmd': '/usr/local/bin/cmd',
                    'nvc': '/usr/local/bin/nvc',
                    'nvt': '/usr/local/bin/nvt',
                    'exa': '/usr/bin/exa',
                }
                scp_files = []
                copy_cmds = []
                for fname, dest in files_map.items():
                    src = os.path.join(BASE_CONFIG_DIR, fname)
                    if os.path.exists(src):
                        scp_files.append(src)
                        copy_cmds.append(f'sudo cp /tmp/{fname} {dest}')
                        if dest.startswith('/usr/') or fname in ('cmd', 'nvc', 'nvt', 'exa', 'motd.sh'):
                            copy_cmds.append(f'sudo chmod 755 {dest}')
                
                if scp_files:
                    try:
                        subprocess.run(
                            ['sudo', '-u', LLDPQ_USER, 'scp', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=3',
                             '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                             '-o', 'LogLevel=ERROR'] + scp_files + [f'cumulus@{ip}:/tmp/'],
                            capture_output=True, text=True, timeout=15
                        )
                        cmds.extend(copy_cmds)
                    except Exception:
                        pass
            
            # ZTP disable
            if auto_ztp:
                cmds.append('sudo ztp -d 2>/dev/null || true')
            
            # Hostname set
            if auto_host and hostname:
                cmds.append(f'sudo nv set system hostname {hostname} 2>/dev/null && sudo nv config apply -y 2>/dev/null || true')
            
            # Write marker
            cmds.append('sudo touch /etc/lldpq-base-deployed')
            
            if cmds:
                cmd_str = ' && '.join(cmds)
                try:
                    subprocess.run(
                        ['sudo', '-u', LLDPQ_USER, 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5',
                         '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null',
                         '-o', 'LogLevel=ERROR', f'cumulus@{ip}', cmd_str],
                        capture_output=True, text=True, timeout=30
                    )
                    return ip, 'deployed'
                except Exception:
                    return ip, None
            
            return ip, None
        
        # Run post-provision in parallel (limited workers since these are heavier)
        post_results = {}
        if provisioned_entries:
            with ThreadPoolExecutor(max_workers=10) as executor:
                futures = {executor.submit(post_provision_one, e): e['ip'] for e in provisioned_entries}
                for future in as_completed(futures):
                    ip, status = future.result()
                    post_results[ip] = status
            
            # Update entries with post-provision results
            for entry in entries:
                if entry['ip'] in post_results:
                    entry['post_provision'] = post_results[entry['ip']]
    
    # Step 6: Write cache
    cache_data = {
        'timestamp': time.time(),
        'discovery_range': disc_range,
        'entries': entries,
    }
    try:
        with open(DISCOVERY_CACHE_FILE, 'w') as f:
            json.dump(cache_data, f)
    except PermissionError:
        subprocess.run(['sudo', 'tee', DISCOVERY_CACHE_FILE],
                      input=json.dumps(cache_data), capture_output=True, text=True, timeout=5)
    
    result_json({
        "success": True,
        "entries": entries,
        "scan_type": "subnet",
        "discovery_range": disc_range,
        "total_ips": len(all_ips),
        "reachable": len(reachable_ips),
        "post_provision_results": {ip: s for ip, s in post_results.items()} if 'post_results' in dir() else {},
    })

def action_get_discovery_cache():
    """Read cached discovery results."""
    if not os.path.exists(DISCOVERY_CACHE_FILE):
        result_json({"success": True, "entries": [], "stale": True, "timestamp": 0})
    
    try:
        with open(DISCOVERY_CACHE_FILE, 'r') as f:
            data = json.load(f)
        age = time.time() - data.get('timestamp', 0)
        data['success'] = True
        data['stale'] = age > 300  # stale if > 5 minutes
        data['age_seconds'] = int(age)
        result_json(data)
    except Exception as e:
        result_json({"success": True, "entries": [], "stale": True, "timestamp": 0, "error": str(e)})

def action_save_post_provision():
    """Save post-provision toggle settings."""
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON")
    
    if 'auto_base_config' in data:
        update_lldpq_conf('AUTO_BASE_CONFIG', 'true' if data['auto_base_config'] else 'false')
    if 'auto_ztp_disable' in data:
        update_lldpq_conf('AUTO_ZTP_DISABLE', 'true' if data['auto_ztp_disable'] else 'false')
    if 'auto_set_hostname' in data:
        update_lldpq_conf('AUTO_SET_HOSTNAME', 'true' if data['auto_set_hostname'] else 'false')
    if 'discovery_range' in data:
        update_lldpq_conf('DISCOVERY_RANGE', data['discovery_range'])
    
    result_json({"success": True, "message": "Settings saved"})

# ======================== ZTP SCRIPT ========================

def action_get_ztp_script():
    if not os.path.exists(ZTP_SCRIPT_FILE):
        # Try alternate locations
        for alt in ['/var/www/html/cumulus-ztp.sh', f'{WEB_ROOT}/cumulus-ztp.sh']:
            if os.path.exists(alt):
                with open(alt, 'r') as f:
                    result_json({"success": True, "content": f.read(), "file": alt})
        result_json({"success": True, "content": "", "file": ZTP_SCRIPT_FILE})
    
    with open(ZTP_SCRIPT_FILE, 'r') as f:
        content = f.read()
    result_json({"success": True, "content": content, "file": ZTP_SCRIPT_FILE})

def action_save_ztp_script():
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    content = data.get('content', '')
    if not content.strip():
        error_json("Script content is empty")
    
    filepath = ZTP_SCRIPT_FILE
    
    try:
        with open(filepath, 'w') as f:
            f.write(content)
        # Ensure executable
        os.chmod(filepath, 0o755)
    except PermissionError:
        try:
            proc = subprocess.run(
                ['sudo', 'tee', filepath],
                input=content, capture_output=True, text=True, timeout=10
            )
            if proc.returncode != 0:
                error_json(f"Failed to write: {proc.stderr}")
            subprocess.run(['sudo', 'chmod', '755', filepath], capture_output=True, timeout=5)
        except Exception as e:
            error_json(str(e))
    
    result_json({"success": True, "message": "ZTP script saved"})

# ======================== DHCP STATUS ========================

def action_dhcp_service_status():
    """Check if DHCP service is running."""
    running = False
    
    # Try systemctl
    try:
        for svc in ['isc-dhcp-server', 'dhcpd']:
            r = subprocess.run(
                ['systemctl', 'is-active', svc],
                capture_output=True, text=True, timeout=5
            )
            if r.stdout.strip() == 'active':
                running = True
                break
    except Exception:
        pass
    
    if not running:
        # Check if dhcpd process is running
        try:
            r = subprocess.run(['pgrep', '-x', 'dhcpd'], capture_output=True, timeout=5)
            running = r.returncode == 0
        except Exception:
            pass
    
    result_json({"success": True, "running": running})

def action_dhcp_service_control():
    """Start, stop, or restart DHCP service."""
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    action = data.get('action', '')
    if action not in ('start', 'stop', 'restart'):
        error_json(f"Invalid action: {action}")
    
    # Try systemctl first
    for svc in ['isc-dhcp-server', 'dhcpd']:
        try:
            r = subprocess.run(
                ['sudo', 'systemctl', action, svc],
                capture_output=True, text=True, timeout=15
            )
            if r.returncode == 0:
                # Stop also disables (prevent auto-start on boot)
                if action == 'stop':
                    subprocess.run(['sudo', 'systemctl', 'disable', svc],
                                   capture_output=True, text=True, timeout=10)
                    result_json({"success": True, "message": f"{svc} stopped & disabled"})
                # Start also enables
                elif action == 'start':
                    subprocess.run(['sudo', 'systemctl', 'enable', svc],
                                   capture_output=True, text=True, timeout=10)
                    result_json({"success": True, "message": f"{svc} started & enabled"})
                else:
                    result_json({"success": True, "message": f"{svc} restarted"})
        except Exception:
            continue
    
    # Fallback: direct process management (Docker)
    if action in ('stop', 'restart'):
        subprocess.run(['sudo', 'pkill', '-x', 'dhcpd'], capture_output=True, timeout=5)
        if action == 'stop':
            result_json({"success": True, "message": "dhcpd stopped"})
    
    if action in ('start', 'restart'):
        ok, msg = restart_dhcp()
        result_json({"success": ok, "message": msg, "error": "" if ok else msg})
    
    error_json("Could not control DHCP service")

def action_get_dhcp_config():
    """Read dhcpd.conf and isc-dhcp-server defaults, return parsed settings."""
    conf_path = os.environ.get('DHCP_CONF_FILE', '/etc/dhcp/dhcpd.conf')
    isc_default = '/etc/default/isc-dhcp-server'
    
    config = {
        'subnet': '', 'netmask': '', 'range_start': '', 'range_end': '',
        'gateway': '', 'dns': '', 'domain': '', 'provision_url': '',
        'interface': 'eth0', 'lease_time': '172800'
    }
    
    # Parse dhcpd.conf
    if os.path.exists(conf_path):
        try:
            with open(conf_path, 'r') as f:
                content = f.read()
        except PermissionError:
            r = subprocess.run(['sudo', 'cat', conf_path], capture_output=True, text=True, timeout=5)
            content = r.stdout if r.returncode == 0 else ''
        
        # subnet X netmask Y
        m = re.search(r'subnet\s+([\d.]+)\s+netmask\s+([\d.]+)', content)
        if m:
            config['subnet'] = m.group(1)
            config['netmask'] = m.group(2)
        
        # range START END
        m = re.search(r'range\s+([\d.]+)\s+([\d.]+)', content)
        if m:
            config['range_start'] = m.group(1)
            config['range_end'] = m.group(2)
        
        # option routers
        m = re.search(r'option\s+routers\s+([\d.]+)', content)
        if m:
            config['gateway'] = m.group(1)
        
        # option domain-name-servers
        m = re.search(r'option\s+domain-name-servers\s+([\d.]+)', content)
        if m:
            config['dns'] = m.group(1)
        
        # option domain-name
        m = re.search(r'option\s+domain-name\s+"([^"]*)"', content)
        if m:
            config['domain'] = m.group(1)
        
        # cumulus-provision-url
        m = re.search(r'cumulus-provision-url\s+"([^"]*)"', content)
        if m:
            config['provision_url'] = m.group(1)
        
        # default-lease-time
        m = re.search(r'default-lease-time\s+(\d+)', content)
        if m:
            config['lease_time'] = m.group(1)
    
    # Parse interface from /etc/default/isc-dhcp-server
    if os.path.exists(isc_default):
        try:
            with open(isc_default, 'r') as f:
                isc_content = f.read()
            m = re.search(r'INTERFACES="([^"]*)"', isc_content)
            if m:
                config['interface'] = m.group(1)
        except Exception:
            pass
    
    # List network interfaces with IP addresses
    interfaces = []
    try:
        r = subprocess.run(['ip', '-4', '-o', 'addr', 'show'], capture_output=True, text=True, timeout=5)
        if r.returncode == 0:
            seen = set()
            for line in r.stdout.strip().split('\n'):
                parts = line.split()
                if len(parts) >= 4:
                    iface_name = parts[1]
                    ip_cidr = parts[3]  # e.g. 192.168.100.200/24
                    ip_addr = ip_cidr.split('/')[0]
                    if iface_name not in seen and iface_name != 'lo':
                        interfaces.append({'name': iface_name, 'ip': ip_addr})
                        seen.add(iface_name)
    except Exception:
        pass
    
    # Read discovery range and post-provision settings from lldpq.conf
    discovery_range = read_lldpq_conf_key('DISCOVERY_RANGE', '')
    # Auto-generate default from subnet if empty
    if not discovery_range and config['subnet']:
        prefix = '.'.join(config['subnet'].split('.')[:3])
        discovery_range = f'{prefix}.10-{prefix}.249'
    
    result_json({
        "success": True,
        "interfaces": interfaces,
        "discovery_range": discovery_range,
        "auto_base_config": read_lldpq_conf_key('AUTO_BASE_CONFIG', 'true') == 'true',
        "auto_ztp_disable": read_lldpq_conf_key('AUTO_ZTP_DISABLE', 'true') == 'true',
        "auto_set_hostname": read_lldpq_conf_key('AUTO_SET_HOSTNAME', 'true') == 'true',
        **config
    })

def action_save_dhcp_config():
    """Write dhcpd.conf from settings and restart DHCP."""
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    subnet = data.get('subnet', '')
    netmask = data.get('netmask', '255.255.255.0')
    range_start = data.get('range_start', '')
    range_end = data.get('range_end', '')
    gateway = data.get('gateway', '')
    dns = data.get('dns', gateway)
    domain = data.get('domain', 'nvidia')
    provision_url = data.get('provision_url', '')
    iface = data.get('interface', 'eth0')
    lease_time = data.get('lease_time', '172800')
    
    # Find hosts include path
    hosts_path = get_dhcp_hosts_path()
    
    # Generate dhcpd.conf
    range_line = f'    range {range_start} {range_end};' if range_start and range_end else '    # range not configured'
    prov_line = f'    option cumulus-provision-url "{provision_url}";' if provision_url else ''
    
    conf = f"""# /etc/dhcp/dhcpd.conf - Generated by LLDPq Provision

ddns-update-style none;
authoritative;
log-facility local7;

option www-server code 72 = ip-address;
option default-url code 114 = text;
option cumulus-provision-url code 239 = text;
option space onie code width 1 length width 1;
option onie.installer_url code 1 = text;
option onie.updater_url   code 2 = text;
option onie.machine       code 3 = text;
option onie.arch          code 4 = text;
option onie.machine_rev   code 5 = text;

option space vivso code width 4 length width 1;
option vivso.onie code 42623 = encapsulate onie;
option vivso.iana code 0 = string;
option op125 code 125 = encapsulate vivso;

class "onie-vendor-classes" {{
  match if substring(option vendor-class-identifier, 0, 11) = "onie_vendor";
  option vivso.iana 01:01:01;
}}

# OOB Management subnet
shared-network OOB {{
  subnet {subnet} netmask {netmask} {{
{range_line}
    option routers {gateway};
    option domain-name "{domain}";
    option domain-name-servers {dns};
    option www-server {gateway};
    option default-url "http://{gateway}/";
{prov_line}
    default-lease-time {lease_time};
    max-lease-time     {int(lease_time) * 2};
  }}
}}

include "{hosts_path}";
"""
    
    conf_path = os.environ.get('DHCP_CONF_FILE', '/etc/dhcp/dhcpd.conf')
    
    # Write dhcpd.conf
    try:
        with open(conf_path, 'w') as f:
            f.write(conf)
    except PermissionError:
        proc = subprocess.run(['sudo', 'tee', conf_path], input=conf, capture_output=True, text=True, timeout=10)
        if proc.returncode != 0:
            error_json(f"Failed to write dhcpd.conf: {proc.stderr}")
    
    # Write interface config
    isc_default = '/etc/default/isc-dhcp-server'
    isc_content = f'INTERFACES="{iface}"\n'
    try:
        with open(isc_default, 'w') as f:
            f.write(isc_content)
    except PermissionError:
        subprocess.run(['sudo', 'tee', isc_default], input=isc_content, capture_output=True, text=True, timeout=5)
    
    # Save discovery range to lldpq.conf
    discovery_range = data.get('discovery_range', '')
    if discovery_range:
        update_lldpq_conf('DISCOVERY_RANGE', discovery_range)
    
    # Save post-provision toggles
    if 'auto_base_config' in data:
        update_lldpq_conf('AUTO_BASE_CONFIG', 'true' if data['auto_base_config'] else 'false')
    if 'auto_ztp_disable' in data:
        update_lldpq_conf('AUTO_ZTP_DISABLE', 'true' if data['auto_ztp_disable'] else 'false')
    if 'auto_set_hostname' in data:
        update_lldpq_conf('AUTO_SET_HOSTNAME', 'true' if data['auto_set_hostname'] else 'false')
    
    # Restart DHCP
    ok, msg = restart_dhcp()
    result_json({
        "success": True,
        "message": f"Config saved. DHCP: {msg}",
        "dhcp_restart": ok
    })

def parse_dhcp_leases(filepath):
    """Parse ISC dhcpd.leases file."""
    leases = []
    if not os.path.exists(filepath):
        return leases
    
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Parse lease blocks
    lease_pattern = re.compile(
        r'lease\s+([\d.]+)\s*\{(.*?)\}',
        re.DOTALL
    )
    
    for m in lease_pattern.finditer(content):
        ip = m.group(1)
        block = m.group(2)
        
        lease = {'ip': ip, 'mac': '', 'hostname': '', 'start': '', 'end': '', 'state': 'active'}
        
        # Parse fields
        mac_m = re.search(r'hardware\s+ethernet\s+([\w:]+)', block)
        if mac_m:
            lease['mac'] = mac_m.group(1).lower()
        
        host_m = re.search(r'client-hostname\s+"([^"]*)"', block)
        if host_m:
            lease['hostname'] = host_m.group(1)
        
        start_m = re.search(r'starts\s+\d+\s+([\d/]+\s+[\d:]+)', block)
        if start_m:
            lease['start'] = start_m.group(1)
        
        end_m = re.search(r'ends\s+\d+\s+([\d/]+\s+[\d:]+)', block)
        if end_m:
            lease['end'] = end_m.group(1)
        
        state_m = re.search(r'binding\s+state\s+(\w+)', block)
        if state_m:
            lease['state'] = state_m.group(1)
        
        leases.append(lease)
    
    # Deduplicate: keep last lease per IP (most recent)
    seen = {}
    for l in leases:
        seen[l['ip']] = l
    
    return sorted(seen.values(), key=lambda x: x['ip'])

def action_dhcp_leases():
    leases = parse_dhcp_leases(DHCP_LEASES_FILE)
    bindings = parse_dhcp_hosts(get_dhcp_hosts_path())
    result_json({
        "success": True,
        "leases": leases,
        "reserved_count": len(bindings)
    })

# ======================== LIST DEVICES ========================

def action_list_devices():
    """List devices from devices.yaml for base config deploy target selection."""
    devices_file = os.path.join(LLDPQ_DIR, 'devices.yaml')
    
    if not os.path.exists(devices_file):
        error_json(f"devices.yaml not found at {devices_file}")
    
    try:
        import yaml
        with open(devices_file, 'r') as f:
            data = yaml.safe_load(f)
    except Exception as e:
        error_json(str(e))
    
    defaults = data.get('defaults', {})
    default_username = defaults.get('username', 'cumulus')
    
    devices_section = data.get('devices', data)
    devices = []
    
    groups = {}  # role -> [devices]
    
    for ip, info in devices_section.items():
        if ip in ('defaults', 'endpoint_hosts'):
            continue
        
        role = 'ungrouped'
        if isinstance(info, dict):
            hostname = info.get('hostname', str(ip))
            username = info.get('username', default_username)
            role = info.get('role', 'ungrouped')
        elif isinstance(info, str):
            # Format: "hostname @role" or just "hostname"
            raw = info.strip()
            if '@' in raw:
                parts = raw.split('@')
                hostname = parts[0].strip()
                role = parts[1].strip()
            else:
                hostname = raw
            username = default_username
        else:
            hostname = str(info) if info else str(ip)
            username = default_username
        
        dev = {'ip': str(ip), 'hostname': hostname, 'username': username, 'role': role}
        groups.setdefault(role, []).append(dev)
    
    # Sort devices within each group by hostname
    for role in groups:
        groups[role].sort(key=lambda x: x['hostname'])
    
    # Flat list for backward compat
    all_devices = []
    for devs in groups.values():
        all_devices.extend(devs)
    all_devices.sort(key=lambda x: x['hostname'])
    
    result_json({"success": True, "devices": all_devices, "groups": groups})

# ======================== BASE CONFIG DEPLOY ========================

# File deployment mapping: source name -> (destination, permissions, extra_dest)
FILE_DEPLOY_MAP = {
    'bash.bashrc': [
        {'dest': '/etc/bash.bashrc', 'mode': '644'},
        {'dest': '/home/cumulus/.bashrc', 'mode': '644'}
    ],
    'motd.sh': [
        {'dest': '/etc/profile.d/motd.sh', 'mode': '755'}
    ],
    'tmux.conf': [
        {'dest': '/etc/tmux.conf', 'mode': '644'}
    ],
    'nanorc': [
        {'dest': '/etc/nanorc', 'mode': '644'}
    ],
    'cmd': [
        {'dest': '/usr/local/bin/cmd', 'mode': '755'}
    ],
    'nvc': [
        {'dest': '/usr/local/bin/nvc', 'mode': '755'}
    ],
    'nvt': [
        {'dest': '/usr/local/bin/nvt', 'mode': '755'}
    ],
    'exa': [
        {'dest': '/usr/bin/exa', 'mode': '755'}
    ]
}

def deploy_to_device(device, files, disable_ztp):
    """Deploy base config files to a single device via SCP + SSH.
    Returns result dict.
    """
    ip = device['ip']
    hostname = device['hostname']
    username = device.get('username', 'cumulus')
    
    result = {
        'ip': ip,
        'hostname': hostname,
        'success': False,
        'message': '',
        'error': ''
    }
    
    ssh_opts = ['-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=no', '-o', 'BatchMode=yes']
    
    # Step 1: Check connectivity
    try:
        check = subprocess.run(
            ['sudo', '-u', LLDPQ_USER, 'ssh'] + ssh_opts + ['-q', f'{username}@{ip}', 'echo ok'],
            capture_output=True, text=True, timeout=15
        )
        if check.returncode != 0:
            result['error'] = 'SSH connection failed (key not configured?)'
            return result
    except subprocess.TimeoutExpired:
        result['error'] = 'SSH connection timeout'
        return result
    except Exception as e:
        result['error'] = str(e)
        return result
    
    # Step 2: SCP files to /tmp/
    scp_files = []
    for fname in files:
        src = os.path.join(BASE_CONFIG_DIR, fname)
        if os.path.exists(src):
            scp_files.append(src)
    
    if not scp_files:
        result['error'] = 'No source files found'
        return result
    
    try:
        scp_cmd = ['sudo', '-u', LLDPQ_USER, 'scp'] + ssh_opts + scp_files + [f'{username}@{ip}:/tmp/']
        scp_result = subprocess.run(scp_cmd, capture_output=True, text=True, timeout=60)
        if scp_result.returncode != 0:
            result['error'] = f'SCP failed: {scp_result.stderr.strip()[:200]}'
            return result
    except subprocess.TimeoutExpired:
        result['error'] = 'SCP timeout'
        return result
    except Exception as e:
        result['error'] = f'SCP error: {e}'
        return result
    
    # Step 3: SSH to move files to correct locations
    mv_commands = []
    for fname in files:
        if fname in FILE_DEPLOY_MAP:
            for target in FILE_DEPLOY_MAP[fname]:
                dest = target['dest']
                mode = target['mode']
                mv_commands.append(f'sudo cp /tmp/{fname} {dest} && sudo chmod {mode} {dest}')
    
    if disable_ztp:
        mv_commands.append('sudo ztp -d 2>/dev/null || true')
    
    # Cleanup tmp files
    cleanup = ' '.join(f'/tmp/{fname}' for fname in files)
    mv_commands.append(f'rm -f {cleanup}')
    
    remote_cmd = ' && '.join(mv_commands)
    
    try:
        ssh_cmd = ['sudo', '-u', LLDPQ_USER, 'ssh'] + ssh_opts + [f'{username}@{ip}', remote_cmd]
        ssh_result = subprocess.run(ssh_cmd, capture_output=True, text=True, timeout=30)
        if ssh_result.returncode != 0:
            result['error'] = f'Remote install failed: {ssh_result.stderr.strip()[:200]}'
            return result
    except subprocess.TimeoutExpired:
        result['error'] = 'SSH command timeout'
        return result
    except Exception as e:
        result['error'] = f'SSH error: {e}'
        return result
    
    result['success'] = True
    result['message'] = f'{len(files)} files deployed'
    return result

def action_deploy_base_config():
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    files = data.get('files', [])
    devices = data.get('devices', [])
    disable_ztp = data.get('disable_ztp', False)
    
    # If no files specified, deploy all known files (skip missing ones)
    if not files:
        files = list(FILE_DEPLOY_MAP.keys())
    
    if not devices:
        error_json("No devices selected")
    
    # Filter to only files that exist on disk (graceful skip)
    available_files = [f for f in files if f in FILE_DEPLOY_MAP and os.path.exists(os.path.join(BASE_CONFIG_DIR, f))]
    if not available_files:
        error_json("No deploy files found in " + BASE_CONFIG_DIR)
    files = available_files
    
    # Deploy in parallel (20 workers max)
    results = []
    with ThreadPoolExecutor(max_workers=20) as executor:
        futures = {
            executor.submit(deploy_to_device, dev, files, disable_ztp): dev
            for dev in devices
        }
        for future in as_completed(futures):
            try:
                results.append(future.result())
            except Exception as e:
                dev = futures[future]
                results.append({
                    'ip': dev['ip'],
                    'hostname': dev['hostname'],
                    'success': False,
                    'error': str(e)
                })
    
    # Sort by hostname
    results.sort(key=lambda x: x['hostname'])
    
    ok = sum(1 for r in results if r['success'])
    fail = len(results) - ok
    
    result_json({
        "success": True,
        "results": results,
        "summary": {"ok": ok, "fail": fail, "total": len(results)}
    })

# ======================== SSH KEY ========================

def get_ssh_key_info():
    """Find existing SSH key for LLDPQ_USER. Returns (pub_key_content, key_type, key_file) or (None,None,None)."""
    home = os.path.expanduser(f'~{LLDPQ_USER}')
    for key_type, key_name in [('ed25519', 'id_ed25519'), ('rsa', 'id_rsa')]:
        pub_path = os.path.join(home, '.ssh', f'{key_name}.pub')
        if os.path.isfile(pub_path):
            try:
                with open(pub_path, 'r') as f:
                    return f.read().strip(), key_type, pub_path
            except PermissionError:
                r = subprocess.run(['sudo', '-u', LLDPQ_USER, 'cat', pub_path],
                                   capture_output=True, text=True, timeout=5)
                if r.returncode == 0:
                    return r.stdout.strip(), key_type, pub_path
    return None, None, None

def action_get_ssh_key():
    pub_key, key_type, key_file = get_ssh_key_info()
    if pub_key:
        result_json({"success": True, "public_key": pub_key, "key_type": key_type, "key_file": key_file})
    else:
        result_json({"success": True, "public_key": "", "key_type": "", "key_file": ""})

def action_generate_ssh_key():
    home = os.path.expanduser(f'~{LLDPQ_USER}')
    ssh_dir = os.path.join(home, '.ssh')
    key_path = os.path.join(ssh_dir, 'id_ed25519')
    pub_path = key_path + '.pub'
    
    try:
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        
        # Remove old keys if exist
        for f in [key_path, pub_path]:
            if os.path.exists(f):
                os.remove(f)
        
        # Generate as LLDPQ_USER
        result = subprocess.run(
            ['sudo', '-u', LLDPQ_USER, 'ssh-keygen', '-t', 'ed25519', '-N', '', '-f', key_path, '-C', f'lldpq@provision'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            error_json(f'ssh-keygen failed: {result.stderr}')
        
        # Read public key
        with open(pub_path, 'r') as f:
            pub_key = f.read().strip()
        
        result_json({"success": True, "public_key": pub_key, "key_type": "ed25519", "key_file": pub_path})
    except Exception as e:
        error_json(str(e))

def action_import_ssh_key():
    """Import an existing private key (paste from another server/setup)."""
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    private_key = data.get('private_key', '').strip()
    if not private_key or 'PRIVATE KEY' not in private_key:
        error_json("Invalid private key")
    
    # Ensure newline at end
    if not private_key.endswith('\n'):
        private_key += '\n'
    
    home = os.path.expanduser(f'~{LLDPQ_USER}')
    ssh_dir = os.path.join(home, '.ssh')
    
    # Detect key type from content
    if 'ed25519' in private_key.lower() or 'ED25519' in private_key:
        key_name = 'id_ed25519'
        key_type = 'ed25519'
    elif 'RSA' in private_key:
        key_name = 'id_rsa'
        key_type = 'rsa'
    else:
        key_name = 'id_ed25519'
        key_type = 'unknown'
    
    key_path = os.path.join(ssh_dir, key_name)
    pub_path = key_path + '.pub'
    
    try:
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        
        # Write private key
        with open(key_path, 'w') as f:
            f.write(private_key)
        os.chmod(key_path, 0o600)
        
        # Extract public key from private key
        result = subprocess.run(
            ['ssh-keygen', '-y', '-f', key_path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            with open(pub_path, 'w') as f:
                f.write(result.stdout.strip() + f' {LLDPQ_USER}@imported\n')
            os.chmod(pub_path, 0o644)
        else:
            # Clean up on failure
            os.remove(key_path)
            error_json(f"Invalid private key: {result.stderr.strip()[:200]}")
        
        # Fix ownership
        subprocess.run(['chown', f'{LLDPQ_USER}:{LLDPQ_USER}', key_path, pub_path],
                       capture_output=True, timeout=5)
        
        # Read public key
        with open(pub_path, 'r') as f:
            pub_key = f.read().strip()
        
        result_json({"success": True, "public_key": pub_key, "key_type": key_type, "key_file": pub_path})
    except Exception as e:
        error_json(str(e))

# ======================== OS IMAGES ========================

def action_list_os_images():
    """List Cumulus Linux image files in web root."""
    images = []
    for ext in ['*.bin', '*.img', '*.iso']:
        import glob as g
        for f in g.glob(os.path.join(WEB_ROOT, ext)):
            name = os.path.basename(f)
            size_bytes = os.path.getsize(f)
            if size_bytes > 1048576:
                size = f'{size_bytes / 1048576:.0f} MB'
            else:
                size = f'{size_bytes / 1024:.0f} KB'
            images.append({"name": name, "size": size, "path": f})
    images.sort(key=lambda x: x['name'])
    result_json({"success": True, "images": images})

def action_upload_os_image():
    """Handle multipart file upload for OS images.
    Since we're behind fcgiwrap, we read raw stdin.
    """
    # For multipart uploads through fcgiwrap, we need to handle it differently
    # The file comes through POST_DATA or stdin
    content_type = os.environ.get('CONTENT_TYPE', '')
    
    if 'multipart/form-data' in content_type:
        # Parse boundary
        boundary = content_type.split('boundary=')[-1].strip()
        
        # Read raw POST data from stdin (already read as POST_DATA)
        raw = POST_DATA.encode('latin-1') if POST_DATA else b''
        if not raw:
            # Try reading from stdin
            import sys
            raw = sys.stdin.buffer.read()
        
        if not raw:
            error_json("No file data received")
        
        # Parse multipart
        parts = raw.split(f'--{boundary}'.encode())
        for part in parts:
            if b'filename=' in part:
                # Extract filename
                header_end = part.find(b'\r\n\r\n')
                if header_end < 0:
                    continue
                headers = part[:header_end].decode('latin-1', errors='replace')
                file_data = part[header_end + 4:]
                # Remove trailing \r\n--
                if file_data.endswith(b'\r\n'):
                    file_data = file_data[:-2]
                if file_data.endswith(b'--'):
                    file_data = file_data[:-2]
                if file_data.endswith(b'\r\n'):
                    file_data = file_data[:-2]
                
                # Extract filename
                fn_match = re.search(r'filename="([^"]+)"', headers)
                if not fn_match:
                    continue
                filename = os.path.basename(fn_match.group(1))
                
                # Validate extension
                if not any(filename.endswith(ext) for ext in ['.bin', '.img', '.iso']):
                    error_json(f"Invalid file type: {filename}. Only .bin, .img, .iso allowed.")
                
                # Write file
                dest = os.path.join(WEB_ROOT, filename)
                try:
                    with open(dest, 'wb') as f:
                        f.write(file_data)
                    os.chmod(dest, 0o644)
                    result_json({"success": True, "message": f"Uploaded {filename}", "size": len(file_data)})
                except PermissionError:
                    # Use sudo
                    proc = subprocess.run(['sudo', 'tee', dest], input=file_data,
                                          capture_output=True, timeout=120)
                    if proc.returncode == 0:
                        subprocess.run(['sudo', 'chmod', '644', dest], capture_output=True, timeout=5)
                        result_json({"success": True, "message": f"Uploaded {filename}"})
                    else:
                        error_json(f"Write failed: {proc.stderr.decode()[:200]}")
    
    error_json("No file found in upload")

def action_delete_os_image():
    try:
        data = json.loads(POST_DATA)
    except Exception:
        error_json("Invalid JSON data")
    
    name = data.get('name', '')
    if not name or '/' in name or '..' in name:
        error_json("Invalid filename")
    
    filepath = os.path.join(WEB_ROOT, name)
    if not os.path.exists(filepath):
        error_json(f"File not found: {name}")
    
    try:
        os.remove(filepath)
    except PermissionError:
        subprocess.run(['sudo', 'rm', '-f', filepath], capture_output=True, timeout=5)
    
    result_json({"success": True, "message": f"Deleted {name}"})

# ======================== ROUTER ========================

if ACTION == 'list-bindings':
    action_list_bindings()
elif ACTION == 'save-bindings':
    action_save_bindings()
elif ACTION == 'discovered':
    action_discovered()
elif ACTION == 'get-ztp-script':
    action_get_ztp_script()
elif ACTION == 'save-ztp-script':
    action_save_ztp_script()
elif ACTION == 'dhcp-service-status':
    action_dhcp_service_status()
elif ACTION == 'dhcp-service-control':
    action_dhcp_service_control()
elif ACTION == 'get-dhcp-config':
    action_get_dhcp_config()
elif ACTION == 'save-dhcp-config':
    action_save_dhcp_config()
elif ACTION == 'dhcp-leases':
    action_dhcp_leases()
elif ACTION == 'list-devices':
    action_list_devices()
elif ACTION == 'deploy-base-config':
    action_deploy_base_config()
elif ACTION == 'ping-scan':
    action_ping_scan()
elif ACTION == 'subnet-scan':
    action_subnet_scan()
elif ACTION == 'discovery-cache':
    action_get_discovery_cache()
elif ACTION == 'save-post-provision':
    action_save_post_provision()
elif ACTION == 'get-ssh-key':
    action_get_ssh_key()
elif ACTION == 'generate-ssh-key':
    action_generate_ssh_key()
elif ACTION == 'import-ssh-key':
    action_import_ssh_key()
elif ACTION == 'list-os-images':
    action_list_os_images()
elif ACTION == 'upload-os-image':
    action_upload_os_image()
elif ACTION == 'delete-os-image':
    action_delete_os_image()
else:
    error_json(f"Unknown action: {ACTION}")

PYTHON_SCRIPT
