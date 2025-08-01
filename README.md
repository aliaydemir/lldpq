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
- collects bgp, optical, ber, link flap data
- shows network topology with lldp
- web dashboard with real-time stats

## [02] configuration files

edit these 4 files:

```
cable-check/devices.sh     # add your switches (ip + username + hostname)
cable-check/topology.dot   # expected cable connections
cable-check/hosts.ini      # optional: extra hostnames for topology  
/etc/nccm.yml              # optional: ssh manager [zzh]
/etc/ip_list               # optional: paralel ping to all devices [pping]
```

## [03] cron jobs (auto setup)

```
*/30 * * * * lldpq         # topology every 30min (0,30)
15,45 * * * * monitor      # performance monitor every 30min (15,45)  
0 */12 * * * get-conf      # configs every 12 hours
```

## [04] web pages  

- `http://server/` - main dashboard
- `http://server/lldp.html` - topology problems
- `http://server/monitor-results/bgp-analysis.html` - bgp neighbors
- `http://server/monitor-results/optical-analysis.html` - sfp health
- `http://server/monitor-results/ber-analysis.html` - bit errors
- `http://server/monitor-results/link-flap-analysis.html` - unstable links

## [05] update

when lldpq gets new features via git:

```
cd lldpq
git pull                    # get latest code
./update.sh                 # keeps your configs, updates everything else
```

your devices.sh, hosts.ini, topology.dot topology_config.yaml files stay untouched.

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