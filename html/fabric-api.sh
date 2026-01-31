#!/bin/bash
# Fabric Configuration API
# Backend for fabric-config.html

# Load config - explicitly read ANSIBLE_DIR from config file
if [[ -f /etc/lldpq.conf ]]; then
    ANSIBLE_DIR=$(grep "^ANSIBLE_DIR=" /etc/lldpq.conf | cut -d= -f2)
fi
ANSIBLE_DIR="${ANSIBLE_DIR:-$HOME/ansible}"

# Export for Python scripts
export ANSIBLE_DIR

# Output JSON header
echo "Content-Type: application/json"
echo ""

# Parse query string
parse_query() {
    local query="$QUERY_STRING"
    # Parse action
    ACTION=$(echo "$query" | grep -oP 'action=\K[^&]*' | head -1)
    # Parse hostname
    HOSTNAME=$(echo "$query" | grep -oP 'hostname=\K[^&]*' | head -1 | python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))")
}

# List devices from inventory/hosts
list_devices() {
    local hosts_file="$ANSIBLE_DIR/inventory/hosts"
    
    if [[ ! -f "$hosts_file" ]]; then
        echo '{"success": false, "error": "Inventory file not found: '"$hosts_file"'"}'
        return
    fi
    
    # Python script to parse hosts file
    python3 << 'PYTHON'
import sys
import json
import os

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
hosts_file = f"{ansible_dir}/inventory/hosts"

devices = {}
current_group = None

try:
    with open(hosts_file, 'r') as f:
        for line in f:
            line = line.strip()
            
            # Skip empty lines and comments
            if not line or line.startswith('#'):
                continue
            
            # Skip [all:vars] and similar sections
            if line.startswith('[') and ':' in line:
                current_group = None
                continue
            
            # Group header
            if line.startswith('[') and line.endswith(']'):
                current_group = line[1:-1]
                # Skip children groups
                if ':children' in current_group:
                    current_group = None
                else:
                    devices[current_group] = []
                continue
            
            # Device line
            if current_group and '=' in line:
                parts = line.split()
                hostname = parts[0]
                ip = None
                
                # Find ansible_host
                for part in parts[1:]:
                    if part.startswith('ansible_host='):
                        ip = part.split('=')[1]
                        break
                
                devices[current_group].append({
                    'hostname': hostname,
                    'ip': ip
                })
    
    print(json.dumps({
        'success': True,
        'devices': devices,
        'ansible_dir': ansible_dir
    }))

except Exception as e:
    print(json.dumps({
        'success': False,
        'error': str(e)
    }))
PYTHON
}

# Get device configuration
get_device() {
    local hostname="$1"
    
    if [[ -z "$hostname" ]]; then
        echo '{"success": false, "error": "Hostname is required"}'
        return
    fi
    
    local host_vars_file="$ANSIBLE_DIR/inventory/host_vars/${hostname}.yaml"
    
    # Python script to parse host_vars and find device info
    # Host vars file is optional - some devices (like spines) may not have it
    python3 << PYTHON
import sys
import json
import yaml
import os

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
hostname = "$hostname"
host_vars_file = f"{ansible_dir}/inventory/host_vars/{hostname}.yaml"
hosts_file = f"{ansible_dir}/inventory/hosts"
port_profiles_file = f"{ansible_dir}/inventory/group_vars/all/sw_port_profiles.yaml"
vlan_profiles_file = f"{ansible_dir}/inventory/group_vars/all/vlan_profiles.yaml"

try:
    # Read host_vars (optional - some devices like spines may not have it)
    config = {}
    if os.path.exists(host_vars_file):
        with open(host_vars_file, 'r') as f:
            config = yaml.safe_load(f) or {}
    
    # Find device info from hosts file
    device_info = {'hostname': hostname, 'group': None, 'ip': None}
    current_group = None
    
    with open(hosts_file, 'r') as f:
        for line in f:
            line = line.strip()
            
            if not line or line.startswith('#'):
                continue
            
            if line.startswith('[') and line.endswith(']'):
                current_group = line[1:-1]
                if ':' in current_group:
                    current_group = None
                continue
            
            if current_group and line.startswith(hostname):
                device_info['group'] = current_group
                parts = line.split()
                for part in parts[1:]:
                    if part.startswith('ansible_host='):
                        device_info['ip'] = part.split('=')[1]
                        break
                break
    
    # Check for group_vars VRFs if not in host_vars
    if 'vrfs' not in config and device_info['group']:
        group_vrfs_file = f"{ansible_dir}/inventory/group_vars/{device_info['group']}/vrfs.yaml"
        if os.path.exists(group_vrfs_file):
            with open(group_vrfs_file, 'r') as f:
                group_config = yaml.safe_load(f) or {}
                if 'vrfs' in group_config:
                    config['vrfs'] = group_config['vrfs']
    
    # Load port profiles for VLAN resolution
    port_profiles = {}
    if os.path.exists(port_profiles_file):
        with open(port_profiles_file, 'r') as f:
            pp_config = yaml.safe_load(f) or {}
            port_profiles = pp_config.get('sw_port_profiles', {})
    
    # Load VLAN profiles for VRF and IP resolution
    vlan_to_vrf = {}
    vlan_profiles_data = {}
    vxlan_int_mapping = {}  # VRF name -> VLAN ID for L3VNI interface
    
    if os.path.exists(vlan_profiles_file):
        with open(vlan_profiles_file, 'r') as f:
            vp_config = yaml.safe_load(f) or {}
            
            # Load vxlan_int mapping (nscale/kddi style: vxlan_int at top level)
            if 'vxlan_int' in vp_config and isinstance(vp_config['vxlan_int'], dict):
                vxlan_int_mapping = {str(k): str(v) for k, v in vp_config['vxlan_int'].items()}
            
            vlan_profiles = vp_config.get('vlan_profiles', {})
            # Build VLAN ID to VRF mapping and VLAN profile data
            for profile_name, profile_data in vlan_profiles.items():
                if profile_data and 'vlans' in profile_data:
                    vrr_enabled = profile_data.get('vrr', {}).get('state', False)
                    vlan_ids = sorted([int(v) for v in profile_data['vlans'].keys()])
                    
                    # Build vlan_to_vrf mapping for all VLANs
                    for vlan_id, vlan_config in profile_data['vlans'].items():
                        if vlan_config and 'vrf' in vlan_config:
                            vlan_to_vrf[str(vlan_id)] = vlan_config['vrf']
                    
                    # Get first VLAN's config for description/VRF etc
                    first_vlan_id = vlan_ids[0] if vlan_ids else None
                    first_vlan_config = profile_data['vlans'].get(str(first_vlan_id)) or profile_data['vlans'].get(first_vlan_id) or {}
                    
                    # Get last VLAN's l2vni for range profiles
                    last_vlan_id = vlan_ids[-1] if vlan_ids else None
                    last_vlan_config = profile_data['vlans'].get(str(last_vlan_id)) or profile_data['vlans'].get(last_vlan_id) or {}
                    
                    # Determine VLAN ID display (single or range)
                    if len(vlan_ids) == 1:
                        vlan_id_display = str(vlan_ids[0])
                    else:
                        vlan_id_display = f"{vlan_ids[0]}-{vlan_ids[-1]}"
                    
                    # Store VLAN profile info for SVI section
                    vlan_profiles_data[profile_name] = {
                        'vlan_id': vlan_id_display,
                        'vlan_count': len(vlan_ids),
                        'description': first_vlan_config.get('description', ''),
                        'vrf': first_vlan_config.get('vrf', 'default'),
                        'l2vni': last_vlan_config.get('l2vni'),
                        'vrr_enabled': vrr_enabled,
                        'vrr_vip': first_vlan_config.get('vrr_vip'),
                        'even_ip': first_vlan_config.get('even_ip'),
                        'odd_ip': first_vlan_config.get('odd_ip'),
                        'ip': first_vlan_config.get('ip'),
                        'vlans': profile_data['vlans']  # Include raw vlans data
                    }
    
    print(json.dumps({
        'success': True,
        'config': config,
        'device_info': device_info,
        'port_profiles': port_profiles,
        'vlan_to_vrf': vlan_to_vrf,
        'vlan_profiles': vlan_profiles_data,
        'vxlan_int_mapping': vxlan_int_mapping
    }))

except Exception as e:
    print(json.dumps({
        'success': False,
        'error': str(e)
    }))
PYTHON
}

# Get VLAN profiles
get_vlan_profiles() {
    local vlan_file="$ANSIBLE_DIR/inventory/group_vars/all/vlan_profiles.yaml"
    
    if [[ ! -f "$vlan_file" ]]; then
        echo '{"success": false, "error": "VLAN profiles file not found"}'
        return
    fi
    
    python3 << PYTHON
import json
import yaml
import os

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
vlan_file = f"{ansible_dir}/inventory/group_vars/all/vlan_profiles.yaml"

try:
    with open(vlan_file, 'r') as f:
        config = yaml.safe_load(f) or {}
    
    print(json.dumps({
        'success': True,
        'vlan_profiles': config.get('vlan_profiles', {}),
        'vxlan_int': config.get('vxlan_int', {})
    }))

except Exception as e:
    print(json.dumps({
        'success': False,
        'error': str(e)
    }))
PYTHON
}

# Bulk create VLANs
bulk_create_vlans() {
    read -r POST_DATA
    python3 << PYTHON
import json
import yaml
import os
import sys

try:
    data = json.loads('''$POST_DATA''')
except:
    data = json.loads(sys.stdin.read()) if sys.stdin.isatty() == False else {}

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
vlan_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'vlan_profiles.yaml')

start_id = data.get('start_id', 1)
end_id = data.get('end_id', 1)
profile_name = data.get('profile_name', f'VLAN_{start_id}_{end_id}_L2')
description = data.get('description', f'L2 VLANs {start_id}-{end_id}')
l2vni_offset = data.get('l2vni_offset', 100000)

# Validate
if start_id < 1 or end_id > 4094 or start_id > end_id:
    print(json.dumps({'success': False, 'error': 'Invalid VLAN ID range'}))
    exit(0)

count = end_id - start_id + 1
if count > 500:
    print(json.dumps({'success': False, 'error': 'Maximum 500 VLANs at once'}))
    exit(0)

# Load existing vlan profiles
vlan_profiles = {}
if os.path.exists(vlan_file):
    with open(vlan_file, 'r') as f:
        existing = yaml.safe_load(f) or {}
        vlan_profiles = existing.get('vlan_profiles', {})

# Check if profile name already exists
if profile_name in vlan_profiles:
    print(json.dumps({'success': False, 'error': f'Profile {profile_name} already exists'}))
    exit(0)

# Create the VLAN profile with multiple VLANs inside
vlans_dict = {}
for vid in range(start_id, end_id + 1):
    vlans_dict[vid] = {
        'description': f'{description}',
        'l2vni': l2vni_offset + vid
    }

new_profile = {
    'vlans': vlans_dict
}

vlan_profiles[profile_name] = new_profile

# Write back
with open(vlan_file, 'w') as f:
    yaml.dump({'vlan_profiles': vlan_profiles}, f, default_flow_style=False, sort_keys=False)

print(json.dumps({'success': True, 'message': f'Created {count} VLANs in profile {profile_name}'}))
PYTHON
}

# ==================== BGP PROFILES ====================

# Get VRFs that can be used for leaking (those that have profiles with route_import)
get_leaking_vrfs() {
    python3 << PYTHON
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
bgp_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')

leaking_vrfs = []

try:
    # First, find BGP profiles that have route_import.from_vrf
    if os.path.exists(bgp_file):
        with open(bgp_file, 'r') as f:
            data = yaml.safe_load(f) or {}
            bgp_profiles = data.get('bgp_profiles', {})
            
            # Find all VRFs mentioned in from_vrf across all profiles
            imported_vrfs = set()
            for profile_name, profile_config in bgp_profiles.items():
                ipv4_af = profile_config.get('ipv4_unicast_af', {})
                route_import = ipv4_af.get('route_import', {})
                from_vrf = route_import.get('from_vrf', [])
                for vrf in from_vrf:
                    imported_vrfs.add(vrf)
            
            # These VRFs can be leaked into
            for vrf_name in sorted(imported_vrfs):
                leaking_vrfs.append({'name': vrf_name})
    
    print(json.dumps({'success': True, 'vrfs': leaking_vrfs}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
}

# Get BGP profiles (filtered - exclude VxLAN_UNDERLAY*)
get_bgp_profiles() {
    python3 << PYTHON
import json
import yaml
import os

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
bgp_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')

profiles = []
infra_vrfs = ['default']  # Default fallback

try:
    if os.path.exists(bgp_file):
        with open(bgp_file, 'r') as f:
            data = yaml.safe_load(f) or {}
            bgp_profiles = data.get('bgp_profiles', {})
            
            # Get infra_vrfs list from config
            infra_vrfs = data.get('infra_vrfs', ['default'])
            
            for name in sorted(bgp_profiles.keys()):
                # Filter out underlay profiles
                if name.startswith('VxLAN_UNDERLAY'):
                    continue
                profiles.append({'name': name})
    
    print(json.dumps({'success': True, 'profiles': profiles, 'infra_vrfs': infra_vrfs}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
}

# ==================== VRF MANAGEMENT ====================

# Get available VRFs from all devices
get_available_vrfs() {
    python3 << PYTHON
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')

# Collect all unique VRFs from all devices
vrfs = {}

for host_file in glob.glob(os.path.join(host_vars_dir, '*.yaml')) + glob.glob(os.path.join(host_vars_dir, '*.yml')):
    hostname = os.path.basename(host_file).rsplit('.', 1)[0]
    
    try:
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
            device_vrfs = host_data.get('vrfs', {})
            
            for vrf_name, vrf_config in device_vrfs.items():
                if vrf_name not in vrfs:
                    vrfs[vrf_name] = {
                        'name': vrf_name,
                        'l3vni': vrf_config.get('l3vni'),
                        'vxlan_int': vrf_config.get('vxlan_int'),
                        'bgp_profile': vrf_config.get('bgp', {}).get('bgp_profile'),
                        'device_count': 0,
                        'devices': []
                    }
                vrfs[vrf_name]['device_count'] += 1
                vrfs[vrf_name]['devices'].append(hostname)
    except:
        pass

print(json.dumps({
    'success': True,
    'vrfs': list(vrfs.values())
}))
PYTHON
}

# Create VRF in device's host_vars
create_vrf() {
    read -r POST_DATA
    python3 << PYTHON
import json
import yaml
import os
import sys

try:
    data = json.loads('''$POST_DATA''')
except:
    data = {}

device = data.get('device')
vrf_name = data.get('vrf_name')
l3vni = data.get('l3vni')
vxlan_int = data.get('vxlan_int')
bgp_asn = data.get('bgp_asn')
bgp_profile = data.get('bgp_profile')
leaking_enabled = data.get('leaking_enabled', False)
leak_from_vrf = data.get('leak_from_vrf')

if not device or not vrf_name:
    print(json.dumps({'success': False, 'error': 'Device and VRF name are required'}))
    sys.exit(0)

if not l3vni:
    print(json.dumps({'success': False, 'error': 'L3VNI is required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
host_file = os.path.join(ansible_dir, 'inventory', 'host_vars', f'{device}.yaml')

# Try .yml if .yaml doesn't exist
if not os.path.exists(host_file):
    host_file = os.path.join(ansible_dir, 'inventory', 'host_vars', f'{device}.yml')

# If leaking is enabled, find the appropriate profiles
tenant_profile = None
shared_profile = None
leaking_configured = False

if leaking_enabled and leak_from_vrf:
    try:
        with open(bgp_profiles_file, 'r') as f:
            bgp_data = yaml.safe_load(f) or {}
            bgp_profiles = bgp_data.get('bgp_profiles', {})
            
            # Find profile that imports FROM the leak_from_vrf (this is for new tenant)
            # Find profile that imports FROM other tenants (this is for shared VRF, needs updating)
            for profile_name, profile_config in bgp_profiles.items():
                if profile_name.startswith('VxLAN_UNDERLAY'):
                    continue
                    
                ipv4_af = profile_config.get('ipv4_unicast_af', {})
                route_import = ipv4_af.get('route_import', {})
                from_vrf_list = route_import.get('from_vrf', [])
                
                if leak_from_vrf in from_vrf_list:
                    # This profile imports from leak_from_vrf -> use for new tenant
                    tenant_profile = profile_name
                elif from_vrf_list and leak_from_vrf not in from_vrf_list:
                    # This profile imports from other VRFs -> this is the shared profile
                    shared_profile = profile_name
            
            # Update the shared profile to include the new tenant
            if shared_profile and shared_profile in bgp_profiles:
                ipv4_af = bgp_profiles[shared_profile].setdefault('ipv4_unicast_af', {})
                route_import = ipv4_af.setdefault('route_import', {})
                from_vrf_list = route_import.setdefault('from_vrf', [])
                
                if vrf_name not in from_vrf_list:
                    from_vrf_list.append(vrf_name)
                    
                    # Write updated bgp_profiles.yaml
                    with open(bgp_profiles_file, 'w') as f:
                        yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
                    leaking_configured = True
            
            # Use tenant_profile if found
            if tenant_profile:
                bgp_profile = tenant_profile
                
    except Exception as e:
        print(json.dumps({'success': False, 'error': f'Failed to configure leaking: {str(e)}'}))
        sys.exit(0)

# Load existing host_vars
host_data = {}
if os.path.exists(host_file):
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}

# Initialize vrfs if not exists
if 'vrfs' not in host_data:
    host_data['vrfs'] = {}

# Check if VRF already exists
if vrf_name in host_data['vrfs']:
    print(json.dumps({'success': False, 'error': f'VRF {vrf_name} already exists on this device'}))
    sys.exit(0)

# Create VRF entry
vrf_entry = {
    'l3vni': l3vni,
    'lo': '{{ lo_ip }}'
}

if vxlan_int:
    vrf_entry['vxlan_int'] = vxlan_int

if bgp_asn or bgp_profile:
    vrf_entry['bgp'] = {}
    if bgp_asn:
        vrf_entry['bgp']['asn'] = bgp_asn
    if bgp_profile:
        vrf_entry['bgp']['bgp_profile'] = bgp_profile

host_data['vrfs'][vrf_name] = vrf_entry

# Write back
with open(host_file if os.path.exists(host_file) else os.path.join(ansible_dir, 'inventory', 'host_vars', f'{device}.yaml'), 'w') as f:
    yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)

result = {'success': True, 'vrf_name': vrf_name}
if leaking_enabled:
    result['leaking_configured'] = leaking_configured
    result['tenant_profile'] = tenant_profile
    result['shared_profile'] = shared_profile
    if not tenant_profile:
        result['warning'] = f'No profile found that imports from {leak_from_vrf}'

print(json.dumps(result))
PYTHON
}

# Create VRF on multiple devices (bulk)
create_vrf_bulk() {
    read -r POST_DATA
    python3 << PYTHON
import json
import yaml
import os
import sys
import glob

try:
    data = json.loads('''$POST_DATA''')
except:
    data = {}

devices = data.get('devices', [])
vrf_name = data.get('vrf_name')
l3vni = data.get('l3vni')
vxlan_int = data.get('vxlan_int')
bgp_profile = data.get('bgp_profile', 'OVERLAY_LEAF')
leaking_enabled = data.get('leaking_enabled', False)
leak_from_vrf = data.get('leak_from_vrf')

if not devices or not isinstance(devices, list):
    print(json.dumps({'success': False, 'error': 'No devices specified'}))
    sys.exit(0)

if not vrf_name or not l3vni:
    print(json.dumps({'success': False, 'error': 'VRF name and L3VNI are required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')
bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')

# Handle leaking profile detection
leaking_configured = False
tenant_profile = None
shared_profile = None

if leaking_enabled and leak_from_vrf:
    try:
        with open(bgp_profiles_file, 'r') as f:
            bgp_data = yaml.safe_load(f) or {}
        
        bgp_profiles = bgp_data.get('bgp_profiles', {})
        
        # Find profile that imports from leak_from_vrf (this is tenant profile)
        for profile_name, profile_config in bgp_profiles.items():
            ipv4_af = profile_config.get('ipv4_unicast_af', {})
            route_import = ipv4_af.get('route_import', {})
            from_vrf_list = route_import.get('from_vrf', [])
            if leak_from_vrf in from_vrf_list:
                tenant_profile = profile_name
                break
        
        # Find profile for shared VRF (has from_vrf list without leak_from_vrf)
        for profile_name, profile_config in bgp_profiles.items():
            ipv4_af = profile_config.get('ipv4_unicast_af', {})
            route_import = ipv4_af.get('route_import', {})
            from_vrf_list = route_import.get('from_vrf', [])
            if from_vrf_list and leak_from_vrf not in from_vrf_list:
                shared_profile = profile_name
                # Add new VRF to shared profile's from_vrf list
                from_vrf_list.append(vrf_name)
                leaking_configured = True
                break
        
        if leaking_configured:
            with open(bgp_profiles_file, 'w') as f:
                yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
        
        if tenant_profile:
            bgp_profile = tenant_profile
    except Exception as e:
        pass

# Create VRF entry
vrf_entry = {
    'l3vni': l3vni,
    'bgp_profile': bgp_profile
}

if vxlan_int:
    vrf_entry['vxlan_int'] = vxlan_int

devices_created = []

for device in devices:
    try:
        host_file = os.path.join(host_vars_dir, f'{device}.yaml')
        if not os.path.exists(host_file):
            alt_file = os.path.join(host_vars_dir, f'{device}.yml')
            if os.path.exists(alt_file):
                host_file = alt_file
        
        # Load host_vars
        host_data = {}
        if os.path.exists(host_file):
            with open(host_file, 'r') as f:
                host_data = yaml.safe_load(f) or {}
        
        # Get device's BGP ASN
        device_asn = None
        bgp_config = host_data.get('bgp', {})
        if isinstance(bgp_config, dict):
            device_asn = bgp_config.get('asn')
        
        # Initialize vrfs if not exists
        if 'vrfs' not in host_data:
            host_data['vrfs'] = {}
        
        # Create device-specific VRF entry with its own ASN
        device_vrf_entry = vrf_entry.copy()
        if device_asn:
            device_vrf_entry['bgp_asn'] = device_asn
        
        host_data['vrfs'][vrf_name] = device_vrf_entry
        
        # Write back
        target_file = host_file if os.path.exists(host_file) else os.path.join(host_vars_dir, f'{device}.yaml')
        with open(target_file, 'w') as f:
            yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
        
        devices_created.append(device)
    except Exception as e:
        pass  # Skip failed devices

result = {
    'success': True,
    'vrf_name': vrf_name,
    'devices_created': len(devices_created),
    'devices_list': devices_created
}

if leaking_enabled:
    result['leaking_configured'] = leaking_configured
    result['tenant_profile'] = tenant_profile
    result['shared_profile'] = shared_profile
    if not tenant_profile:
        result['warning'] = f'No profile found that imports from {leak_from_vrf}'

print(json.dumps(result))
PYTHON
}

# Assign VRFs to device
assign_vrfs() {
    read -r POST_DATA
    python3 << PYTHON
import json
import yaml
import os
import sys
import glob

try:
    data = json.loads('''$POST_DATA''')
except:
    data = {}

device = data.get('device')
vrf_names = data.get('vrfs', [])

if not device or not vrf_names:
    print(json.dumps({'success': False, 'error': 'Device and VRF names are required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')
host_file = os.path.join(host_vars_dir, f'{device}.yaml')

# Try .yml if .yaml doesn't exist
if not os.path.exists(host_file):
    alt_file = os.path.join(host_vars_dir, f'{device}.yml')
    if os.path.exists(alt_file):
        host_file = alt_file

# Load existing host_vars
host_data = {}
if os.path.exists(host_file):
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}

# Initialize vrfs if not exists
if 'vrfs' not in host_data:
    host_data['vrfs'] = {}

# Find VRF configs from other devices
all_vrf_configs = {}
for hf in glob.glob(os.path.join(host_vars_dir, '*.yaml')) + glob.glob(os.path.join(host_vars_dir, '*.yml')):
    try:
        with open(hf, 'r') as f:
            hd = yaml.safe_load(f) or {}
            for vrf_name, vrf_config in hd.get('vrfs', {}).items():
                if vrf_name not in all_vrf_configs:
                    all_vrf_configs[vrf_name] = vrf_config
    except:
        pass

# Add VRFs
added = []
for vrf_name in vrf_names:
    if vrf_name not in host_data['vrfs']:
        if vrf_name in all_vrf_configs:
            host_data['vrfs'][vrf_name] = all_vrf_configs[vrf_name]
            added.append(vrf_name)
        else:
            # Create minimal VRF entry
            host_data['vrfs'][vrf_name] = {'l3vni': None}
            added.append(vrf_name)

# Write back
with open(host_file, 'w') as f:
    yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)

print(json.dumps({'success': True, 'added': added}))
PYTHON
}

# Unassign VRF from device
unassign_vrf() {
    read -r POST_DATA
    python3 << PYTHON
import json
import yaml
import os
import sys

try:
    data = json.loads('''$POST_DATA''')
except:
    data = {}

device = data.get('device')
vrf_name = data.get('vrf')

if not device or not vrf_name:
    print(json.dumps({'success': False, 'error': 'Device and VRF name are required'}))
    sys.exit(0)

if vrf_name == 'default':
    print(json.dumps({'success': False, 'error': 'Cannot remove default VRF'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')
bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
host_file = os.path.join(host_vars_dir, f'{device}.yaml')

# Try .yml if .yaml doesn't exist
if not os.path.exists(host_file):
    alt_file = os.path.join(host_vars_dir, f'{device}.yml')
    if os.path.exists(alt_file):
        host_file = alt_file

if not os.path.exists(host_file):
    print(json.dumps({'success': False, 'error': 'Host vars file not found'}))
    sys.exit(0)

# Load host_vars
with open(host_file, 'r') as f:
    host_data = yaml.safe_load(f) or {}

if 'vrfs' not in host_data or vrf_name not in host_data['vrfs']:
    print(json.dumps({'success': False, 'error': f'VRF {vrf_name} not found in device config'}))
    sys.exit(0)

# Remove VRF
del host_data['vrfs'][vrf_name]

# Write back host_vars
with open(host_file, 'w') as f:
    yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)

# Check if any other devices still have this VRF
import glob
remaining_devices = 0
for hf in glob.glob(os.path.join(host_vars_dir, '*.yaml')) + glob.glob(os.path.join(host_vars_dir, '*.yml')):
    try:
        with open(hf, 'r') as f:
            hd = yaml.safe_load(f) or {}
        if vrf_name in hd.get('vrfs', {}):
            remaining_devices += 1
    except:
        pass

# Only remove VRF from bgp_profiles.yaml if this was the LAST device
leaking_removed = False
if remaining_devices == 0:
    try:
        if os.path.exists(bgp_profiles_file):
            with open(bgp_profiles_file, 'r') as f:
                bgp_data = yaml.safe_load(f) or {}
            
            bgp_profiles = bgp_data.get('bgp_profiles', {})
            modified = False
            
            for profile_name, profile_config in bgp_profiles.items():
                ipv4_af = profile_config.get('ipv4_unicast_af', {})
                route_import = ipv4_af.get('route_import', {})
                from_vrf_list = route_import.get('from_vrf', [])
                
                if vrf_name in from_vrf_list:
                    from_vrf_list.remove(vrf_name)
                    modified = True
                    leaking_removed = True
            
            if modified:
                with open(bgp_profiles_file, 'w') as f:
                    yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
    except:
        pass  # Don't fail if bgp_profiles update fails

print(json.dumps({'success': True, 'leaking_removed': leaking_removed, 'remaining_devices': remaining_devices}))
PYTHON
}

# Delete VRF globally (from all devices)
delete_vrf_global() {
    read -r POST_DATA
    python3 << PYTHON
import json
import yaml
import os
import sys
import glob

try:
    data = json.loads('''$POST_DATA''')
except:
    data = {}

vrf_name = data.get('vrf_name')

if not vrf_name:
    print(json.dumps({'success': False, 'error': 'VRF name is required'}))
    sys.exit(0)

if vrf_name == 'default':
    print(json.dumps({'success': False, 'error': 'Cannot delete default VRF'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')
bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')

devices_updated = []

# Remove VRF from all host_vars files
for host_file in glob.glob(os.path.join(host_vars_dir, '*.yaml')) + glob.glob(os.path.join(host_vars_dir, '*.yml')):
    try:
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
        
        if 'vrfs' in host_data and vrf_name in host_data['vrfs']:
            del host_data['vrfs'][vrf_name]
            with open(host_file, 'w') as f:
                yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
            hostname = os.path.basename(host_file).replace('.yaml', '').replace('.yml', '')
            devices_updated.append(hostname)
    except:
        pass

# Remove VRF from bgp_profiles.yaml (leaking references)
leaking_removed = False
try:
    if os.path.exists(bgp_profiles_file):
        with open(bgp_profiles_file, 'r') as f:
            bgp_data = yaml.safe_load(f) or {}
        
        bgp_profiles = bgp_data.get('bgp_profiles', {})
        modified = False
        
        for profile_name, profile_config in bgp_profiles.items():
            ipv4_af = profile_config.get('ipv4_unicast_af', {})
            route_import = ipv4_af.get('route_import', {})
            from_vrf_list = route_import.get('from_vrf', [])
            
            if vrf_name in from_vrf_list:
                from_vrf_list.remove(vrf_name)
                modified = True
                leaking_removed = True
        
        if modified:
            with open(bgp_profiles_file, 'w') as f:
                yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
except:
    pass

print(json.dumps({
    'success': True,
    'devices_updated': devices_updated,
    'leaking_removed': leaking_removed
}))
PYTHON
}

# Get VRF report - VRFs with device assignments
get_vrf_report() {
    python3 << PYTHON
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')

# Collect all VRFs from all devices
vrfs = {}
unique_devices = set()

for host_file in glob.glob(os.path.join(host_vars_dir, '*.yaml')) + glob.glob(os.path.join(host_vars_dir, '*.yml')):
    hostname = os.path.basename(host_file).rsplit('.', 1)[0]
    
    try:
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
            device_vrfs = host_data.get('vrfs', {})
            
            if device_vrfs:
                unique_devices.add(hostname)
            
            for vrf_name, vrf_config in device_vrfs.items():
                if vrf_name not in vrfs:
                    vrfs[vrf_name] = {
                        'name': vrf_name,
                        'l3vni': vrf_config.get('l3vni'),
                        'vxlan_int': vrf_config.get('vxlan_int'),
                        'bgp_profile': vrf_config.get('bgp', {}).get('bgp_profile') if vrf_config.get('bgp') else None,
                        'devices': []
                    }
                vrfs[vrf_name]['devices'].append(hostname)
    except:
        pass

print(json.dumps({
    'success': True,
    'vrfs': vrfs,
    'device_count': len(unique_devices)
}))
PYTHON
}

# Get VLAN report - VLANs with device assignments
get_vlan_report() {
    python3 << PYTHON
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
inventory_base = os.path.join(ansible_dir, 'inventory')
vlan_file = os.path.join(inventory_base, 'group_vars', 'all', 'vlan_profiles.yaml')
host_vars_dir = os.path.join(inventory_base, 'host_vars')

# Load VLAN profiles
vlan_profiles = {}
vrfs = set()

if os.path.exists(vlan_file):
    with open(vlan_file, 'r') as f:
        data = yaml.safe_load(f) or {}
        vlan_profiles = data.get('vlan_profiles', {})

# Collect VRFs from VLAN profiles
for vlan_name, vlan_data in vlan_profiles.items():
    if vlan_data and 'vlans' in vlan_data:
        for vid, vinfo in vlan_data['vlans'].items():
            if vinfo and vinfo.get('vrf'):
                vrfs.add(vinfo['vrf'])

# Build VLAN to device mapping and collect unique devices
vlan_device_map = {vlan_name: [] for vlan_name in vlan_profiles.keys()}
unique_devices = set()

# Scan all host_vars files for vlan_templates
for host_file in glob.glob(os.path.join(host_vars_dir, '*.yaml')) + glob.glob(os.path.join(host_vars_dir, '*.yml')):
    hostname = os.path.basename(host_file).rsplit('.', 1)[0]
    
    try:
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
            vlan_templates = host_data.get('vlan_templates', [])
            
            if vlan_templates:
                unique_devices.add(hostname)
            
            for vlan_name in vlan_templates:
                if vlan_name in vlan_device_map:
                    vlan_device_map[vlan_name].append(hostname)
                else:
                    vlan_device_map[vlan_name] = [hostname]
    except:
        pass

print(json.dumps({
    'success': True,
    'vlan_profiles': vlan_profiles,
    'vlan_device_map': vlan_device_map,
    'device_count': len(unique_devices),
    'vrf_count': len(vrfs)
}))
PYTHON
}

# Get port profiles
get_port_profiles() {
    local port_file="$ANSIBLE_DIR/inventory/group_vars/all/sw_port_profiles.yaml"
    
    if [[ ! -f "$port_file" ]]; then
        echo '{"success": false, "error": "Port profiles file not found"}'
        return
    fi
    
    python3 << PYTHON
import json
import yaml
import os

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
port_file = f"{ansible_dir}/inventory/group_vars/all/sw_port_profiles.yaml"

try:
    with open(port_file, 'r') as f:
        config = yaml.safe_load(f) or {}
    
    print(json.dumps({
        'success': True,
        'port_profiles': config.get('sw_port_profiles', {})
    }))

except Exception as e:
    print(json.dumps({
        'success': False,
        'error': str(e)
    }))
PYTHON
}

# Create VLAN - adds to vlan_profiles.yaml and sw_port_profiles.yaml
create_vlan() {
    # Read POST data
    local post_data
    read -r post_data
    
    python3 << PYTHON
import json
import yaml
import os
import sys
from datetime import datetime

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
vlan_profiles_file = f"{ansible_dir}/inventory/group_vars/all/vlan_profiles.yaml"
port_profiles_file = f"{ansible_dir}/inventory/group_vars/all/sw_port_profiles.yaml"

try:
    # Parse POST data
    post_data = '''$post_data'''
    data = json.loads(post_data)
    
    vlan_id = int(data.get('vlan_id'))
    profile_name = data.get('profile_name', f'VLAN_{vlan_id}')
    description = data.get('description', '')
    l2vni = data.get('l2vni', 100000 + vlan_id)
    stp_bpduguard = data.get('stp_bpduguard', True)
    
    # SVI/L3 configuration
    svi_enabled = data.get('svi_enabled', False)
    vrf = data.get('vrf', 'default') if svi_enabled else None
    vrr_enabled = data.get('vrr_enabled', False) if svi_enabled else False
    vrr_vip = data.get('vrr_vip', '')
    even_ip = data.get('even_ip', '')
    odd_ip = data.get('odd_ip', '')
    gateway_ip = data.get('gateway_ip', '')
    
    # Validate VLAN ID
    if vlan_id < 1 or vlan_id > 4094:
        print(json.dumps({'success': False, 'error': 'VLAN ID must be between 1 and 4094'}))
        sys.exit(0)
    
    # Load existing vlan_profiles
    vlan_config = {}
    if os.path.exists(vlan_profiles_file):
        with open(vlan_profiles_file, 'r') as f:
            vlan_config = yaml.safe_load(f) or {}
    
    if 'vlan_profiles' not in vlan_config:
        vlan_config['vlan_profiles'] = {}
    
    # Check if VLAN profile already exists
    if profile_name in vlan_config['vlan_profiles']:
        print(json.dumps({'success': False, 'error': f'VLAN profile {profile_name} already exists'}))
        sys.exit(0)
    
    # Check if VLAN ID already used
    for pname, pdata in vlan_config['vlan_profiles'].items():
        if pdata and 'vlans' in pdata:
            if vlan_id in pdata['vlans'] or str(vlan_id) in pdata['vlans']:
                print(json.dumps({'success': False, 'error': f'VLAN ID {vlan_id} already exists in profile {pname}'}))
                sys.exit(0)
    
    # Build VLAN entry
    vlan_entry = {
        'description': description,
        'l2vni': l2vni
    }
    
    # Add VRF and IP info only if SVI is enabled
    if svi_enabled:
        vlan_entry['vrf'] = vrf
        vlan_entry['ipv6'] = False  # Always disabled
        
        if vrr_enabled:
            # VRR mode with VIP and Even/Odd IPs
            if vrr_vip:
                vlan_entry['vrr_vip'] = vrr_vip
            if even_ip:
                vlan_entry['even_ip'] = even_ip
            if odd_ip:
                vlan_entry['odd_ip'] = odd_ip
        else:
            # Single gateway IP mode
            if gateway_ip:
                vlan_entry['ip'] = gateway_ip
    
    # Build profile entry
    profile_entry = {
        'vrr': {'state': vrr_enabled if svi_enabled else False},
        'vlans': {vlan_id: vlan_entry}
    }
    
    # Add to vlan_profiles
    vlan_config['vlan_profiles'][profile_name] = profile_entry
    
    # Write vlan_profiles.yaml
    with open(vlan_profiles_file, 'w') as f:
        yaml.dump(vlan_config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    
    # Load existing port_profiles
    port_config = {}
    if os.path.exists(port_profiles_file):
        with open(port_profiles_file, 'r') as f:
            port_config = yaml.safe_load(f) or {}
    
    if 'sw_port_profiles' not in port_config:
        port_config['sw_port_profiles'] = {}
    
    # Create ACCESS_VLAN_{id} profile
    access_profile_name = f'ACCESS_VLAN_{vlan_id}'
    if access_profile_name not in port_config['sw_port_profiles']:
        port_config['sw_port_profiles'][access_profile_name] = {
            'description': description,
            'sw_port_mode': 'access',
            'access_vlan': vlan_id,
            'stp_bpduguard': stp_bpduguard
        }
        
        # Write port_profiles.yaml
        with open(port_profiles_file, 'w') as f:
            yaml.dump(port_config, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
    
    print(json.dumps({
        'success': True,
        'message': f'VLAN {vlan_id} created successfully',
        'vlan_profile': profile_name,
        'port_profile': access_profile_name
    }))

except json.JSONDecodeError as e:
    print(json.dumps({'success': False, 'error': f'Invalid JSON: {str(e)}'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
}

# Get list of VRFs for dropdown
get_vrfs() {
    python3 << 'PYTHON'
import json
import yaml
import os

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
vlan_profiles_file = f"{ansible_dir}/inventory/group_vars/all/vlan_profiles.yaml"

vrfs = set(['default'])

try:
    # Check vxlan_int mapping for VRF names
    if os.path.exists(vlan_profiles_file):
        with open(vlan_profiles_file, 'r') as f:
            config = yaml.safe_load(f) or {}
        
        # Get VRFs from vxlan_int mapping
        if 'vxlan_int' in config:
            vrfs.update(config['vxlan_int'].keys())
        
        # Get VRFs from vlan_profiles
        if 'vlan_profiles' in config:
            for profile in config['vlan_profiles'].values():
                if profile and 'vlans' in profile:
                    for vlan in profile['vlans'].values():
                        if vlan and 'vrf' in vlan:
                            vrfs.add(vlan['vrf'])
    
    print(json.dumps({
        'success': True,
        'vrfs': sorted(list(vrfs))
    }))

except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
}

delete_vlan() {
    # Read POST data
    local post_data
    read -r post_data

    python3 << PYTHON
import json
import yaml
import os
import sys

# Parse POST data
post_data = '''$post_data'''
data = json.loads(post_data)

profile_name = data.get('profile_name', '')

if not profile_name:
    print(json.dumps({'success': False, 'error': 'Profile name is required'}))
    sys.exit(0)

# Paths
ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
inventory_base = os.path.join(ansible_dir, 'inventory')
vlan_profiles_file = os.path.join(inventory_base, 'group_vars', 'all', 'vlan_profiles.yaml')
port_profiles_file = os.path.join(inventory_base, 'group_vars', 'all', 'sw_port_profiles.yaml')

# Load vlan_profiles
vlan_config = {}
if os.path.exists(vlan_profiles_file):
    with open(vlan_profiles_file, 'r') as f:
        vlan_config = yaml.safe_load(f) or {}

if 'vlan_profiles' not in vlan_config or profile_name not in vlan_config['vlan_profiles']:
    print(json.dumps({'success': False, 'error': f'VLAN profile {profile_name} not found'}))
    sys.exit(0)

# Get VLAN ID for port profile name
vlan_id = None
profile_data = vlan_config['vlan_profiles'][profile_name]
if profile_data and 'vlans' in profile_data:
    vlan_ids = list(profile_data['vlans'].keys())
    if vlan_ids:
        vlan_id = vlan_ids[0]

# Delete from vlan_profiles
del vlan_config['vlan_profiles'][profile_name]

# Save vlan_profiles
with open(vlan_profiles_file, 'w') as f:
    yaml.dump(vlan_config, f, default_flow_style=False, sort_keys=False)

# Try to delete corresponding port profile
port_profile_deleted = False
port_profile_name = None
if vlan_id:
    port_profile_name = f'ACCESS_VLAN_{vlan_id}'
    
    port_config = {}
    if os.path.exists(port_profiles_file):
        with open(port_profiles_file, 'r') as f:
            port_config = yaml.safe_load(f) or {}
    
    if 'sw_port_profiles' in port_config and port_profile_name in port_config['sw_port_profiles']:
        del port_config['sw_port_profiles'][port_profile_name]
        
        with open(port_profiles_file, 'w') as f:
            yaml.dump(port_config, f, default_flow_style=False, sort_keys=False)
        
        port_profile_deleted = True

print(json.dumps({
    'success': True,
    'profile_name': profile_name,
    'port_profile': port_profile_name,
    'port_profile_deleted': port_profile_deleted
}))
PYTHON
}

assign_vlans() {
    # Read POST data
    local post_data
    read -r post_data

    python3 << PYTHON
import json
import yaml
import os
import sys

# Parse POST data
post_data = '''$post_data'''
data = json.loads(post_data)

device = data.get('device', '')
vlans = data.get('vlans', [])

if not device:
    print(json.dumps({'success': False, 'error': 'Device name is required'}))
    sys.exit(0)

if not vlans:
    print(json.dumps({'success': False, 'error': 'No VLANs selected'}))
    sys.exit(0)

# Path to host_vars
ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
inventory_base = os.path.join(ansible_dir, 'inventory')
host_vars_file = os.path.join(inventory_base, 'host_vars', device + '.yaml')

if not os.path.exists(host_vars_file):
    # Also try without .yaml
    host_vars_file = os.path.join(inventory_base, 'host_vars', device + '.yml')

# Load host_vars or create empty config
host_config = {}
if os.path.exists(host_vars_file):
    with open(host_vars_file, 'r') as f:
        host_config = yaml.safe_load(f) or {}
else:
    # Create new file with .yaml extension
    host_vars_file = os.path.join(inventory_base, 'host_vars', device + '.yaml')

# Add VLANs to vlan_templates
if 'vlan_templates' not in host_config:
    host_config['vlan_templates'] = []

# Add new VLANs (avoid duplicates)
added = []
for vlan in vlans:
    if vlan not in host_config['vlan_templates']:
        host_config['vlan_templates'].append(vlan)
        added.append(vlan)

# Save host_vars
with open(host_vars_file, 'w') as f:
    yaml.dump(host_config, f, default_flow_style=False, sort_keys=False)

print(json.dumps({
    'success': True,
    'device': device,
    'added_vlans': added,
    'total_vlans': len(host_config['vlan_templates'])
}))
PYTHON
}

unassign_vlan() {
    # Read POST data
    local post_data
    read -r post_data

    python3 << PYTHON
import json
import yaml
import os
import sys

# Parse POST data
post_data = '''$post_data'''
data = json.loads(post_data)

device = data.get('device', '')
vlan = data.get('vlan', '')

if not device:
    print(json.dumps({'success': False, 'error': 'Device name is required'}))
    sys.exit(0)

if not vlan:
    print(json.dumps({'success': False, 'error': 'VLAN name is required'}))
    sys.exit(0)

# Path to host_vars
ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
inventory_base = os.path.join(ansible_dir, 'inventory')
host_vars_file = os.path.join(inventory_base, 'host_vars', device + '.yaml')

# Try .yaml first, then .yml
if not os.path.exists(host_vars_file):
    host_vars_file = os.path.join(inventory_base, 'host_vars', device + '.yml')

# Load host_vars (create empty if doesn't exist)
host_config = {}
if os.path.exists(host_vars_file):
    with open(host_vars_file, 'r') as f:
        host_config = yaml.safe_load(f) or {}
else:
    # File doesn't exist - check if we should create it
    # Use .yaml extension for new files
    host_vars_file = os.path.join(inventory_base, 'host_vars', device + '.yaml')
    host_config = {}

# Check if VLAN is in vlan_templates
if 'vlan_templates' not in host_config or vlan not in host_config.get('vlan_templates', []):
    print(json.dumps({'success': False, 'error': f'VLAN {vlan} not found in device config (may be inherited from group_vars)'}))
    sys.exit(0)

# Remove VLAN from vlan_templates
host_config['vlan_templates'].remove(vlan)

# Save host_vars
with open(host_vars_file, 'w') as f:
    yaml.dump(host_config, f, default_flow_style=False, sort_keys=False)

print(json.dumps({
    'success': True,
    'device': device,
    'removed_vlan': vlan
}))
PYTHON
}

update_vlan() {
    # Read POST data
    local post_data
    read -r post_data

    python3 << PYTHON
import json
import yaml
import os
import sys

# Parse POST data
post_data = '''$post_data'''
data = json.loads(post_data)

original_name = data.get('original_name', '')
profile_name = data.get('profile_name', original_name)
vlan_id = data.get('vlan_id')
description = data.get('description', '')
l2vni = data.get('l2vni')
svi_enabled = data.get('svi_enabled', False)
vrr_enabled = data.get('vrr_enabled', False)
vrf = data.get('vrf', 'default')
vrr_vip = data.get('vrr_vip', '')
even_ip = data.get('even_ip', '')
odd_ip = data.get('odd_ip', '')
gateway_ip = data.get('gateway_ip', '')

if not original_name:
    print(json.dumps({'success': False, 'error': 'Original profile name is required'}))
    sys.exit(0)

# Paths
ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
inventory_base = os.path.join(ansible_dir, 'inventory')
vlan_profiles_file = os.path.join(inventory_base, 'group_vars', 'all', 'vlan_profiles.yaml')

# Load vlan_profiles
vlan_config = {}
if os.path.exists(vlan_profiles_file):
    with open(vlan_profiles_file, 'r') as f:
        vlan_config = yaml.safe_load(f) or {}

if 'vlan_profiles' not in vlan_config or original_name not in vlan_config['vlan_profiles']:
    print(json.dumps({'success': False, 'error': f'VLAN profile {original_name} not found'}))
    sys.exit(0)

# Get existing profile data
existing = vlan_config['vlan_profiles'][original_name]

# Build updated VLAN entry
vlan_entry = {
    'description': description,
    'l2vni': l2vni if l2vni else existing.get('vlans', {}).get(vlan_id, {}).get('l2vni', 100000 + vlan_id)
}

if svi_enabled:
    vlan_entry['vrf'] = vrf
    vlan_entry['ipv6'] = False
    
    if vrr_enabled:
        if vrr_vip:
            vlan_entry['vrr_vip'] = vrr_vip
        if even_ip:
            vlan_entry['even_ip'] = even_ip
        if odd_ip:
            vlan_entry['odd_ip'] = odd_ip
    else:
        if gateway_ip:
            vlan_entry['ip'] = gateway_ip

# Update profile
profile_entry = {
    'vrr': {'state': vrr_enabled if svi_enabled else False},
    'vlans': {vlan_id: vlan_entry}
}

# If profile name changed, remove old and add new
if profile_name != original_name:
    del vlan_config['vlan_profiles'][original_name]

vlan_config['vlan_profiles'][profile_name] = profile_entry

# Save
with open(vlan_profiles_file, 'w') as f:
    yaml.dump(vlan_config, f, default_flow_style=False, sort_keys=False)

print(json.dumps({
    'success': True,
    'profile_name': profile_name,
    'renamed': profile_name != original_name
}))
PYTHON
}

# Main handler
parse_query

case "$ACTION" in
    "list-devices")
        list_devices
        ;;
    "get-device")
        get_device "$HOSTNAME"
        ;;
    "get-vlan-profiles")
        get_vlan_profiles
        ;;
    "get-vlan-report")
        get_vlan_report
        ;;
    "get-port-profiles")
        get_port_profiles
        ;;
    "get-vrfs")
        get_vrfs
        ;;
    "create-vlan")
        create_vlan
        ;;
    "delete-vlan")
        delete_vlan
        ;;
    "assign-vlans")
        assign_vlans
        ;;
    "unassign-vlan")
        unassign_vlan
        ;;
    "update-vlan")
        update_vlan
        ;;
    "bulk-create-vlans")
        bulk_create_vlans
        ;;
    "get-available-vrfs")
        get_available_vrfs
        ;;
    "get-bgp-profiles")
        get_bgp_profiles
        ;;
    "get-leaking-vrfs")
        get_leaking_vrfs
        ;;
    "create-vrf")
        create_vrf
        ;;
    "create-vrf-bulk")
        create_vrf_bulk
        ;;
    "assign-vrfs")
        assign_vrfs
        ;;
    "unassign-vrf")
        unassign_vrf
        ;;
    "delete-vrf-global")
        delete_vrf_global
        ;;
    "get-vrf-report")
        get_vrf_report
        ;;
    "get-all-leaked-subnets")
        # Get all leaked subnets with their target VRFs
        python3 << 'PYTHON'
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = f"{ansible_dir}/inventory/host_vars"
bgp_file = f"{ansible_dir}/inventory/group_vars/all/bgp_profiles.yaml"

try:
    with open(bgp_file, 'r') as f:
        bgp_data = yaml.safe_load(f)
    
    profiles = bgp_data.get('bgp_profiles', {})
    route_map_to_target = {}
    
    # Scan devices to find route_map -> target_vrf mapping
    for yaml_file in glob.glob(f"{host_vars_dir}/*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                device_data = yaml.safe_load(f)
            if not device_data:
                continue
            vrfs = device_data.get('vrfs', {})
            for vrf_name, vrf_config in vrfs.items():
                if isinstance(vrf_config, dict):
                    bgp = vrf_config.get('bgp', {})
                    bgp_profile = bgp.get('bgp_profile', '')
                    if bgp_profile in profiles:
                        profile = profiles[bgp_profile]
                        ipv4_af = profile.get('ipv4_unicast_af', {})
                        route_import = ipv4_af.get('route_import', {})
                        route_map = route_import.get('route_map', '')
                        if route_map and route_map not in route_map_to_target:
                            route_map_to_target[route_map] = vrf_name
        except:
            continue
    
    # Collect all leaked subnets
    leaked_subnets = {}  # subnet -> {target_vrf, route_map}
    
    for yaml_file in glob.glob(f"{host_vars_dir}/*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                device_data = yaml.safe_load(f)
            if not device_data:
                continue
            
            policies = device_data.get('policies', {})
            prefix_lists = policies.get('prefix_list', {})
            
            for pl_name, pl_entries in prefix_lists.items():
                if pl_name in route_map_to_target:
                    target_vrf = route_map_to_target[pl_name]
                    for seq, entry in pl_entries.items():
                        subnet = entry.get('match', '')
                        if subnet and subnet not in leaked_subnets:
                            leaked_subnets[subnet] = {
                                'target_vrf': target_vrf,
                                'route_map': pl_name
                            }
        except:
            continue
    
    print(json.dumps({'success': True, 'leaked_subnets': leaked_subnets}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "check-subnet-leak")
        # Check if a subnet is already leaked to any VRF
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import glob

try:
    params = json.loads('''$POST_DATA''')
except:
    params = {}

subnet = params.get('subnet', '')

if not subnet:
    print(json.dumps({'success': False, 'error': 'Missing subnet'}))
    exit()

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = f"{ansible_dir}/inventory/host_vars"
bgp_file = f"{ansible_dir}/inventory/group_vars/all/bgp_profiles.yaml"

# Build route_map -> target_vrf mapping from bgp_profiles
try:
    with open(bgp_file, 'r') as f:
        bgp_data = yaml.safe_load(f)
    
    profiles = bgp_data.get('bgp_profiles', {})
    route_map_to_target = {}  # route_map -> source_vrf (the VRF that imports)
    
    for profile_name, profile in profiles.items():
        ipv4_af = profile.get('ipv4_unicast_af', {})
        route_import = ipv4_af.get('route_import', {})
        from_vrfs = route_import.get('from_vrf', [])
        route_map = route_import.get('route_map', '')
        if route_map and from_vrfs:
            # This profile imports from these VRFs using this route_map
            # We need to find which VRF uses this profile
            pass
    
    # Scan devices to find route_map -> target_vrf
    for yaml_file in glob.glob(f"{host_vars_dir}/*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                device_data = yaml.safe_load(f)
            if not device_data:
                continue
            vrfs = device_data.get('vrfs', {})
            for vrf_name, vrf_config in vrfs.items():
                if isinstance(vrf_config, dict):
                    bgp = vrf_config.get('bgp', {})
                    bgp_profile = bgp.get('bgp_profile', '')
                    if bgp_profile in profiles:
                        profile = profiles[bgp_profile]
                        ipv4_af = profile.get('ipv4_unicast_af', {})
                        route_import = ipv4_af.get('route_import', {})
                        route_map = route_import.get('route_map', '')
                        if route_map:
                            route_map_to_target[route_map] = vrf_name
        except:
            continue
    
    # Now check if subnet exists in any prefix-list
    leaked_to = None
    route_map_found = None
    
    for yaml_file in glob.glob(f"{host_vars_dir}/*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                device_data = yaml.safe_load(f)
            if not device_data:
                continue
            
            policies = device_data.get('policies', {})
            prefix_lists = policies.get('prefix_list', {})
            
            for pl_name, pl_entries in prefix_lists.items():
                for seq, entry in pl_entries.items():
                    if entry.get('match') == subnet:
                        route_map_found = pl_name
                        if pl_name in route_map_to_target:
                            leaked_to = route_map_to_target[pl_name]
                        break
                if leaked_to:
                    break
            if leaked_to:
                break
        except:
            continue
    
    print(json.dumps({
        'success': True,
        'leaked': leaked_to is not None,
        'target_vrf': leaked_to,
        'route_map': route_map_found
    }))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "get-leaking-targets")
        # Get VRFs that can receive leaked routes (from a source VRF)
        python3 << 'PYTHON'
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
bgp_file = f"{ansible_dir}/inventory/group_vars/all/bgp_profiles.yaml"
host_vars_dir = f"{ansible_dir}/inventory/host_vars"

try:
    with open(bgp_file, 'r') as f:
        data = yaml.safe_load(f)
    
    profiles = data.get('bgp_profiles', {})
    
    # Build profile -> route_map mapping
    profile_route_map = {}
    for profile_name, profile in profiles.items():
        ipv4_af = profile.get('ipv4_unicast_af', {})
        route_import = ipv4_af.get('route_import', {})
        from_vrfs = route_import.get('from_vrf', [])
        route_map = route_import.get('route_map', '')
        if from_vrfs and route_map:
            profile_route_map[profile_name] = {
                'from_vrfs': from_vrfs,
                'route_map': route_map
            }
    
    # Scan host_vars to find which VRF uses which profile
    vrf_profile_map = {}  # vrf_name -> profile_name
    for yaml_file in glob.glob(f"{host_vars_dir}/*.yaml"):
        try:
            with open(yaml_file, 'r') as f:
                device_data = yaml.safe_load(f)
            if not device_data:
                continue
            vrfs = device_data.get('vrfs', {})
            for vrf_name, vrf_config in vrfs.items():
                if isinstance(vrf_config, dict):
                    bgp = vrf_config.get('bgp', {})
                    bgp_profile = bgp.get('bgp_profile', '')
                    if bgp_profile and bgp_profile in profile_route_map:
                        vrf_profile_map[vrf_name] = bgp_profile
        except:
            continue
    
    # Build leaking_map: source_vrf -> [target_vrfs with route_map]
    leaking_map = {}
    for vrf_name, profile_name in vrf_profile_map.items():
        if profile_name in profile_route_map:
            info = profile_route_map[profile_name]
            for src_vrf in info['from_vrfs']:
                if src_vrf not in leaking_map:
                    leaking_map[src_vrf] = []
                # Check if this target VRF is already added
                existing = [x for x in leaking_map[src_vrf] if x['target_vrf'] == vrf_name]
                if not existing:
                    leaking_map[src_vrf].append({
                        'target_vrf': vrf_name,
                        'route_map': info['route_map']
                    })
    
    print(json.dumps({'success': True, 'leaking_map': leaking_map}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "add-subnet-leak")
        # Add a subnet to prefix-list for leaking
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys
import glob

# Read POST data
try:
    params = json.loads('''$POST_DATA''')
except:
    params = {}

subnet = params.get('subnet', '')
route_map = params.get('route_map', '')

if not subnet or not route_map:
    print(json.dumps({'success': False, 'error': 'Missing subnet or route_map'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = f"{ansible_dir}/inventory/host_vars"

# Find all devices that have this prefix_list and add the subnet
devices_updated = []
errors = []

try:
    for yaml_file in glob.glob(f"{host_vars_dir}/*.yaml"):
        hostname = os.path.basename(yaml_file).replace('.yaml', '')
        
        with open(yaml_file, 'r') as f:
            content = f.read()
            device_data = yaml.safe_load(content)
        
        if not device_data:
            continue
        
        policies = device_data.get('policies', {})
        prefix_lists = policies.get('prefix_list', {})
        
        if route_map not in prefix_lists:
            continue
        
        # This device has the prefix_list, add the subnet
        prefix_list = prefix_lists[route_map]
        
        # Find the next sequence number (increment by 10)
        existing_seqs = [int(seq) for seq in prefix_list.keys()]
        next_seq = str(max(existing_seqs) + 10) if existing_seqs else "10"
        
        # Check if subnet already exists
        subnet_exists = any(
            entry.get('match') == subnet 
            for entry in prefix_list.values()
        )
        
        if subnet_exists:
            continue
        
        # Add the new entry
        prefix_list[next_seq] = {
            'match': subnet,
            'max_prefix_len': 32
        }
        
        # Write back
        with open(yaml_file, 'w') as f:
            yaml.dump(device_data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)
        
        devices_updated.append(hostname)
    
    print(json.dumps({
        'success': True,
        'devices_updated': devices_updated,
        'count': len(devices_updated),
        'message': f"Subnet {subnet} added to prefix-list {route_map} on {len(devices_updated)} device(s)"
    }))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "save-dhcp-relay")
        # Save (create or update) DHCP relay entry
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys

try:
    params = json.loads('''$POST_DATA''')
except:
    params = {}

device = params.get('device', '')
index = params.get('index')  # None for create, number for update
vrf = params.get('vrf', '')
interfaces = params.get('interfaces', [])
servers = params.get('servers', [])
upstream = params.get('upstream', [])
giaddr = params.get('giaddr', '')  # Optional gateway interface

if not device or not vrf:
    print(json.dumps({'success': False, 'error': 'Device and VRF are required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = f"{ansible_dir}/inventory/host_vars"
host_file = f"{host_vars_dir}/{device}.yaml"

# Try .yml if .yaml doesn't exist
if not os.path.exists(host_file):
    alt_file = f"{host_vars_dir}/{device}.yml"
    if os.path.exists(alt_file):
        host_file = alt_file

try:
    # Load host_vars
    host_data = {}
    if os.path.exists(host_file):
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
    
    # Initialize dhcp_relay if not exists
    if 'dhcp_relay' not in host_data:
        host_data['dhcp_relay'] = []
    
    # Build relay entry
    relay_entry = {
        'vrf': vrf,
        'interfaces': interfaces,
        'servers': servers
    }
    if upstream:
        relay_entry['upstream'] = upstream
    if giaddr:
        relay_entry['giaddr'] = giaddr
    
    if index is not None and isinstance(index, int) and 0 <= index < len(host_data['dhcp_relay']):
        # Update existing
        host_data['dhcp_relay'][index] = relay_entry
    else:
        # Create new
        host_data['dhcp_relay'].append(relay_entry)
    
    # Write back
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': 'DHCP relay saved'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "delete-dhcp-relay")
        # Delete DHCP relay entry
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys

try:
    params = json.loads('''$POST_DATA''')
except:
    params = {}

device = params.get('device', '')
index = params.get('index')

if not device or index is None:
    print(json.dumps({'success': False, 'error': 'Device and index are required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_vars_dir = f"{ansible_dir}/inventory/host_vars"
host_file = f"{host_vars_dir}/{device}.yaml"

# Try .yml if .yaml doesn't exist
if not os.path.exists(host_file):
    alt_file = f"{host_vars_dir}/{device}.yml"
    if os.path.exists(alt_file):
        host_file = alt_file

try:
    # Load host_vars
    host_data = {}
    if os.path.exists(host_file):
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
    
    if 'dhcp_relay' not in host_data or not isinstance(index, int) or index < 0 or index >= len(host_data['dhcp_relay']):
        print(json.dumps({'success': False, 'error': 'DHCP relay entry not found'}))
        sys.exit(0)
    
    # Delete the entry
    del host_data['dhcp_relay'][index]
    
    # If empty, remove the key
    if len(host_data['dhcp_relay']) == 0:
        del host_data['dhcp_relay']
    
    # Write back
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': 'DHCP relay deleted'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "save-evpn-mh")
        # Save EVPN Multihoming configuration
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys

try:
    params = json.loads('''$POST_DATA''')
    device = params.get('device', '')
    evpn_mh = params.get('evpn_mh', {})
    
    if not device:
        print(json.dumps({'success': False, 'error': 'Device is required'}))
        sys.exit(0)
    
    if not evpn_mh.get('sysmac'):
        print(json.dumps({'success': False, 'error': 'System MAC is required'}))
        sys.exit(0)
    
    ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
    host_file = f"{ansible_dir}/inventory/host_vars/{device}.yaml"
    
    if not os.path.exists(host_file):
        print(json.dumps({'success': False, 'error': f'Host file not found: {device}.yaml'}))
        sys.exit(0)
    
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    # Set evpn_mh
    host_data['evpn_mh'] = {
        'sysmac': evpn_mh.get('sysmac'),
        'df_preference': evpn_mh.get('df_preference', 50000)
    }
    
    # Write back
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': 'EVPN Multihoming saved'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    "delete-evpn-mh")
        # Delete EVPN Multihoming configuration
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys

try:
    params = json.loads('''$POST_DATA''')
    device = params.get('device', '')
    
    if not device:
        print(json.dumps({'success': False, 'error': 'Device is required'}))
        sys.exit(0)
    
    ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
    host_file = f"{ansible_dir}/inventory/host_vars/{device}.yaml"
    
    if not os.path.exists(host_file):
        print(json.dumps({'success': False, 'error': f'Host file not found: {device}.yaml'}))
        sys.exit(0)
    
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    if 'evpn_mh' not in host_data:
        print(json.dumps({'success': False, 'error': 'EVPN Multihoming not configured'}))
        sys.exit(0)
    
    # Delete evpn_mh
    del host_data['evpn_mh']
    
    # Write back
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': 'EVPN Multihoming deleted'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    create-bond)
        # Create a new bond interface
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import sys
import os

try:
    data = json.loads('''$POST_DATA''')
except:
    try:
        data = json.loads(sys.stdin.read())
    except:
        print(json.dumps({'success': False, 'error': 'Invalid JSON data'}))
        sys.exit(0)

device = data.get('device', '')
bond_name = data.get('bond_name', '')
profile = data.get('profile', '')
mh_id = data.get('evpn_mh_id', '')
bond_mode = data.get('bond_mode', 'lacp')
lacp_bypass = data.get('lacp_bypass', False)
description = data.get('description', '')

if not device or not bond_name:
    print(json.dumps({'success': False, 'error': 'Device and bond name are required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_file = f"{ansible_dir}/inventory/host_vars/{device}.yaml"

try:
    # Load host file
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    # Initialize bonds if not exists
    if 'bonds' not in host_data:
        host_data['bonds'] = {}
    
    # Check if bond already exists
    if bond_name in host_data['bonds']:
        print(json.dumps({'success': False, 'error': f'Bond {bond_name} already exists'}))
        sys.exit(0)
    
    # Create bond entry
    bond_entry = {}
    
    if profile:
        bond_entry['sw_port_profile'] = profile
    
    if mh_id:
        bond_entry['evpn_mh_id'] = int(mh_id)
    
    if bond_mode and bond_mode != 'lacp':
        bond_entry['bond_mode'] = bond_mode
    
    if lacp_bypass:
        bond_entry['lacp_bypass'] = True
    
    if description:
        bond_entry['description'] = description
    
    # Empty bond_members - will be added later
    bond_entry['bond_members'] = []
    
    host_data['bonds'][bond_name] = bond_entry
    
    # Write back
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': f'Bond {bond_name} created'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    delete-bond)
        # Delete a bond interface
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import sys
import os

try:
    data = json.loads('''$POST_DATA''')
except:
    try:
        data = json.loads(sys.stdin.read())
    except:
        print(json.dumps({'success': False, 'error': 'Invalid JSON data'}))
        sys.exit(0)

device = data.get('device', '')
bond_name = data.get('name', '')

if not device or not bond_name:
    print(json.dumps({'success': False, 'error': 'Device and bond name are required'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_file = f"{ansible_dir}/inventory/host_vars/{device}.yaml"

try:
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    if 'bonds' not in host_data or bond_name not in host_data['bonds']:
        print(json.dumps({'success': False, 'error': f'Bond {bond_name} not found'}))
        sys.exit(0)
    
    # Get bond members to release them
    bond_members = host_data['bonds'][bond_name].get('bond_members', [])
    
    # Remove bond
    del host_data['bonds'][bond_name]
    
    # Clean up empty bonds dict
    if not host_data['bonds']:
        del host_data['bonds']
    
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': f'Bond {bond_name} deleted'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    delete-subinterface)
        # Delete a subinterface
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import sys
import os

try:
    data = json.loads('''$POST_DATA''')
except:
    try:
        data = json.loads(sys.stdin.read())
    except:
        print(json.dumps({'success': False, 'error': 'Invalid JSON data'}))
        sys.exit(0)

device = data.get('device', '')
subif_name = data.get('name', '')  # e.g., swp1.1001

if not device or not subif_name:
    print(json.dumps({'success': False, 'error': 'Device and subinterface name are required'}))
    sys.exit(0)

# Parse parent interface and subif ID
if '.' not in subif_name:
    print(json.dumps({'success': False, 'error': 'Invalid subinterface name format'}))
    sys.exit(0)

parts = subif_name.rsplit('.', 1)
parent_if = parts[0]
subif_id = parts[1]

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_file = f"{ansible_dir}/inventory/host_vars/{device}.yaml"

try:
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    deleted = False
    
    # Check in interfaces -> parent -> subinterfaces
    if 'interfaces' in host_data and parent_if in host_data['interfaces']:
        iface = host_data['interfaces'][parent_if]
        if 'subinterfaces' in iface and subif_id in iface['subinterfaces']:
            del iface['subinterfaces'][subif_id]
            deleted = True
            # Clean up empty subinterfaces dict
            if not iface['subinterfaces']:
                del iface['subinterfaces']
        elif 'subinterfaces' in iface:
            # Try numeric key
            try:
                subif_id_int = int(subif_id)
                if subif_id_int in iface['subinterfaces']:
                    del iface['subinterfaces'][subif_id_int]
                    deleted = True
                    if not iface['subinterfaces']:
                        del iface['subinterfaces']
            except:
                pass
    
    if not deleted:
        print(json.dumps({'success': False, 'error': f'Subinterface {subif_name} not found'}))
        sys.exit(0)
    
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': f'Subinterface {subif_name} deleted'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    update-interface)
        # Update interface or bond settings
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import sys
import os

# Read POST data
try:
    data = json.loads('''$POST_DATA''')
except:
    try:
        data = json.loads(sys.stdin.read())
    except:
        print(json.dumps({'success': False, 'error': 'Invalid JSON data'}))
        sys.exit(0)

device = data.get('device', '')
interface_name = data.get('interface_name', '')
interface_type = data.get('interface_type', '')  # 'l2', 'l3', 'subif', 'bond'
description = data.get('description', '')

if not device or not interface_name:
    print(json.dumps({'success': False, 'error': 'Missing device or interface_name'}))
    sys.exit(0)

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))
host_file = f"{ansible_dir}/inventory/host_vars/{device}.yaml"

try:
    # Load host file
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    if interface_type == 'bond':
        # Update bond
        if 'bonds' not in host_data:
            host_data['bonds'] = {}
        if interface_name not in host_data['bonds']:
            host_data['bonds'][interface_name] = {}
        
        bond = host_data['bonds'][interface_name]
        
        # Update profile
        profile = data.get('profile', '')
        if profile:
            bond['sw_port_profile'] = profile
        elif 'sw_port_profile' in bond:
            del bond['sw_port_profile']
        
        # Update description
        if description:
            bond['description'] = description
        elif 'description' in bond:
            del bond['description']
        
        # Update bond_members
        bond_members = data.get('bond_members', [])
        if bond_members:
            bond['bond_members'] = bond_members
        elif 'bond_members' in bond:
            del bond['bond_members']
        
        # Update evpn_mh_id
        mh_id = data.get('evpn_mh_id', '')
        if mh_id:
            bond['evpn_mh_id'] = int(mh_id)
        elif 'evpn_mh_id' in bond:
            del bond['evpn_mh_id']
        
        # Update bond_mode
        bond_mode = data.get('bond_mode', '')
        if bond_mode:
            bond['bond_mode'] = bond_mode
        elif 'bond_mode' in bond:
            del bond['bond_mode']
        
        # Update lacp_bypass
        lacp_bypass = data.get('lacp_bypass', False)
        if lacp_bypass:
            bond['lacp_bypass'] = True
        elif 'lacp_bypass' in bond:
            del bond['lacp_bypass']
    
    elif interface_type == 'breakout':
        # Physical port with breakout config
        if 'interfaces' not in host_data:
            host_data['interfaces'] = {}
        if interface_name not in host_data['interfaces']:
            host_data['interfaces'][interface_name] = {}
        
        iface = host_data['interfaces'][interface_name]
        
        # Update breakout
        breakout = data.get('breakout', '')
        if breakout:
            iface['breakout'] = breakout
        elif 'breakout' in iface:
            del iface['breakout']
        
        # Update description
        if description:
            iface['description'] = description
        elif 'description' in iface:
            del iface['description']
    
    elif interface_type == 'bond-member':
        # Bond member - manage bond membership
        target_bond = data.get('target_bond', '')
        previous_bond = data.get('previous_bond', '')
        
        # Remove from previous bond if different
        if previous_bond and previous_bond != target_bond:
            if 'bonds' in host_data and previous_bond in host_data['bonds']:
                old_bond = host_data['bonds'][previous_bond]
                if 'bond_members' in old_bond and interface_name in old_bond['bond_members']:
                    old_bond['bond_members'].remove(interface_name)
        
        # Add to target bond
        if target_bond:
            if 'bonds' not in host_data:
                host_data['bonds'] = {}
            if target_bond not in host_data['bonds']:
                host_data['bonds'][target_bond] = {}
            
            bond = host_data['bonds'][target_bond]
            if 'bond_members' not in bond:
                bond['bond_members'] = []
            
            if interface_name not in bond['bond_members']:
                bond['bond_members'].append(interface_name)
        
        # Update description on interface
        if 'interfaces' not in host_data:
            host_data['interfaces'] = {}
        if interface_name not in host_data['interfaces']:
            host_data['interfaces'][interface_name] = {}
        
        iface = host_data['interfaces'][interface_name]
        if description:
            iface['description'] = description
        elif 'description' in iface:
            del iface['description']
            
    elif interface_type == 'l3':
        # L3 interface
        # First, remove from any previous bond
        previous_bond = data.get('previous_bond', '')
        if previous_bond:
            if 'bonds' in host_data and previous_bond in host_data['bonds']:
                old_bond = host_data['bonds'][previous_bond]
                if 'bond_members' in old_bond and interface_name in old_bond['bond_members']:
                    old_bond['bond_members'].remove(interface_name)
        
        if 'interfaces' not in host_data:
            host_data['interfaces'] = {}
        if interface_name not in host_data['interfaces']:
            host_data['interfaces'][interface_name] = {}
        
        iface = host_data['interfaces'][interface_name]
        
        # Update IP
        ip = data.get('ip', '')
        if ip:
            iface['ip'] = ip
        elif 'ip' in iface:
            del iface['ip']
        
        # Update VRF
        vrf = data.get('vrf', '')
        if vrf:
            iface['vrf'] = vrf
        elif 'vrf' in iface:
            del iface['vrf']
        
        # Update description
        if description:
            iface['description'] = description
        elif 'description' in iface:
            del iface['description']
            
    elif interface_type == 'subif':
        # Subinterface - format: swp1.1001
        # First, remove from any previous bond
        previous_bond = data.get('previous_bond', '')
        if previous_bond:
            if 'bonds' in host_data and previous_bond in host_data['bonds']:
                old_bond = host_data['bonds'][previous_bond]
                if 'bond_members' in old_bond and interface_name in old_bond['bond_members']:
                    old_bond['bond_members'].remove(interface_name)
        
        if '.' in interface_name:
            parent_if, sub_id = interface_name.rsplit('.', 1)
            
            if 'interfaces' not in host_data:
                host_data['interfaces'] = {}
            if parent_if not in host_data['interfaces']:
                host_data['interfaces'][parent_if] = {}
            if 'subinterfaces' not in host_data['interfaces'][parent_if]:
                host_data['interfaces'][parent_if]['subinterfaces'] = {}
            
            subif = host_data['interfaces'][parent_if]['subinterfaces'].get(sub_id, {})
            
            # Update VLAN ID
            vlan_id = data.get('vlan_id', '')
            if vlan_id:
                subif['vlan'] = int(vlan_id)
            
            # Update IP
            ip = data.get('ip', '')
            if ip:
                subif['ip'] = ip
            elif 'ip' in subif:
                del subif['ip']
            
            # Update VRF
            vrf = data.get('vrf', '')
            if vrf:
                subif['vrf'] = vrf
            elif 'vrf' in subif:
                del subif['vrf']
            
            host_data['interfaces'][parent_if]['subinterfaces'][sub_id] = subif
            
            # Update parent description
            if description:
                host_data['interfaces'][parent_if]['description'] = description
        else:
            print(json.dumps({'success': False, 'error': 'Invalid subinterface format'}))
            sys.exit(0)
            
    else:
        # L2 interface (default)
        # First, remove from any previous bond
        previous_bond = data.get('previous_bond', '')
        if previous_bond:
            if 'bonds' in host_data and previous_bond in host_data['bonds']:
                old_bond = host_data['bonds'][previous_bond]
                if 'bond_members' in old_bond and interface_name in old_bond['bond_members']:
                    old_bond['bond_members'].remove(interface_name)
        
        if 'interfaces' not in host_data:
            host_data['interfaces'] = {}
        if interface_name not in host_data['interfaces']:
            host_data['interfaces'][interface_name] = {}
        
        iface = host_data['interfaces'][interface_name]
        
        # Update profile
        profile = data.get('profile', '')
        if profile:
            iface['sw_port_profile'] = profile
        elif 'sw_port_profile' in iface:
            del iface['sw_port_profile']
        
        # Update description
        if description:
            iface['description'] = description
        elif 'description' in iface:
            del iface['description']
    
    # Write back
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({'success': True, 'message': f'{interface_type} {interface_name} updated'}))
except Exception as e:
    print(json.dumps({'success': False, 'error': str(e)}))
PYTHON
        ;;
    add-external-peer)
        # Add a new external BGP peer
        # Creates subinterface + adds peer to BGP profile
        # If create_border_profile=true, creates OVERLAY_BORDER_XX profile with External peer group
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os

try:
    data = json.loads('''$POST_DATA''')
except:
    import sys
    data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))

try:
    device = data.get('device', '')
    vrf = data.get('vrf', '')
    interface = data.get('interface', '')  # e.g., swp1.1002
    vlan_id = data.get('vlan_id', '')
    local_ip = data.get('local_ip', '')
    remote_peer = data.get('remote_peer', '')
    create_border_profile = data.get('create_border_profile', False)
    border_profile_suffix = data.get('border_profile_suffix', '00')
    
    if not all([device, vrf, interface, local_ip, remote_peer]):
        print(json.dumps({'success': False, 'error': 'Missing required fields'}))
        exit(0)
    
    # Parse interface name
    if '.' in interface:
        parent_if, sub_id = interface.split('.', 1)
    else:
        print(json.dumps({'success': False, 'error': 'Invalid interface format, expected swpX.VLAN'}))
        exit(0)
    
    # 1. Update host_vars - add subinterface
    host_file = os.path.join(ansible_dir, 'inventory', 'host_vars', f'{device}.yaml')
    
    if not os.path.exists(host_file):
        print(json.dumps({'success': False, 'error': f'Device file not found: {device}.yaml'}))
        exit(0)
    
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    # Get VRF config
    vrfs = host_data.get('vrfs', {})
    if vrf not in vrfs:
        print(json.dumps({'success': False, 'error': f'VRF {vrf} not found on device'}))
        exit(0)
    
    vrf_config = vrfs[vrf]
    bgp_profile = vrf_config.get('bgp', {}).get('bgp_profile', '')
    profile_created = False
    
    # Load BGP profiles
    bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
    with open(bgp_profiles_file, 'r') as f:
        bgp_data = yaml.safe_load(f) or {}
    
    profiles = bgp_data.get('bgp_profiles', {})
    
    # Check if current profile has External peer group
    has_external = False
    if bgp_profile and bgp_profile in profiles:
        peer_groups = profiles[bgp_profile].get('peer_groups', {})
        has_external = 'External' in peer_groups
    
    # If no External and create_border_profile requested, create new OVERLAY_BORDER_XX profile
    if not has_external and create_border_profile:
        new_profile_name = f'OVERLAY_BORDER_{border_profile_suffix}'
        
        # Create new profile with External peer group (template from OVERLAY_BORDER_XX)
        profiles[new_profile_name] = {
            'ipv4_unicast_af': {
                'redistribute_connected_routes': True,
                'redistribute_static_routes': False,
                'export_to_evpn_type5': True
            },
            'peer_groups': {
                'External': {
                    'description': 'External-Connections',
                    'peer_type': 'external',
                    'enable_bfd': False,
                    'peers': {
                        remote_peer: None
                    }
                }
            }
        }
        
        # Update VRF to use new profile
        if 'bgp' not in vrf_config:
            vrf_config['bgp'] = {}
        vrf_config['bgp']['bgp_profile'] = new_profile_name
        bgp_profile = new_profile_name
        profile_created = True
        
        # Save updated host_vars with new bgp_profile
        with open(host_file, 'w') as f:
            yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
        
        # Save bgp_profiles with new profile
        with open(bgp_profiles_file, 'w') as f:
            yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
    
    elif not has_external:
        print(json.dumps({'success': False, 'error': f'External peer group not found in profile {bgp_profile}. Enable "Create Border Profile" option.'}))
        exit(0)
    
    # Create subinterface
    if 'interfaces' not in host_data:
        host_data['interfaces'] = {}
    
    if parent_if not in host_data['interfaces']:
        host_data['interfaces'][parent_if] = {'description': 'External BGP'}
    
    if 'subinterfaces' not in host_data['interfaces'][parent_if]:
        host_data['interfaces'][parent_if]['subinterfaces'] = {}
    
    # Add subinterface
    host_data['interfaces'][parent_if]['subinterfaces'][int(sub_id)] = {
        'ip': local_ip,
        'vlan': int(sub_id),
        'vrf': vrf
    }
    
    # Save host_vars
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    # If profile already had External, add peer to it
    if has_external and not profile_created:
        # Reload bgp_profiles (might have been saved)
        with open(bgp_profiles_file, 'r') as f:
            bgp_data = yaml.safe_load(f) or {}
        
        profiles = bgp_data.get('bgp_profiles', {})
        profile = profiles[bgp_profile]
        external_pg = profile['peer_groups']['External']
        
        # Initialize peers dict if needed
        if 'peers' not in external_pg:
            external_pg['peers'] = {}
        
        # Handle both list and dict formats
        if isinstance(external_pg['peers'], list):
            if remote_peer not in external_pg['peers']:
                external_pg['peers'].append(remote_peer)
        else:
            external_pg['peers'][remote_peer] = None
        
        # Save bgp_profiles
        with open(bgp_profiles_file, 'w') as f:
            yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({
        'success': True, 
        'message': f'Added external peer {remote_peer} on {device} ({interface})',
        'bgp_profile': bgp_profile,
        'profile_created': profile_created
    }))

except Exception as e:
    import traceback
    print(json.dumps({'success': False, 'error': str(e), 'trace': traceback.format_exc()}))
PYTHON
        ;;
    delete-external-peer)
        # Delete an external BGP peer
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys

try:
    data = json.loads('''$POST_DATA''')
except:
    data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))

try:
    device = data.get('device', '')
    vrf = data.get('vrf', '')
    interface = data.get('interface', '')  # e.g., swp1.1002
    remote_peer = data.get('remote_peer', '')
    
    if not all([device, vrf, remote_peer]):
        print(json.dumps({'success': False, 'error': 'Missing required fields'}))
        sys.exit(0)
    
    # 1. Update host_vars - remove subinterface if specified
    host_file = os.path.join(ansible_dir, 'inventory', 'host_vars', f'{device}.yaml')
    subif_removed = False
    
    if os.path.exists(host_file) and interface and '.' in interface:
        parent_if, sub_id = interface.split('.', 1)
        
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
        
        # Remove subinterface
        if 'interfaces' in host_data and parent_if in host_data['interfaces']:
            subifs = host_data['interfaces'][parent_if].get('subinterfaces', {})
            
            # Try both int and string keys
            if int(sub_id) in subifs:
                del subifs[int(sub_id)]
                subif_removed = True
            elif sub_id in subifs:
                del subifs[sub_id]
                subif_removed = True
            
            # Clean up empty subinterfaces dict
            if subif_removed and not subifs:
                del host_data['interfaces'][parent_if]['subinterfaces']
            
            # Clean up empty interface dict
            if subif_removed and len(host_data['interfaces'][parent_if]) == 0:
                del host_data['interfaces'][parent_if]
        
        if subif_removed:
            with open(host_file, 'w') as f:
                yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    # 2. Get BGP profile from VRF config
    bgp_profile = ''
    if os.path.exists(host_file):
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
        vrfs = host_data.get('vrfs', {})
        if vrf in vrfs:
            bgp_profile = vrfs[vrf].get('bgp', {}).get('bgp_profile', '')
    
    # 3. Remove peer from BGP profile External group
    peer_removed = False
    profile_deleted = False
    
    if bgp_profile:
        bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
        
        with open(bgp_profiles_file, 'r') as f:
            bgp_data = yaml.safe_load(f) or {}
        
        profiles = bgp_data.get('bgp_profiles', {})
        
        if bgp_profile in profiles:
            profile = profiles[bgp_profile]
            peer_groups = profile.get('peer_groups', {})
            
            if 'External' in peer_groups:
                external_pg = peer_groups['External']
                peers = external_pg.get('peers', {})
                
                if isinstance(peers, list):
                    if remote_peer in peers:
                        peers.remove(remote_peer)
                        peer_removed = True
                else:
                    if remote_peer in peers:
                        del peers[remote_peer]
                        peer_removed = True
                
                # Check if no peers left and profile is OVERLAY_BORDER_XX
                remaining_peers = len(peers) if isinstance(peers, (list, dict)) else 0
                is_border_profile = bgp_profile.startswith('OVERLAY_BORDER_')
                
                if peer_removed and remaining_peers == 0 and is_border_profile:
                    # Delete the empty OVERLAY_BORDER_XX profile
                    del profiles[bgp_profile]
                    profile_deleted = True
                    
                    # Update VRF to use OVERLAY_LEAF instead
                    with open(host_file, 'r') as f:
                        host_data = yaml.safe_load(f) or {}
                    
                    if vrf in host_data.get('vrfs', {}):
                        vrf_config = host_data['vrfs'][vrf]
                        if 'bgp' in vrf_config:
                            vrf_config['bgp']['bgp_profile'] = 'OVERLAY_LEAF'
                        
                        with open(host_file, 'w') as f:
                            yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
                
                # Save bgp_profiles (with or without deleted profile)
                with open(bgp_profiles_file, 'w') as f:
                    yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({
        'success': True, 
        'message': f'Deleted external peer {remote_peer} from {device}',
        'subinterface_removed': subif_removed,
        'peer_removed': peer_removed,
        'profile_deleted': profile_deleted
    }))

except Exception as e:
    import traceback
    print(json.dumps({'success': False, 'error': str(e), 'trace': traceback.format_exc()}))
PYTHON
        ;;
    update-external-peer)
        # Update an existing external BGP peer
        read -r POST_DATA
        python3 << PYTHON
import json
import yaml
import os
import sys

try:
    data = json.loads('''$POST_DATA''')
except:
    data = json.loads(sys.stdin.read()) if not sys.stdin.isatty() else {}

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))

try:
    device = data.get('device', '')
    vrf = data.get('vrf', '')
    original_peer = data.get('original_peer', '')
    interface = data.get('interface', '')  # e.g., swp1.1002
    local_ip = data.get('local_ip', '')
    remote_peer = data.get('remote_peer', '')
    bfd_enabled = data.get('bfd_enabled', False)
    
    if not all([device, vrf, interface, local_ip, remote_peer]):
        print(json.dumps({'success': False, 'error': 'Missing required fields'}))
        sys.exit(0)
    
    # Parse interface name
    if '.' in interface:
        parent_if, sub_id = interface.split('.', 1)
    else:
        print(json.dumps({'success': False, 'error': 'Invalid interface format, expected swpX.VLAN'}))
        sys.exit(0)
    
    # 1. Update host_vars - update subinterface
    host_file = os.path.join(ansible_dir, 'inventory', 'host_vars', f'{device}.yaml')
    
    if not os.path.exists(host_file):
        print(json.dumps({'success': False, 'error': f'Device file not found: {device}.yaml'}))
        sys.exit(0)
    
    with open(host_file, 'r') as f:
        host_data = yaml.safe_load(f) or {}
    
    # Get VRF's BGP profile
    vrfs = host_data.get('vrfs', {})
    if vrf not in vrfs:
        print(json.dumps({'success': False, 'error': f'VRF {vrf} not found on device'}))
        sys.exit(0)
    
    bgp_profile = vrfs[vrf].get('bgp', {}).get('bgp_profile', '')
    if not bgp_profile:
        print(json.dumps({'success': False, 'error': f'No BGP profile configured for VRF {vrf}'}))
        sys.exit(0)
    
    # Update subinterface
    if 'interfaces' not in host_data:
        host_data['interfaces'] = {}
    
    if parent_if not in host_data['interfaces']:
        host_data['interfaces'][parent_if] = {'description': 'External BGP'}
    
    if 'subinterfaces' not in host_data['interfaces'][parent_if]:
        host_data['interfaces'][parent_if]['subinterfaces'] = {}
    
    # Update subinterface config
    host_data['interfaces'][parent_if]['subinterfaces'][int(sub_id)] = {
        'ip': local_ip if '/' in local_ip else f'{local_ip}/31',
        'vlan': int(sub_id),
        'vrf': vrf
    }
    
    # Save host_vars
    with open(host_file, 'w') as f:
        yaml.dump(host_data, f, default_flow_style=False, sort_keys=False)
    
    # 2. Update BGP profile - update peer in External group
    bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
    
    with open(bgp_profiles_file, 'r') as f:
        bgp_data = yaml.safe_load(f) or {}
    
    profiles = bgp_data.get('bgp_profiles', {})
    
    if bgp_profile not in profiles:
        print(json.dumps({'success': False, 'error': f'BGP profile {bgp_profile} not found'}))
        sys.exit(0)
    
    profile = profiles[bgp_profile]
    peer_groups = profile.get('peer_groups', {})
    
    if 'External' not in peer_groups:
        print(json.dumps({'success': False, 'error': f'External peer group not found in profile {bgp_profile}'}))
        sys.exit(0)
    
    external_pg = peer_groups['External']
    
    # Update BFD setting for the External peer group
    external_pg['enable_bfd'] = bfd_enabled
    
    # Update peer IP if changed
    if original_peer and original_peer != remote_peer:
        peers = external_pg.get('peers', {})
        
        if isinstance(peers, list):
            # List format
            if original_peer in peers:
                peers.remove(original_peer)
            if remote_peer not in peers:
                peers.append(remote_peer)
        else:
            # Dict format
            if original_peer in peers:
                del peers[original_peer]
            peers[remote_peer] = None
    
    # Save bgp_profiles
    with open(bgp_profiles_file, 'w') as f:
        yaml.dump(bgp_data, f, default_flow_style=False, sort_keys=False)
    
    print(json.dumps({
        'success': True, 
        'message': f'Updated external peer {remote_peer} on {device} ({interface})',
        'bgp_profile': bgp_profile,
        'bfd_updated': True
    }))

except Exception as e:
    import traceback
    print(json.dumps({'success': False, 'error': str(e), 'trace': traceback.format_exc()}))
PYTHON
        ;;
    list-vtep-devices)
        # List all VTEP devices (devices with vtep.state: true)
        python3 << 'PYTHON'
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))

try:
    host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')
    hosts_file = os.path.join(ansible_dir, 'inventory', 'hosts')
    
    # Build hostname -> IP mapping from hosts file
    host_ips = {}
    if os.path.exists(hosts_file):
        with open(hosts_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and not line.startswith('[') and '=' in line:
                    parts = line.split()
                    hostname = parts[0]
                    for part in parts[1:]:
                        if part.startswith('ansible_host='):
                            host_ips[hostname] = part.split('=')[1]
                            break
    
    # Find all devices with vtep.state: true
    vtep_devices = []
    
    for host_file in glob.glob(os.path.join(host_vars_dir, '*.yaml')):
        hostname = os.path.basename(host_file).replace('.yaml', '')
        
        try:
            with open(host_file, 'r') as f:
                host_data = yaml.safe_load(f) or {}
            
            # Check if vtep.state is true
            vtep_config = host_data.get('vtep', {})
            if vtep_config.get('state', False):
                vtep_devices.append({
                    'hostname': hostname,
                    'ip': host_ips.get(hostname, '')
                })
        except:
            pass
    
    # Sort by hostname
    vtep_devices.sort(key=lambda x: x['hostname'])
    
    print(json.dumps({
        'success': True,
        'devices': vtep_devices,
        'count': len(vtep_devices)
    }))

except Exception as e:
    import traceback
    print(json.dumps({'success': False, 'error': str(e), 'trace': traceback.format_exc()}))
PYTHON
        ;;
    list-external-peers)
        # List all external BGP peers across all devices
        python3 << 'PYTHON'
import json
import yaml
import os
import glob

ansible_dir = os.environ.get('ANSIBLE_DIR', os.path.expanduser('~/ansible'))

try:
    # Load BGP profiles
    bgp_profiles_file = os.path.join(ansible_dir, 'inventory', 'group_vars', 'all', 'bgp_profiles.yaml')
    bgp_profiles = {}
    profiles_with_external = {}
    
    if os.path.exists(bgp_profiles_file):
        with open(bgp_profiles_file, 'r') as f:
            bgp_data = yaml.safe_load(f) or {}
            bgp_profiles = bgp_data.get('bgp_profiles', {})
    
    # Find profiles that have "External" peer group
    for profile_name, profile_config in bgp_profiles.items():
        peer_groups = profile_config.get('peer_groups', {})
        if 'External' in peer_groups:
            external_pg = peer_groups['External']
            profiles_with_external[profile_name] = {
                'peers': list(external_pg.get('peers', {}).keys()) if isinstance(external_pg.get('peers'), dict) else external_pg.get('peers', []),
                'bfd_enabled': external_pg.get('enable_bfd', False),
                'description': external_pg.get('description', ''),
                'has_external': True
            }
    
    # Load all devices and find those using external profiles
    peers = []
    devices = []
    host_vars_dir = os.path.join(ansible_dir, 'inventory', 'host_vars')
    
    for host_file in glob.glob(os.path.join(host_vars_dir, '*.yaml')):
        hostname = os.path.basename(host_file).replace('.yaml', '')
        
        with open(host_file, 'r') as f:
            host_data = yaml.safe_load(f) or {}
        
        # Check VRFs for external BGP profiles
        vrfs = host_data.get('vrfs', {})
        interfaces = host_data.get('interfaces', {})
        has_external = False
        
        for vrf_name, vrf_config in vrfs.items():
            bgp_config = vrf_config.get('bgp', {})
            profile_name = bgp_config.get('bgp_profile', '')
            
            if profile_name in profiles_with_external:
                has_external = True
                external_info = profiles_with_external[profile_name]
                
                # Get peer IPs from the profile
                peer_ips = external_info['peers']
                
                # Try to match subinterfaces to find local IPs
                for peer_ip in peer_ips:
                    # Find matching subinterface (same /31 network)
                    local_ip = ''
                    interface_name = ''
                    
                    for if_name, if_config in interfaces.items():
                        subinterfaces = if_config.get('subinterfaces', {})
                        for sub_id, sub_config in subinterfaces.items():
                            sub_ip = sub_config.get('ip', '')
                            sub_vrf = sub_config.get('vrf', '')
                            
                            # Check if this subinterface is in the same VRF
                            if sub_vrf == vrf_name and sub_ip:
                                # Check if IPs are in same /31 (simple check)
                                local_base = sub_ip.split('/')[0].rsplit('.', 1)[0]
                                peer_base = str(peer_ip).rsplit('.', 1)[0]
                                
                                if local_base == peer_base:
                                    local_ip = sub_ip
                                    interface_name = f"{if_name}.{sub_id}"
                                    break
                        if local_ip:
                            break
                    
                    peers.append({
                        'device': hostname,
                        'vrf': vrf_name,
                        'bgp_profile': profile_name,
                        'interface': interface_name,
                        'local_ip': local_ip.split('/')[0] if local_ip else '',
                        'remote_peer': str(peer_ip),
                        'bfd_enabled': external_info['bfd_enabled']
                    })
        
        if has_external:
            devices.append({'hostname': hostname})
    
    # Sort peers by device, then vrf
    peers.sort(key=lambda x: (x['device'], x['vrf'], x['remote_peer']))
    
    print(json.dumps({
        'success': True,
        'peers': peers,
        'devices': devices,
        'bgp_profiles': {k: {'has_external': True, 'bfd_enabled': v['bfd_enabled']} for k, v in profiles_with_external.items()}
    }))

except Exception as e:
    import traceback
    print(json.dumps({'success': False, 'error': str(e), 'trace': traceback.format_exc()}))
PYTHON
        ;;
    *)
        echo '{"success": false, "error": "Unknown action: '"$ACTION"'"}'
        ;;
esac
