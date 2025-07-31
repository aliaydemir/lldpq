![](assets/nvidia.png)

# 🚀️ LLDPq

## [00] git clone  

``` 
git clone https://github.com/aliaydemir/lldpq.git 
```

cd lldpq

```
./install.sh 
```
or 
```
./update.sh
```

or manual 

``` install nginx, copy files, edit 4 files, then run ```


## [01]  install and runn "nginx"
```
sudo apt install nginx

sudo systemctl enable --now nginx
```


## [02]  copy files (cd lldpq/)
```
sudo cp -r etc/* /etc

sudo cp -r html/* /var/www/html/

sudo cp bin/* /usr/local/bin/

cp -r cable-check ~/cable-check 
```


## [03]  edit necesary files
```
sudo nano /etc/ip_list    
```
edit the end of the ```nccm.yml```
```
sudo nano /etc/nccm.yml
```
```
nano ~/cable-check/devices.sh
```
```
nano ~/cable-check/topology.dot
```
```
nano ~/cable-check/topology_confg.yaml
```

## [04]  restart nginx service
```
sudo systemctl restart nginx
```


## [05]  add cron job
```
echo "*/30 * * * * $(whoami) /usr/local/bin/lldpq" | sudo tee -a /etc/crontab
```
```
echo "15,45 * * * * $(whoami) /usr/local/bin/monitor" | sudo tee -a /etc/crontab
```
```
echo "0 */12 * * * $(whoami) /usr/local/bin/get-conf" | sudo tee -a /etc/crontab
```
 
# run the LLDPq 🚀️

Before running ```lldpq``` or ```zzh```, ```ssh-copy-id``` must be done on all devices. 
And run ```sudo``` without password.

```
lldpq
```

```
get-conf
```

```
monitor
```

```
zzh
```

```
pping
```

