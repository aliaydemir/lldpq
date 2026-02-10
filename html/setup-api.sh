#!/bin/bash
# setup-api.sh - SSH Setup API (send-key + sudo-fix)
# Backend for SSH Setup modal in assets.html
# Called by nginx fcgiwrap

# Load config
if [[ -f /etc/lldpq.conf ]]; then
    source /etc/lldpq.conf
fi

LLDPQ_DIR="${LLDPQ_DIR:-/home/lldpq/lldpq}"
LLDPQ_USER="${LLDPQ_USER:-lldpq}"

# Output JSON header
echo "Content-Type: application/json"
echo ""

# Read POST data
if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
else
    POST_DATA=$(cat)
fi

# Only accept POST
if [ "$REQUEST_METHOD" != "POST" ]; then
    echo '{"success": false, "error": "POST method required"}'
    exit 0
fi

# Export for Python
export LLDPQ_DIR LLDPQ_USER POST_DATA

python3 << 'PYTHON'
import json
import sys
import os
import subprocess
import re
from concurrent.futures import ThreadPoolExecutor, as_completed

def load_devices(devices_yaml):
    """Load devices from devices.yaml"""
    try:
        import yaml
        with open(devices_yaml, 'r') as f:
            config = yaml.safe_load(f)
    except Exception as e:
        return None, str(e)
    
    defaults = config.get('defaults', {})
    default_username = defaults.get('username', 'cumulus')
    
    devs = config.get('devices', {})
    if not devs:
        return None, 'No devices found in devices.yaml'
    
    devices = []
    for ip_addr, device_config in devs.items():
        if isinstance(device_config, str):
            match = re.match(r'^(.+?)\s+@(\w+)$', device_config.strip())
            if match:
                hostname = match.group(1).strip()
            else:
                hostname = device_config.strip()
            username = default_username
        elif isinstance(device_config, dict):
            hostname = device_config.get('hostname', str(ip_addr))
            username = device_config.get('username', default_username)
        else:
            continue
        devices.append({
            'ip': str(ip_addr),
            'hostname': hostname,
            'username': username
        })
    
    return devices, None

def ensure_ssh_key(lldpq_user):
    """Check if SSH key exists for LLDPQ_USER, generate if missing. Returns (key_path, generated, error)"""
    # Check for existing keys
    for key_type, key_name in [('ed25519', 'id_ed25519'), ('rsa', 'id_rsa')]:
        pub_path = os.path.expanduser(f'~{lldpq_user}/.ssh/{key_name}.pub')
        if os.path.isfile(pub_path):
            return pub_path, False, None
    
    # No key found - generate ed25519
    ssh_dir = os.path.expanduser(f'~{lldpq_user}/.ssh')
    key_path = os.path.join(ssh_dir, 'id_ed25519')
    pub_path = key_path + '.pub'
    
    try:
        # Ensure .ssh directory exists
        os.makedirs(ssh_dir, mode=0o700, exist_ok=True)
        
        # Generate key as LLDPQ_USER
        result = subprocess.run(
            ['sudo', '-u', lldpq_user, 'ssh-keygen', '-t', 'ed25519', '-N', '', '-f', key_path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return None, False, f'ssh-keygen failed: {result.stderr}'
        
        return pub_path, True, None
    except Exception as e:
        return None, False, str(e)

def setup_device(device, password, ssh_key_path, lldpq_user):
    """Run send-key + sudo-fix for a single device. Returns result dict."""
    ip = device['ip']
    username = device['username']
    hostname = device['hostname']
    
    result = {
        'hostname': hostname,
        'ip': ip,
        'username': username,
        'send_key': 'skipped',
        'sudo_fix': 'skipped',
        'send_key_msg': '',
        'sudo_fix_msg': ''
    }
    
    # Step 1: Check if key already works
    try:
        check = subprocess.run(
            ['sudo', '-u', lldpq_user, 'ssh',
             '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5', '-o', 'StrictHostKeyChecking=no',
             '-q', f'{username}@{ip}', 'exit'],
            capture_output=True, text=True, timeout=10
        )
        if check.returncode == 0:
            result['send_key'] = 'already'
            result['send_key_msg'] = 'Key already configured'
        else:
            raise Exception('Key not configured')
    except Exception:
        # Key not configured - send it
        try:
            # Get the private key path (remove .pub)
            priv_key = ssh_key_path.replace('.pub', '')
            send = subprocess.run(
                ['sudo', '-u', lldpq_user, 'sshpass', '-p', password,
                 'ssh-copy-id', '-o', 'StrictHostKeyChecking=no', '-i', priv_key,
                 f'{username}@{ip}'],
                capture_output=True, text=True, timeout=30
            )
            if send.returncode == 0:
                result['send_key'] = 'ok'
                result['send_key_msg'] = 'Key sent successfully'
            else:
                result['send_key'] = 'fail'
                result['send_key_msg'] = send.stderr.strip()[:200] if send.stderr else 'ssh-copy-id failed'
        except subprocess.TimeoutExpired:
            result['send_key'] = 'fail'
            result['send_key_msg'] = 'Timeout (30s)'
        except Exception as e:
            result['send_key'] = 'fail'
            result['send_key_msg'] = str(e)[:200]
    
    # Step 2: Setup sudo (only if send-key succeeded or already configured)
    if result['send_key'] in ('ok', 'already'):
        try:
            sudo_cmd = (
                f"echo '{password}' | sudo -S bash -c "
                f"'echo \"{username} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/10_{username} "
                f"&& chmod 440 /etc/sudoers.d/10_{username}'"
            )
            sudo = subprocess.run(
                ['sudo', '-u', lldpq_user, 'sshpass', '-p', password,
                 'ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10',
                 f'{username}@{ip}', sudo_cmd],
                capture_output=True, text=True, timeout=30
            )
            if sudo.returncode == 0:
                result['sudo_fix'] = 'ok'
                result['sudo_fix_msg'] = 'Sudo configured'
            else:
                result['sudo_fix'] = 'fail'
                result['sudo_fix_msg'] = sudo.stderr.strip()[:200] if sudo.stderr else 'sudo setup failed'
        except subprocess.TimeoutExpired:
            result['sudo_fix'] = 'fail'
            result['sudo_fix_msg'] = 'Timeout (30s)'
        except Exception as e:
            result['sudo_fix'] = 'fail'
            result['sudo_fix_msg'] = str(e)[:200]
    else:
        result['sudo_fix'] = 'skipped'
        result['sudo_fix_msg'] = 'Skipped (send-key failed)'
    
    return result

# Main
try:
    post_data = json.loads(os.environ.get('POST_DATA', '{}'))
except:
    print(json.dumps({'success': False, 'error': 'Invalid JSON'}))
    sys.exit(0)

password = post_data.get('password', '')
retry_devices = post_data.get('retry_devices', [])  # List of IPs for retry

if not password:
    print(json.dumps({'success': False, 'error': 'Password is required'}))
    sys.exit(0)

lldpq_user = os.environ.get('LLDPQ_USER', 'lldpq')
lldpq_dir = os.environ.get('LLDPQ_DIR', '/home/lldpq/lldpq')
devices_yaml = os.path.join(lldpq_dir, 'devices.yaml')

# Ensure SSH key exists
ssh_key_path, key_generated, key_error = ensure_ssh_key(lldpq_user)
if key_error:
    print(json.dumps({'success': False, 'error': f'SSH key error: {key_error}'}))
    sys.exit(0)

# Load devices
all_devices, load_error = load_devices(devices_yaml)
if load_error:
    print(json.dumps({'success': False, 'error': load_error}))
    sys.exit(0)

# Filter for retry if specified
if retry_devices:
    all_devices = [d for d in all_devices if d['ip'] in retry_devices]
    if not all_devices:
        print(json.dumps({'success': False, 'error': 'No matching devices for retry'}))
        sys.exit(0)

# Run setup for all devices in parallel
results = []
with ThreadPoolExecutor(max_workers=20) as executor:
    futures = {
        executor.submit(setup_device, device, password, ssh_key_path, lldpq_user): device
        for device in all_devices
    }
    for future in as_completed(futures):
        try:
            results.append(future.result())
        except Exception as e:
            device = futures[future]
            results.append({
                'hostname': device['hostname'],
                'ip': device['ip'],
                'username': device['username'],
                'send_key': 'fail',
                'sudo_fix': 'fail',
                'send_key_msg': str(e),
                'sudo_fix_msg': ''
            })

# Sort by hostname
results.sort(key=lambda r: r['hostname'])

# Summary
total = len(results)
send_key_ok = sum(1 for r in results if r['send_key'] in ('ok', 'already'))
sudo_fix_ok = sum(1 for r in results if r['sudo_fix'] == 'ok')

print(json.dumps({
    'success': True,
    'key_generated': key_generated,
    'ssh_key': ssh_key_path,
    'total': total,
    'send_key_ok': send_key_ok,
    'sudo_fix_ok': sudo_fix_ok,
    'results': results
}))
PYTHON
