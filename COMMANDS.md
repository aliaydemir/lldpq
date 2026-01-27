# Commands Reference

Complete list of commands executed on network devices across all monitoring and configuration scripts.

## 📊 Monitor Script (`monitor.sh` - Performance Optimized)

### Interface and Network Status (Native Linux Commands - 20x Faster)
```bash
# Interface status and descriptions (optimized)
ip link show | grep -E ': (swp|bond|vlan)'
for iface in $(ip link show | grep -E ': swp[0-9]' | cut -d: -f2 | tr -d ' '); do
    echo "$iface: $(cat /sys/class/net/$iface/operstate 2>/dev/null || echo unknown)"
done

# Interface IP addresses 
ip addr show | grep -E '(inet |inet6 )' | grep -v '127.0.0.1\|::1\|fe80'

# Bridge and VLAN information (native)
bridge vlan show | grep -v '^port'

# Network neighbor information  
ip neighbour | grep -E -v "fe80" | sort
sudo bridge fdb | grep -E -v "00:00:00:00:00:00" | sort

# BGP status
sudo vtysh -c "show bgp vrf all sum"
```

### Interface Data Collection (Per Interface - Optimized)
```bash
# For each swp interface (native Linux - faster):
ethtool -S $interface | grep -E '(rx_|tx_)' | head -10
cat /sys/class/net/$interface/carrier_changes
cat /sys/class/net/$interface/statistics/rx_packets
cat /sys/class/net/$interface/statistics/tx_packets

# Optical transceiver data (when available)
ethtool -m $interface 2>/dev/null || echo "No transceiver data"
```

### Hardware Health Monitoring
```bash
# System health data
sensors
free -h
cat /proc/loadavg  
uptime

# HW-management thermal sensors (if present)
# Values are usually in millidegree C; scripts convert to °C
sudo cat /var/run/hw-management/thermal/asic 2>/dev/null      # ASIC temperature (m°C)
sudo cat /var/run/hw-management/thermal/cpu_pack 2>/dev/null  # CPU package temperature (m°C)

# Network interface statistics
cat /proc/net/dev
```

### Log Collection (HYBRID Approach - Requires Sudo)
**🎯 Uses TIME + SEVERITY for critical services, OPTIMIZED LINES + SEVERITY for normal services**

```bash
# === CRITICAL NETWORK SERVICES (TIME + SEVERITY) ===
# FRR Routing logs (journalctl for recent events + severity filtering)
sudo journalctl -u frr --since="2 hours ago" --no-pager --lines=200 | grep -E "(ERROR|WARN|CRIT|FAIL|DOWN|BGP|neighbor|peer)"
# Fallback: sudo tail -100 /var/log/frr/frr.log | grep -E "(error|warn|crit|fail|down|bgp)"

# Switch daemon logs (journalctl for recent critical switchd events)
sudo journalctl -u switchd --since="2 hours ago" --no-pager --lines=150 | grep -E "(ERROR|WARN|CRIT|FAIL|EXCEPT|port|link|vlan)"
# Fallback: sudo tail -100 /var/log/switchd.log | grep -E "(error|warn|crit|fail|except)"

# === NORMAL SERVICES (OPTIMIZED LINES + SEVERITY) ===
# NVUE configuration logs (fixed lines + enhanced severity)
sudo tail -50 /var/log/nvued.log | grep -E "(ERROR|WARN|FAIL|EXCEPT|config|commit|rollback)"

# Spanning Tree Protocol logs (fixed lines + enhanced patterns)
sudo tail -50 /var/log/mstpd | grep -E "(ERROR|WARN|TOPOLOGY|CHANGE|port|state|bridge)"

# MLAG logs (fixed lines + enhanced patterns)
sudo tail -50 /var/log/clagd.log | grep -E "(ERROR|WARN|FAIL|CONFLICT|PEER|bond|backup|primary)"

# === SECURITY & SYSTEM (FIXED LINES + SEVERITY) ===
# Authentication logs (fixed lines + enhanced security patterns)
sudo tail -50 /var/log/auth.log | grep -E "(FAIL|ERROR|INVALID|DENIED|ATTACK|authentication|unauthorized|sudo)"

# System critical logs (fixed lines + enhanced system patterns)
sudo tail -100 /var/log/syslog | grep -E "(ERROR|CRIT|ALERT|EMERG|FAIL|kernel|oom|segfault)"

# === SYSTEM WIDE (TIME + SEVERITY) ===
# Journal priority logs (extended time + enhanced filtering)
sudo journalctl --since="3 hours ago" --priority=0..3 --no-pager --lines=75 | grep -E "(CRIT|ALERT|EMERG|ERROR|fail|crash|panic)"

# Hardware kernel messages (extended time + critical levels)
sudo dmesg --since="3 hours ago" --level=crit,alert,emerg | tail -40

# Network interface state changes (extended time + enhanced patterns)
sudo journalctl --since="3 hours ago" --grep="swp|bond|vlan|carrier|link.*up|link.*down|port.*up|port.*down" --no-pager --lines=40
```

## 🔍 LLDP Check Script (`check-lldp.sh`)

### LLDP Neighbor Discovery + Port Status
```bash
# Get LLDP neighbors for topology analysis
sudo lldpcli show neighbors

# Port status collection for LLDP correlation
ip link show | grep ': swp[0-9]' | awk '{
    if ($9 == "UP") print $2 " UP"
    else if ($9 == "DOWN") print $2 " DOWN"
    else print $2 " UP"
}' | sed 's/://'

# Device reachability check
ping -c 1 -W 0.5 $device_ip

# SSH connectivity test
ssh -o ConnectTimeout=5 $user@$device "echo test"
```

## ⚙️ Configuration Script (`get-configs.sh`)

### Device Configuration Export
```bash
# Get all NVUE configuration nv-set format
nv config show -o commands

# Get all NVUE configuration nv-yaml format
sudo cat /etc/nvue.d/startup.yaml
```

## 📦 Asset Information Script (`assets.sh` - Optimized)

### System Information (Performance Optimized)
```bash
# Basic system info
hostname
cat /etc/hostname

# Network configuration
ip addr show
cat /proc/version
cat /etc/os-release

# Hardware information (dmidecode - 10x faster than nv show platform)
sudo dmidecode -s system-serial-number    # Fast serial number lookup
sudo dmidecode -s system-product-name     # Fast model lookup
cat /proc/cpuinfo | grep "model name" | head -1
cat /proc/meminfo | grep MemTotal

# Uptime information
uptime
cat /proc/uptime

# Replaced slow commands:
# OLD: nv show platform --> NEW: dmidecode (10x faster)
# OLD: nv show system --> NEW: /proc/ + /etc/ files (instant)
```

## 🔐 SSH Key Management (`send-key.sh`)

### SSH Key Operations
```bash
# Copy SSH public key
ssh-copy-id -i ~/.ssh/id_rsa.pub $user@$device

# Test SSH connectivity
ssh -o ConnectTimeout=5 $user@$device "echo 'SSH test successful'"
```

## 🛠️ Sudo Fix Script (`sudo-fix.sh`)

### Sudo Configuration
```bash
# Add user to sudoers
echo "$user ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$user

# Verify sudo access
sudo -l
```

## 📊 Additional Commands by Analysis Type

### BGP Analysis
```bash
# Detailed BGP information
sudo vtysh -c "show bgp summary"
sudo vtysh -c "show bgp neighbors"
sudo vtysh -c "show ip route bgp"
```

### Hardware Analysis  
```bash
# Temperature monitoring
sensors | grep -E "(temp|Core|CPU|Ambient)"
# HW-management (platform) temperatures (if available)
sudo cat /var/run/hw-management/thermal/asic 2>/dev/null
sudo cat /var/run/hw-management/thermal/cpu_pack 2>/dev/null

# Power supply information
sensors | grep -E "(PMIC|PSU|VR|Rail|Pwr)"

# Fan status
sensors | grep -E "(fan|Fan|RPM)"
```

### Interface Analysis
```bash
# Per-interface detailed counters
nv show interface $interface counters
ethtool $interface
ethtool -S $interface

# Interface errors and statistics  
cat /sys/class/net/$interface/statistics/rx_errors
cat /sys/class/net/$interface/statistics/tx_errors
cat /sys/class/net/$interface/carrier_changes
```

## 🎯 Command Execution Summary

| Script | Purpose | Commands/Device | Frequency | Performance |
|--------|---------|----------------|-----------|-------------|
| `monitor.sh` | Full monitoring | ~25 commands | Every 5 minutes | Optimized |
| `check-lldp.sh` | LLDP topology | ~8 commands | Every minute | Optimized |
| `get-configs.sh` | Configuration | ~3 commands | Every 12 hours | Standard |
| `assets.sh` | Asset inventory | ~8 commands | Every 12 hours | **10x faster** |
| `send-key.sh` | SSH setup | ~2 commands | Once | Standard |
| `sudo-fix.sh` | Sudo setup | ~2 commands | Once | Standard |
| `lldpq-trigger` | Web triggers | Background daemon | Every 5 seconds | Lightweight |

## 🚀 Performance Optimized Scripts

### `monitor.sh` - Native Linux Monitoring (Optimized)
```bash
# Interface status (native - replaces nv show interface)
ip link show | grep -E ': (swp|bond|vlan)'

# Port descriptions integrated into status table
ethtool $interface | grep "Link detected"

# VLAN configuration (native - replaces nv show bridge)
bridge vlan show | grep -v '^port'

# Interface IP addresses (native)
ip addr show | awk '/inet/ && !/127.0.0.1/ && !/::1/ {print $2, $NF}'
```

### `lldpq-trigger` - Web Interface Triggers
```bash
# Background daemon for web-triggered actions (LLDP + Monitor)
LLDP_TRIGGER=/tmp/.lldp_web_trigger
MONITOR_TRIGGER=/tmp/.monitor_web_trigger
while true; do
  if [ -f "$LLDP_TRIGGER" ] && [ "$LLDP_TRIGGER" -nt .last_lldp_trigger_check ]; then
    date +%s > .last_lldp_trigger_check
    ./assets.sh && ./check-lldp.sh
  fi
  if [ -f "$MONITOR_TRIGGER" ] && [ "$MONITOR_TRIGGER" -nt .last_monitor_trigger_check ]; then
    date +%s > .last_monitor_trigger_check
    ./monitor.sh
  fi
  sleep 5
done
```

### Python HTML Generators
```bash
# LLDP analysis and HTML generation
python3 lldp-validate.py          # Process raw LLDP data
python3 generate_topology.py      # Generate network topology
python3 process_log_data.py       # Generate log analysis HTML
python3 generate_hardware_html.py # Generate hardware analysis HTML

# Analysis scripts with web output
python3 bgp_analyzer.py           # BGP neighbor analysis
python3 optical_analyzer.py       # Optical transceiver analysis
python3 ber_analyzer.py           # Bit Error Rate analysis
python3 link_flap_analyzer.py     # Link flap detection
```

## 📝 Notes

- All commands use SSH multiplexing for performance
- Timeout values prevent hanging connections
- Error handling with fallback commands
- Log commands filter for relevant information only
- Commands are non-interactive and production-safe
- **Native Linux commands provide 10-20x performance improvement**
- **Web interface integration via trigger daemon**

## 🔒 Security Considerations

- **Log commands require `sudo`** for accessing system logs (/var/log/*)
- **SSH keys used** for passwordless authentication  
- **NOPASSWD sudo** configured via `sudo-fix.sh` for automation
- **Read-only operations** (monitoring) - no system modifications
- **Sensitive logs protected** - auth.log, syslog require elevated privileges
- **Configuration commands** are separate scripts (get-configs.sh)
- **Timeout protections** prevent hanging SSH sessions

### Required Sudo Access for Log Monitoring
```bash
# Critical logs that REQUIRE sudo access:
/var/log/auth.log         # Authentication events (ALWAYS restricted)
/var/log/syslog           # System-wide logging (adm group)
/var/log/frr/frr.log      # FRR routing daemon logs
/var/log/switchd.log      # Switch daemon logs (critical)
/var/log/nvued.log        # NVUE configuration logs
journalctl                # SystemD journal (systemd-journal group)
dmesg                     # Kernel messages (may require sudo in newer kernels)

# The sudo-fix.sh script configures:
echo "username ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/username
```