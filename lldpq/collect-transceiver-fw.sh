#!/usr/bin/env bash
# collect-transceiver-fw.sh - Collect transceiver firmware versions via mlxlink
# Runs independently from monitor.sh, CLI only (not triggered from web UI)
# Skips known-risk models before running mlxlink
#
# Copyright (c) 2024-2026 LLDPq Project
# Licensed under MIT License - see LICENSE file for details

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

source /etc/lldpq.conf 2>/dev/null || true
WEB_ROOT="${WEB_ROOT:-/var/www/html}"

parse_devices_output=$(python3 "$SCRIPT_DIR/parse_devices.py")
parse_devices_status=$?
if [ $parse_devices_status -ne 0 ]; then
    echo "ERROR: Unable to parse devices.yaml" >&2
    exit 1
fi
if ! eval "$parse_devices_output"; then
    echo "ERROR: Unable to load parsed device list" >&2
    exit 1
fi
if [ ${#devices[@]} -eq 0 ]; then
    echo "ERROR: No devices found in devices.yaml" >&2
    exit 1
fi

RESULT_DIR="$SCRIPT_DIR/monitor-results"
TRANSCEIVER_DIR="$RESULT_DIR/transceiver-data"
INVENTORY_JSON="$RESULT_DIR/transceiver_inventory.json"
WEB_MONITOR_DIR="$WEB_ROOT/monitor-results"

# Build model map (hostname -> model) from assets.ini
declare -A device_models
if [ -f "$SCRIPT_DIR/assets.ini" ]; then
    while IFS= read -r line; do
        hostname=$(echo "$line" | awk '{print $1}')
        model=$(echo "$line" | awk '{print $5}')
        [ -n "$hostname" ] && [ -n "$model" ] && device_models["$hostname"]="$model"
    done < <(grep -v "^DEVICE-NAME\|^Created\|^$" "$SCRIPT_DIR/assets.ini")
else
    echo "WARN: assets.ini not found; model checks will use remote fallback before mlxlink"
fi

# Models to skip (mlxlink can cause ASIC reset on these platforms).
# SN2010, SN2100, SN2201, and SN2210 are always skipped.
# Add more models in /etc/lldpq.conf:
#   TRANSCEIVER_FW_SKIP_MODELS="2410"
TRANSCEIVER_FW_SKIP_MODELS="2010 2100 2201 2210 ${TRANSCEIVER_FW_SKIP_MODELS:-}"
TRANSCEIVER_FW_UNKNOWN_MODEL_POLICY="${TRANSCEIVER_FW_UNKNOWN_MODEL_POLICY:-skip}"
case "$TRANSCEIVER_FW_UNKNOWN_MODEL_POLICY" in
    run|skip) ;;
    *) TRANSCEIVER_FW_UNKNOWN_MODEL_POLICY="skip" ;;
esac
SKIP_MODEL_PATTERN=$(printf '%s' "$TRANSCEIVER_FW_SKIP_MODELS" | tr -cs '[:alnum:]_.-' ',')
SKIP_MODEL_PATTERN=${SKIP_MODEL_PATTERN#,}
SKIP_MODEL_PATTERN=${SKIP_MODEL_PATTERN%,}

SSH_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR)
MAX_PARALLEL="${TRANSCEIVER_FW_MAX_PARALLEL:-10}"
case "$MAX_PARALLEL" in
    ''|*[!0-9]*|0) MAX_PARALLEL=10 ;;
esac

mkdir -p "$TRANSCEIVER_DIR"
STATUS_DIR=$(mktemp -d "$RESULT_DIR/transceiver-status.XXXXXX")
trap 'rm -rf "$STATUS_DIR"' EXIT

status_file_for() {
    local hostname=$1
    local safe
    safe=$(printf '%s' "$hostname" | tr -c '[:alnum:]_.-' '_')
    printf '%s/%s.status' "$STATUS_DIR" "$safe"
}

write_status() {
    local hostname=$1
    local status=$2
    local detail=${3:-}
    printf '%s|%s\n' "$status" "$detail" > "$(status_file_for "$hostname")"
}

write_transceiver_marker() {
    local hostname=$1
    local reason=$2
    printf '# %s\n' "$reason" > "$TRANSCEIVER_DIR/${hostname}_transceiver.txt"
}

is_unknown_model() {
    local model=$1
    local normalized_model

    normalized_model=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')
    case "$normalized_model" in
        ""|"NA"|"N/A"|"NO-INFO"|"NO_INFO"|"UNKNOWN")
            return 0
            ;;
    esac
    return 1
}

model_matches_skip() {
    local model=$1
    local token
    local normalized_model
    local normalized_token

    [ -z "$model" ] && return 1
    normalized_model=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')
    for token in $TRANSCEIVER_FW_SKIP_MODELS; do
        [ -z "$token" ] && continue
        normalized_token=$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')
        [[ "$normalized_model" == *"$normalized_token"* ]] && return 0
    done
    return 1
}

collect_fw() {
    local device=$1
    local user=$2
    local hostname=$3
    local known_model=${4:-}
    local outfile="$TRANSCEIVER_DIR/${hostname}_transceiver.txt"
    local output
    local ssh_status
    local first_line
    local detail

    rm -f "$outfile"

    output=$(timeout 120 ssh "${SSH_OPTS[@]}" -q "$user@$device" bash -s -- "$SKIP_MODEL_PATTERN" "$TRANSCEIVER_FW_UNKNOWN_MODEL_POLICY" "$known_model" <<'REMOTE_SCRIPT' 2>/dev/null
        skip_model_pattern=${1:-2010,2201,2210}
        unknown_model_policy=${2:-skip}
        known_model=${3:-}

        is_unknown_model() {
            local model=$1
            local normalized_model

            normalized_model=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')
            case "$normalized_model" in
                ""|"NA"|"N/A"|"NO-INFO"|"NO_INFO"|"UNKNOWN")
                    return 0
                    ;;
            esac
            return 1
        }

        get_model() {
            local model=""
            local file

            for file in /sys/devices/virtual/dmi/id/product_name /sys/class/dmi/id/product_name; do
                if [ -r "$file" ]; then
                    model=$(head -1 "$file" 2>/dev/null | xargs)
                    [ -n "$model" ] && break
                fi
            done

            if [ -z "$model" ] && command -v dmidecode >/dev/null 2>&1; then
                model=$(sudo -n dmidecode -s system-product-name 2>/dev/null | head -1 | xargs)
            fi

            if [ -z "$model" ] && command -v nv >/dev/null 2>&1; then
                model=$(nv show platform hardware 2>/dev/null | awk -F: '/Product Name|Model|Platform/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit}' | xargs)
            fi

            if is_unknown_model "$model"; then
                if ! is_unknown_model "$known_model"; then
                    model="$known_model"
                else
                    model=""
                fi
            fi
            printf '%s\n' "$model"
        }

        matches_skip_model() {
            local model=$1
            local token
            local normalized_model
            local normalized_token
            local old_ifs

            [ -z "$model" ] && return 1
            normalized_model=$(printf '%s' "$model" | tr '[:lower:]' '[:upper:]')
            old_ifs=$IFS
            IFS=,
            for token in $skip_model_pattern; do
                [ -z "$token" ] && continue
                normalized_token=$(printf '%s' "$token" | tr '[:lower:]' '[:upper:]')
                case "$normalized_model" in
                    *"$normalized_token"*) IFS=$old_ifs; return 0 ;;
                esac
            done
            IFS=$old_ifs
            return 1
        }

        model=$(get_model)
        if matches_skip_model "$model"; then
            echo "__LLDPQ_SKIPPED_MODEL__|$model"
            exit 0
        fi

        if [ -z "$model" ] && [ "$unknown_model_policy" = "skip" ]; then
            echo "__LLDPQ_SKIPPED_UNKNOWN_MODEL__|unknown"
            exit 0
        fi

        all_interfaces=$(ip link show | awk "/^[0-9]+: swp[0-9]+[s0-9]*/ {gsub(/:/, \"\", \$2); print \$2}")
        MST_DEV=$(ls /dev/mst/ 2>/dev/null | grep pciconf0 | head -1)
        if [ -n "$MST_DEV" ]; then
            done_ports=""
            for iface in $all_interfaces; do
                port_num=$(echo "$iface" | sed "s/swp//" | sed "s/s.*//")
                case " $done_ports " in *" $port_num "*) continue ;; esac
                done_ports="$done_ports $port_num"
                FW=$(timeout 5 sudo mlxlink -d /dev/mst/$MST_DEV -m -p $port_num 2>/dev/null | grep "FW Version" | grep -v "N/A")
                if [ -n "$FW" ]; then
                    echo "swp${port_num}|${FW}"
                fi
            done
        fi
REMOTE_SCRIPT
    )
    ssh_status=$?

    if [ $ssh_status -ne 0 ]; then
        write_status "$hostname" "failed" "ssh_or_timeout"
        echo "  $hostname: failed"
        return
    fi

    first_line=$(printf '%s\n' "$output" | head -1)
    case "$first_line" in
        __LLDPQ_SKIPPED_MODEL__\|*)
            detail=${first_line#__LLDPQ_SKIPPED_MODEL__|}
            write_transceiver_marker "$hostname" "skipped model ${detail:-unknown}"
            write_status "$hostname" "skipped_model" "$detail"
            echo "  $hostname: skipped model ${detail:-unknown}"
            return
            ;;
        __LLDPQ_SKIPPED_UNKNOWN_MODEL__\|*)
            write_transceiver_marker "$hostname" "skipped unknown model"
            write_status "$hostname" "skipped_unknown_model" "unknown"
            echo "  $hostname: skipped unknown model"
            return
            ;;
    esac

    if [ -n "$output" ]; then
        printf '%s\n' "$output" > "$outfile"
        write_status "$hostname" "ok" "$(printf '%s\n' "$output" | wc -l | xargs)"
        echo "  $hostname: $(echo "$output" | wc -l) modules"
    else
        write_transceiver_marker "$hostname" "no firmware data"
        write_status "$hostname" "no_modules" ""
        echo "  $hostname: no firmware data"
    fi
}

count_status() {
    local status=$1
    local count=0
    local file

    for file in "$STATUS_DIR"/*.status; do
        [ -e "$file" ] || continue
        if grep -q "^${status}|" "$file"; then
            count=$((count + 1))
        fi
    done
    printf '%s\n' "$count"
}

publish_inventory() {
    if [ ! -f "$INVENTORY_JSON" ]; then
        echo "ERROR: Inventory JSON was not created: $INVENTORY_JSON" >&2
        return 1
    fi

    if mkdir -p "$WEB_MONITOR_DIR" 2>/dev/null && cp "$INVENTORY_JSON" "$WEB_MONITOR_DIR/" 2>/dev/null; then
        chown "$(whoami):www-data" "$WEB_MONITOR_DIR/$(basename "$INVENTORY_JSON")" 2>/dev/null || true
        chmod 664 "$WEB_MONITOR_DIR/$(basename "$INVENTORY_JSON")" 2>/dev/null || true
        return 0
    fi

    if command -v sudo >/dev/null 2>&1 && sudo -n mkdir -p "$WEB_MONITOR_DIR" 2>/dev/null && sudo -n cp "$INVENTORY_JSON" "$WEB_MONITOR_DIR/" 2>/dev/null; then
        sudo -n chown "${LLDPQ_USER:-$(whoami)}:www-data" "$WEB_MONITOR_DIR/$(basename "$INVENTORY_JSON")" 2>/dev/null || true
        sudo -n chmod 664 "$WEB_MONITOR_DIR/$(basename "$INVENTORY_JSON")" 2>/dev/null || true
        return 0
    fi

    echo "WARN: Could not publish inventory to $WEB_MONITOR_DIR" >&2
    return 1
}

echo "Collecting transceiver firmware versions..."
queued=0
pids=()
for device in "${!devices[@]}"; do
    IFS=' ' read -r user hostname <<< "${devices[$device]}"

    model="${device_models[$hostname]:-}"
    if is_unknown_model "$model"; then
        model=""
    fi
    if model_matches_skip "$model"; then
        write_transceiver_marker "$hostname" "skipped model $model"
        write_status "$hostname" "skipped_model" "$model"
        echo "  $hostname: skipped model $model"
        continue
    fi

    ((queued++))
    collect_fw "$device" "$user" "$hostname" "$model" &
    pids+=($!)

    if [ ${#pids[@]} -ge $MAX_PARALLEL ]; then
        wait "${pids[0]}" || true
        pids=("${pids[@]:1}")
    fi
done
wait || true

ok_count=$(count_status "ok")
no_modules_count=$(count_status "no_modules")
failed_count=$(count_status "failed")
skipped_model_count=$(count_status "skipped_model")
skipped_unknown_count=$(count_status "skipped_unknown_model")
skipped_total=$((skipped_model_count + skipped_unknown_count))

echo "Queried: $queued devices"
echo "Collected: $ok_count with FW data, $no_modules_count no FW data, $failed_count failed, $skipped_total skipped"
echo "Processing inventory..."

if [ ! -d "$RESULT_DIR/optical-data" ]; then
    echo "ERROR: Missing $RESULT_DIR/optical-data; run monitor.sh first to collect optical inventory" >&2
    exit 1
fi

if ! python3 "$SCRIPT_DIR/process_transceiver_data.py"; then
    echo "ERROR: Failed to process transceiver inventory" >&2
    exit 1
fi

chown "$(whoami):www-data" "$INVENTORY_JSON" 2>/dev/null || true
chmod 664 "$INVENTORY_JSON" 2>/dev/null || true
publish_inventory || true
echo "Done"
