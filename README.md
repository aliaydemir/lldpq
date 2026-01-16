![](assets/nvidia.png)

# 🚀️ LLDPq

simple network monitoring tool for nvidia cumulus switches

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

edit these 7 files:

```
~/lldpq/devices.yaml             # add your switches (ip + username + hostname)
~/lldpq/topology.dot             # expected cable connections
~/lldpq/topology_config.yaml     # optional: customize device layers/icons at topology
~/lldpq/notifications.yaml       # optional: slack alerts + thresholds
~/lldpq/hosts.ini                # optional: extra hostnames for topology  
/etc/nccm.yml                      # optional: ssh manager [zzh]
/etc/ip_list                       # optional: paralel ping to all devices [pping]
```

## [04] cron jobs (auto setup)

```
*/5 * * * * lldpq                       # system monitoring every 5 minutes
0 */12 * * * get-conf                   # configs every 12 hours
* * * * * lldp-trigger-monitor.sh       # web triggers daemon (checks every 5 seconds)
```

## [05] update

when lldpq gets new features via git:

```
cd lldpq-src
git pull                    # get latest code
./update.sh                 # smart update with data preservation
```

### what gets preserved:
- **config files**: devices.yaml, hosts.ini, topology.dot, topology_config.yaml
- **monitoring data**: monitor-results/, lldp-results/ (optional backup)
- **system configs**: /etc/ip_list, /etc/nccm.yml  

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

## [09] commands reference

see all commands executed on devices:

```
cat COMMANDS.md     # complete list of ssh commands, sudo requirements, security notes
```

## [10] authentication (optional)

to secure the web interface with login:

```
cd monitor && sudo ./webauth.sh     # interactive menu: enable/disable/update auth
```

### how it works:
- **nginx basic auth**: server-level security (no javascript bypass)
- **encrypted passwords**: bcrypt hashed, stored in /etc/nginx/.htpasswd
- **browser integration**: remember credentials, works with all browsers
- **zero backend**: no php/python needed, pure nginx feature

when enabled, all web pages require authentication. when disabled, everything is open access.

**note**: the web interface includes a "Run LLDP Check" button that automatically triggers lldp analysis from the browser.

## [11] alerts & notifications

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
- 🔥 **hardware**: cpu/asic temp, fan failures, memory usage, psu issues
- 🔴 **network**: bgp neighbors down, excessive link flaps, optical power
- 📋 **system**: critical logs, disk usage, high load average
- ✅ **recovery**: automatic notifications when issues resolve

### how it works:
- **smart detection**: only alerts on state changes (no spam)
- **1-minute checks**: runs with lldpq cron job every minute for fast topology updates
- **customizable**: adjust thresholds in notifications.yaml
- **state tracking**: prevents duplicate alerts, tracks recovery

alerts automatically start working once webhooks are configured. check `~/lldpq/alert-states/` for alert history.

## [12] troubleshooting

```
# check if cron is running
sudo crontab -l | grep lldpq

# manual run
cd ~/lldpq && ./assets.sh && ./check-lldp.sh && ./monitor.sh

# check logs  
ls -la /var/www/html/monitor-results/
```

## [13] license

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
