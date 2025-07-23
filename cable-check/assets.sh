#!/bin/bash

DATE=$(date '+%Y-%m-%d %H-%M')
SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
source "$SCRIPT_DIR/devices.sh"

command='echo $HOSTNAME \
$(ip -4 -o addr show dev eth0 | awk "{print \$4}" | cut -d/ -f1) \
$(cat /sys/class/net/eth0/address) \
$(nv sh platform | grep serial-number | awk "{print \$2}") \
$(nv sh platform | grep product-name | awk "{print \$2}") \
$(grep RELEASE /etc/lsb-release | cut -d "=" -f2) \
$(uptime -p | sed "s/,//g; s/ /-/g")'

mkdir -p ~/cable-check
echo "DEVICE-NAME ETH0-IP ETH0-MAC SERIAL MODEL VERSION UPTIME" > ~/cable-check/assets.txt

rm -f ~/cable-check/unreachable.tmp

ping_test() {
    local device=$1
    local hostname=$2
    ping -c 1 -W 0.5 "$device" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "$hostname" >> ~/cable-check/unreachable.tmp
        return 1
    fi
    return 0
}

execute_commands() {
    local device=$1
    local user=$2
    local hostname=$3
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" $command 2>/dev/null >> ~/cable-check/assets.txt
}

process_device() {
    local device=$1
    local user=$2
    local hostname=$3
    ping_test "$device" "$hostname"
    if [ $? -eq 0 ]; then
        execute_commands "$device" "$user" "$hostname"
    fi
}

for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"
    process_device "$device" "$user" "$hostname" &
done

wait

column -t ~/cable-check/assets.txt > ~/cable-check/asset
rm -rf ~/cable-check/assets.txt
sort -t'.' -k1,1n -k2,2n -k3,3n -k4,4n ~/cable-check/asset > ~/cable-check/assets.ini
rm -rf ~/cable-check/asset

if [ -f ~/cable-check/unreachable.tmp ]; then
    while IFS= read -r hostname; do
        printf "%s\t No-Info\n" "$hostname" >> ~/cable-check/assets.ini
    done < ~/cable-check/unreachable.tmp
    rm -f ~/cable-check/unreachable.tmp
fi

echo -e "\nCreated on $DATE" >> ~/cable-check/assets.ini
sudo cp ~/cable-check/assets.ini /var/www/html/
exit 0
