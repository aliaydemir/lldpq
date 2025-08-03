# Commands Reference

Complete list of commands executed on network devices across all monitoring and configuration scripts.

## 📊 Monitor Script (`monitor.sh`)

### Interface and Network Status
```bash
# Interface overview and status
nv show interface
nv show interface status  
nv show interface description

# Bridge and VLAN information
nv show bridge port-vlan

# Network neighbor information  
ip neighbour | grep -E -v "fe80" | sort
sudo bridge fdb | grep -E -v "00:00:00:00:00:00" | sort

# BGP status
sudo vtysh -c "show bgp vrf all sum"
```

### Interface Data Collection (Per Interface)
```bash
# For each swp interface:
nv show interface $interface counters
cat /sys/class/net/$interface/carrier_changes
nv show interface $interface transceiver
```

### Hardware Health Monitoring
```bash
# System health data
sensors
free -h
cat /proc/loadavg  
uptime

# Network interface statistics
cat /proc/net/dev
```

### Log Collection (Enhanced - Requires Sudo)
```bash
# FRR Routing logs (sudo required for reliable access)
sudo tail -100 /var/log/frr/frr.log | grep -E "(error|warn|crit|fail|down|bgp|ospf)"

# Switch daemon logs (sudo required)
sudo tail -100 /var/log/switchd.log | grep -E "(error|warn|crit|fail|except)"

# NVUE configuration logs (sudo required)
sudo tail -50 /var/log/nvued.log | grep -E "(error|warn|fail|except)"

# Spanning Tree Protocol logs (sudo required)
sudo tail -50 /var/log/mstpd | grep -E "(error|warn|topology|change)"

# MLAG logs (sudo required)
sudo tail -50 /var/log/clagd.log | grep -E "(error|warn|fail|conflict|peer)"

# Authentication logs (ALWAYS requires sudo)
sudo tail -50 /var/log/auth.log | grep -E "(fail|error|invalid|denied|attack)"

# System critical logs (sudo required for full access)
sudo tail -100 /var/log/syslog | grep -E "(error|crit|alert|emerg|fail)"

# Journal priority logs (sudo for complete access)
sudo journalctl --since="24 hours ago" --priority=0..3 --no-pager --lines=50

# Hardware kernel messages (sudo may be required)
sudo dmesg --since="24 hours ago" --level=crit,alert,emerg | tail -30

# Network interface state changes (sudo for full journal access)
sudo journalctl --since="24 hours ago" --grep="swp|bond|vlan|carrier|link.*up|link.*down" --no-pager --lines=30
```

## 🔍 LLDP Check Script (`check-lldp.sh`)

### LLDP Neighbor Discovery
```bash
# Get LLDP neighbors for each interface
sudo lldpcli show neighbors ports $interface detail

# Alternative LLDP commands
lldpctl show neighbors
sudo lldpcli show statistics
```

## ⚙️ Configuration Script (`get-configs.sh`)

### Device Configuration Export
```bash
# Get all NVUE configuration nv-set format
nv config show -o commands

# Get all NVUE configuration nv-yaml format
sudo cat /etc/nvue.d/startup.yaml
```

## 📦 Asset Information Script (`assets.sh`)

### System Information
```bash
# Basic system info
hostname
cat /etc/hostname

# Network configuration
ip addr show
cat /proc/version
cat /etc/os-release

# Hardware information  
sudo dmidecode -s system-serial-number
sudo dmidecode -s system-product-name
cat /proc/cpuinfo | grep "model name" | head -1
cat /proc/meminfo | grep MemTotal

# Uptime information
uptime
cat /proc/uptime
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

| Script | Purpose | Commands/Device | Frequency |
|--------|---------|----------------|-----------|
| `monitor.sh` | Full monitoring | ~25 commands | Manual/Cron |
| `check-lldp.sh` | LLDP topology | ~5 commands | Manual/Cron |
| `get-configs.sh` | Configuration | ~3 commands | Manual/Cron |
| `assets.sh` | Asset inventory | ~8 commands | Manual/Cron |
| `send-key.sh` | SSH setup | ~2 commands | Once |
| `sudo-fix.sh` | Sudo setup | ~2 commands | Once |

## 📝 Notes

- All commands use SSH multiplexing for performance
- Timeout values prevent hanging connections
- Error handling with fallback commands
- Log commands filter for relevant information only
- Commands are non-interactive and production-safe

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