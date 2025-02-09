#!/bin/bash

SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
source "$SCRIPT_DIR/devices.sh"
date=$(date +%F--%H-%M)
mkdir -p ~/configs/configs-${date}/nv-yaml
mkdir -p ~/configs/configs-${date}/nv-set
sudo mkdir -p /var/www/html/configs
unreachable_hosts_file=$(mktemp)

ping_test() {
    local device=$1
    local hostname=$2
    ping -c 1 -W 0.5 "$device" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "$device $hostname" >> "$unreachable_hosts_file"
        return 1
    fi
    return 0
}

execute_commands() {
    local device=$1
    local user=$2
    local hostname=$3

    ssh -q -o StrictHostKeyChecking=no "${user}@${device}" "nv config save" > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        ssh -q -o StrictHostKeyChecking=no "${user}@${device}" "sudo cat /etc/nvue.d/startup.yaml" 2>/dev/null 1> ~/configs/configs-${date}/nv-yaml/${hostname}.yaml
        ssh -q -o StrictHostKeyChecking=no "${user}@${device}" "nv config show -o commands" 2>/dev/null 1> ~/configs/configs-${date}/nv-set/${hostname}.txt
        echo -e "\e[0;32mConfig of \e[1;32m${hostname}\e[0;32m device has been pulled...\e[0m"
    else
        echo -e "\e[0;31mFailed to execute commands on ${hostname} (${device})\e[0m"
    fi
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

echo ""
echo -e "\e[1;34mAll commands have been executed...\e[0m"
echo ""

if [ -s "$unreachable_hosts_file" ]; then
    echo -e "\e[0;36mUnreachable hosts:\e[0m"
    echo ""
    while IFS= read -r host; do
        IFS=' ' read -r ip hostname <<< "$host"
        printf "\e[31m[%-14s]\t\e[0;31m[%-1s]\e[0m\n" "$ip" "$hostname"
    done < "$unreachable_hosts_file"
    echo ""
else
    echo -e "\e[0;32mAll hosts are reachable.\e[0m"
    echo ""
fi

sudo rm -rf /var/www/html/configs/*
sudo cp ~/configs/configs-${date}/nv-set/* /var/www/html/configs/
sudo cp ~/configs/configs-${date}/nv-yaml/* /var/www/html/configs/
rm -f "$unreachable_hosts_file"
exit 0
