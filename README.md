![](html/png/nvidia-assets.png)

```
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║     ██╗      ██╗      ██████╗   ██████╗    ██████╗       ║
║     ██║      ██║      ██╔══██╗  ██╔══██╗  ██╔═══██╗      ║
║     ██║      ██║      ██║  ██║  ██████╔╝  ██║   ██║      ║
║     ██║      ██║      ██║  ██║  ██╔═══╝   ██║▄▄ ██║      ║
║     ██████╗  ██████╗  ██████╔╝  ██║        ╚██████╔╝     ║
║     ╚═════╝  ╚═════╝  ╚═════╝   ╚═╝         ╚══▀▀═╝      ║
║                                                          ║
║      Network Monitoring for Cumulus Linux Switches       ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
```

simple network monitoring tool for nvidia cumulus switches

## Requirements

- **Ubuntu Server** 20.04+ (tested on 22.04, 24.04)
- SSH key-based access to Cumulus switches
- Sudo privileges on target switches

## [00] quick start  

``` 
git clone https://github.com/aliaydemir/lldpq-src.git
cd lldpq-src
./install.sh 
```

## [01] what it does

- validation lldp and monitors switches every 5 minutes
- collects bgp, optical, ber, link flap, hardware health data
- shows network topology with lldp
- web dashboard with real-time stats

## [02] analysis coverage

- **bgp neighbors**: state, uptime, prefix counts, health status
- **optical diagnostics**: power levels, temperature, bias current, link margins  
- **link flap detection**: carrier transitions on all interfaces (including breakouts)
- **bit error rate**: comprehensive error statistics with industry thresholds
- **hardware health**: cpu/asic temperatures, memory usage, fan speeds, psu efficiency
- **topology validation**: lldp neighbor verification against expected topology

## [03] configuration files

edit these files:

```
~/lldpq/devices.yaml             # add your switches (required) - used by pping, zzh, send-cmd, get-conf
~/lldpq/topology.dot             # expected cable connections
~/lldpq/topology_config.yaml     # optional: customize device layers/icons (supports regex patterns)
~/lldpq/notifications.yaml       # optional: slack alerts + thresholds
~/lldpq/commands                 # optional: commands for send-cmd
```

### devices.yaml format

```yaml
defaults:
  username: cumulus

devices:
  10.10.100.10: Spine1            # simple: IP: Hostname
  10.10.100.11: Spine2 @spine     # with role: IP: Hostname @role
  10.10.100.12:                   # extended format
    hostname: Leaf1
    username: admin
    role: leaf
```

roles are optional tags for grouping. filter by role:
- **zzh**: type `@spine` to filter interactively
- **send-cmd**: `send-cmd -r spine -c "uptime"` to target specific roles
- **send-cmd**: `send-cmd --roles` to list available roles

### endpoint_hosts (optional)

add extra hostnames for topology visualization in devices.yaml. supports exact names and wildcard patterns:

```yaml
endpoint_hosts:
  - border-router-01      # exact hostname
  - "*dgx*"               # pattern - all devices containing "dgx"
  - "leaf-*"              # pattern - all devices starting with "leaf-"
  - "*-gpu"               # pattern - all devices ending with "-gpu"
```

patterns are matched against devices found in LLDP neighbor data.

## [04] cron jobs (auto setup)

```
*/5 * * * * lldpq                       # system monitoring every 5 minutes
0 */12 * * * get-conf                   # configs every 12 hours
* * * * * lldpq-trigger                 # web triggers daemon (checks every 5 seconds)
```

## [05] update

when lldpq gets new features via git:

```
cd lldpq-src
git pull                    # get latest code
./update.sh                 # smart update with data preservation
```

### what gets preserved:
- **config files**: devices.yaml, topology.dot, topology_config.yaml
- **monitoring data**: monitor-results/, lldp-results/ (optional backup)
- **system configs**: /etc/lldpq.conf  

update.sh will ask if you want to backup existing monitoring data before updating. choose 'y' to keep all your historical analysis results, hardware health data, and network topology information.

## [06] requirements

- linux based server
- ssh key auth to all switches  
- cumulus linux switches
- nginx web server

## [07] file sizes

monitor data grows ~50MB/day. history cleanup after 24h automatically.

## [08] ssh setup

setup ssh keys to all switches:

```
cd ~/lldpq && ./send-key.sh   # auto-installs deps, generates key, prompts password
```

setup passwordless sudo on all switches:

```
cd ~/lldpq && ./sudo-fix.sh   # configures passwordless sudo for cumulus user
```

## [09] cli tools

all tools use `devices.yaml` as the single source of device information.

```bash
# parallel ping
pping                              # ping all devices from devices.yaml
pping -r spine                     # ping only @spine devices
pping -r leaf -v mgmt              # ping @leaf via mgmt VRF
pping --roles                      # list available roles
pping -f hosts.txt                 # ping custom host list
pping -h                           # show help with file format

# send commands to devices
send-cmd                           # run commands from ~/lldpq/commands file
send-cmd -c "nv show system"       # run single command on all devices
send-cmd -c "uptime" -c "hostname" # run multiple commands
send-cmd -r spine -c "uptime"      # run only on @spine devices
send-cmd -r leaf -c "nv show bgp"  # run only on @leaf devices
send-cmd --roles                   # list available roles
send-cmd -e                        # edit commands file
send-cmd -l                        # list commands file
send-cmd -h                        # show help

# ssh manager (ncurses UI)
zzh                                # interactive ssh manager
zzh spine                          # filter: show only "spine" in name
zzh @leaf                          # filter by role (from devices.yaml)
zzh -h                             # show help

# config backup
get-conf                           # backup configs from all devices
```

## [10] ssh commands reference

see all commands executed on devices:

```
cat COMMANDS.md     # complete list of ssh commands, sudo requirements, security notes
```

## [11] authentication

web interface is protected with session-based authentication:

### default credentials:
```
admin / admin         # full access (includes Ansible Config Editor)
operator / operator   # limited access (no Ansible)
```

### features:
- **session-based login**: login page with 8-hour session timeout
- **remember me option**: stay logged in for 7 days
- **role-based access**: admin vs operator privileges
- **password management**: admin can change all passwords via UI
- **user management**: admin can create/delete operator users

### roles:
| Role | Dashboard | Topology View | Topology Edit | Configs | Ansible Editor | User Management |
|------|-----------|---------------|---------------|---------|----------------|-----------------|
| admin | Yes | Yes | Yes | Yes | Yes | Yes |
| operator | Yes | Yes | No | Yes | No | No |

**Operator restrictions:**
- Cannot edit `topology.dot` or `topology_config.yaml`
- Cannot access Ansible Config Editor
- Cannot manage users

### user management (admin only):
1. login as admin
2. click username in sidebar
3. select "User Management"

**capabilities:**
- view all existing users and their roles
- create new users (automatically assigned "operator" role)
- delete users (except admin)
- deleted users are immediately logged out

**security rules:**
- new users can only be created with "operator" role
- admin user cannot be deleted
- users cannot delete themselves

### change passwords:
1. login as admin
2. click username in sidebar
3. select "Change Passwords"
4. choose user and set new password

**important**: change default passwords after installation!

## [12] alerts & notifications

get real-time alerts for network issues via Slack:

```
cd ~/lldpq
nano notifications.yaml                              # add webhook URLs + enable alerts
python3 test_alerts.py                               # test configuration
```

### setup webhooks:

**slack:**  
1. go to https://api.slack.com/apps → create app → incoming webhooks
2. activate → add to workspace → choose channel → copy webhook url

### alert types:
- **hardware**: cpu/asic temp, fan failures, memory usage, psu issues
- **network**: bgp neighbors down, excessive link flaps, optical power
- **system**: critical logs, disk usage, high load average
- **recovery**: automatic notifications when issues resolve

### how it works:
- **smart detection**: only alerts on state changes (no spam)
- **1-minute checks**: runs with lldpq cron job every minute for fast topology updates
- **customizable**: adjust thresholds in notifications.yaml
- **state tracking**: prevents duplicate alerts, tracks recovery

alerts automatically start working once webhooks are configured. check `~/lldpq/alert-states/` for alert history.

## [13] troubleshooting

```
# check if cron is running
sudo crontab -l | grep lldpq

# manual run
cd ~/lldpq && ./assets.sh && ./check-lldp.sh && ./monitor.sh

# check logs  
ls -la /var/www/html/monitor-results/
```

## [14] license

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

### What this means:
- ✅ **Free to use** for any purpose (personal, commercial, enterprise)
- ✅ **Modify and distribute** as you wish
- ✅ **No warranty** - use at your own risk
- ✅ **Only requirement**: Keep the original license notice

### Contributing
Contributions are welcome! Please feel free to submit a Pull Request.

---

done.
