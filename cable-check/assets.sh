#!/bin/bash
# LLDPq Topology Check Script  
# Copyright (c) 2024 LLDPq Project - Licensed under MIT License
set -euo pipefail

#### CONFIGURATION
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
eval "$(python3 "$SCRIPT_DIR/parse_devices.py")"

TMPFILE="$SCRIPT_DIR/assets.tmp"
UNREACH="$SCRIPT_DIR/unreachable.tmp"
FINAL="$SCRIPT_DIR/assets.ini"

rm -f "$TMPFILE" "$UNREACH"

#### REMOTE INFO FUNCTION
remote_info() {
  # 1) HOSTNAME
  h="$HOSTNAME"
  # 2) IPv4
  ip4=$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)
  # 3) MAC
  mac=$(cat /sys/class/net/eth0/address 2>/dev/null)
  # 4) SERIAL
  serial=$(nv sh platform | grep serial-number | awk "{print \$2}")
  [[ -z "$serial" ]] && serial="NA"
  # 5) MODEL
  model=$(nv sh platform | grep product-name | awk "{print \$2}")
  [[ -z "$model" ]] && model="NA"
  # 6) RELEASE
  rel=$(grep RELEASE /etc/lsb-release | cut -d "=" -f2)
  # 7) UPTIME
  up=$(uptime -p | sed 's/,//g; s/ /-/g')

  # Print exactly 7 columns, fixed-width for readability
  printf '%-20s %-15s %-17s %-12s %-12s %-8s %s\n' \
    "$h" "$ip4" "$mac" "$serial" "$model" "$rel" "$up"
}

#### HEADER (7 columns)
printf '%-20s %-15s %-17s %-12s %-12s %-8s %s\n' \
  "DEVICE-NAME" "IP" "ETH0-MAC" "SERIAL" "MODEL" "RELEASE" "UPTIME" > "$TMPFILE"

#### WORKFLOW
ping_test() {
  local ip=$1 host=$2
  if ! ping -c1 -W1 "$ip" &>/dev/null; then
    echo "$host" >> "$UNREACH"
    return 1
  fi
}

collect() {
  local ip=$1 user=$2 host=$3
  ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no \
      "$user@$ip" "$(declare -f remote_info); remote_info" \
    >> "$TMPFILE" 2>/dev/null
}

process_one() {
  local ip=$1 entry=$2 user host
  read -r user host <<< "$entry"
  if ping_test "$ip" "$host"; then
    collect "$ip" "$user" "$host"
  fi
}

# Parallel execution
for ip in "${!devices[@]}"; do
  process_one "$ip" "${devices[$ip]}" &
done
wait

#### FORMAT & SORT
column -t "$TMPFILE" > "$SCRIPT_DIR/assets.sorted"
rm -f "$TMPFILE"

sort -t'.' -k1,1n -k2,2n -k3,3n -k4,4n "$SCRIPT_DIR/assets.sorted" > "$SCRIPT_DIR/assets.sorted2"
rm -f "$SCRIPT_DIR/assets.sorted"

# Append unreachable
if [[ -s "$UNREACH" ]]; then
  while read -r host; do
    # Fill all other columns with No-Info
    printf '%-20s %-15s %-17s %-12s %-12s %-8s %s\n' \
      "$host" "No-Info" "No-Info" "No-Info" "No-Info" "No-Info" "No-Info" \
      >> "$SCRIPT_DIR/assets.sorted2"
  done < "$UNREACH"
fi

mv "$SCRIPT_DIR/assets.sorted2" "$FINAL"

sudo cp "$FINAL" /var/www/html/

rm -f "$TMPFILE" "$UNREACH"

