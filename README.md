![](assets/nvidia.png)

# 🚀️ LLDPq

simple network monitoring tool for cumulus switches

## [00] quick start  

``` 
git clone https://github.com/aliaydemir/lldpq.git 
cd lldpq
./install.sh 
```

## [01] what it does

- monitors switches every 30 minutes  
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

edit these 6 files:

```
~/cable-check/devices.yaml            # add your switches (ip + username + hostname)
~/cable-check/topology.dot            # expected cable connections
~/cable-check/topology_config.yaml    # optional: customize device layers/icons at topology
~/cable-check/hosts.ini               # optional: extra hostnames for topology  
/etc/nccm.yml                         # optional: ssh manager [zzh]
/etc/ip_list                          # optional: paralel ping to all devices [pping]
```

## [04] cron jobs (auto setup)

```
*/10 * * * * lldpq         # topology every 10min
15,45 * * * * monitor      # performance monitor every 30min (15,45)  
0 */12 * * * get-conf      # configs every 12 hours
```

## [05] update

when lldpq gets new features via git:

```
cd lldpq
git pull                    # get latest code
./update.sh                 # keeps your configs, updates everything else
```

your devices.yaml, hosts.ini, topology.dot topology_config.yaml files stay untouched.

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
cd ~/cable-check && ./send-key.sh   # auto-installs deps, generates key, prompts password
```

setup passwordless sudo on all switches:

```
cd ~/cable-check && ./sudo-fix.sh   # configures passwordless sudo for cumulus user
```

## [09] troubleshooting

```
# check if cron is running
sudo crontab -l | grep lldpq

# manual run
cd ~/cable-check && ./assets.sh && ./check-lldp.sh && ./monitor.sh

# check logs  
ls -la /var/www/html/monitor-results/
```

done.
