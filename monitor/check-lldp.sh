#!/bin/bash
# LLDPq Topology Check Script  
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License

DATE=$(date '+%Y-%m-%d--%H-%M')

SCRIPT_DIR=$(dirname "$(readlink -f "$BASH_SOURCE")")
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

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
    
    # LLDP data collection
    echo -e "=========================================${hostname}=========================================\n" >> lldp-results/${hostname}_lldp_result.ini
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "sudo lldpcli show neighbors" >> lldp-results/${hostname}_lldp_result.ini
    
    # Port status collection (NEW)
    echo -e "\n===PORT_STATUS_START===" >> lldp-results/${hostname}_lldp_result.ini
    ssh -o StrictHostKeyChecking=no -T -q "$user@$device" "
        ip link show | grep ': swp[0-9]' | awk '{
            if (\$9 == \"UP\") print \$2, \"UP\"
            else if (\$9 == \"DOWN\") print \$2, \"DOWN\"
            else print \$2, \"UP\"
        }'
    " >> lldp-results/${hostname}_lldp_result.ini
    echo -e "===PORT_STATUS_END===\n" >> lldp-results/${hostname}_lldp_result.ini
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

if [ -s "$unreachable_hosts_file" ]; then
    echo -e "\e[0;36mUnreachable hosts:\e[0m"
    echo ""
    while IFS= read -r host; do
        IFS=' ' read -r ip hostname <<< "$host"
        printf "\e[31m[%-14s]\t\e[0;31m[%-1s]\e[0m\n" "$ip" "$hostname"
    done < "$unreachable_hosts_file"
    echo ""
fi

/usr/bin/python3 ./lldp-validate.py
grep -v Pass lldp-results/lldp_results.ini > lldp-results/raw-problems-lldp_results.ini

awk 'NF' RS='\n\n' lldp-results/raw-problems-lldp_results.ini | awk '/No-Info/ || /Fail/' RS= | sed '/^================================/i\\' > lldp-results/problems-lldp_results.ini
if [ ! -s lldp-results/problems-lldp_results.ini ]; then
    head -n 1 lldp-results/raw-problems-lldp_results.ini >> lldp-results/problems-lldp_results.ini
    echo -e "\nGood news, there are no problematic ports..." >> lldp-results/problems-lldp_results.ini
fi
if ! grep -q "Created on" lldp-results/problems-lldp_results.ini; then
    header=$(head -n 1 lldp-results/raw-problems-lldp_results.ini)
    echo "$header" | cat - lldp-results/problems-lldp_results.ini > temp && mv temp lldp-results/problems-lldp_results.ini
fi

awk 'BEGIN{RS="\n\n"; ORS="\n\n"} /No-Info/' lldp-results/problems-lldp_results.ini | grep -v Fail > lldp-results/down-lldp_results.ini
if [ ! -s lldp-results/down-lldp_results.ini ]; then
    head -n 1 lldp-results/raw-problems-lldp_results.ini >> lldp-results/down-lldp_results.ini
    echo -e "\nGood news, there are no DOWN ports..." >> lldp-results/down-lldp_results.ini
fi
if ! grep -q "Created on" lldp-results/down-lldp_results.ini; then
    header=$(head -n 1 lldp-results/raw-problems-lldp_results.ini)
    echo "$header" | cat - lldp-results/down-lldp_results.ini > temp && mv temp lldp-results/down-lldp_results.ini
fi

sudo cp lldp-results/lldp_results.ini /var/www/html/
sudo mv /var/www/html/problems-lldp_results.ini /var/www/html/hstr/Problems-${DATE}.ini
sudo cp lldp-results/problems-lldp_results.ini /var/www/html/
folder_path="/var/www/html/hstr"
cd "$folder_path" || exit 1
declare -a keep_files
for i in {1..30}; do
    start_date=$(date -d "$i days ago" '+%Y-%m-%d 00:00:00')
    end_date=$(date -d "$((i - 1)) days ago" '+%Y-%m-%d 00:00:00')
    file=$(find . -type f -name "*.ini" -newermt "$start_date" ! -newermt "$end_date" | sort | head -n 1)
    if [ -n "$file" ]; then
        keep_files+=("$file")
    fi
done
recent_files=$(find . -type f -name "*.ini" -mtime -1)
for file in $recent_files; do
    keep_files+=("$file")
done
find . -type f -name "*.ini" | while read file; do
    if [[ ! " ${keep_files[@]} " =~ " ${file} " ]]; then
        sudo rm "$file"
    fi
done

rm -f "$unreachable_hosts_file"
exit 0
