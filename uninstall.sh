#!/usr/bin/env bash
# LLDPq Uninstaller — removes everything install.sh sets up
#
# Usage:
#   ./uninstall.sh            # interactive (asks for confirmation)
#   ./uninstall.sh -y         # auto-yes
#   ./uninstall.sh --dry-run  # show what would be removed, do nothing
#   ./uninstall.sh --keep-data  # keep monitor-results/lldp-results/devices.yaml
#   ./uninstall.sh --remove-docker # also remove Docker packages and data
#   ./uninstall.sh --remove-dhcp   # also remove isc-dhcp-server package/config
#
# What it removes:
#   - LLDPq cron entries (/etc/crontab + /etc/cron.d/lldpq)
#   - lldpq-trigger daemon process
#   - /usr/local/bin/{lldpq, lldpq-trigger, lldpq-ai-analyze, zzh, pping, send-cmd, get-conf}
#   - /var/www/html web content (nginx + fcgiwrap site removed)
#   - $LLDPQ_INSTALL_DIR (default ~/lldpq)
#   - /etc/lldpq.conf, /etc/lldpq.conf.lock, /etc/lldpq-users.conf
#   - /var/lib/lldpq (sessions)
#   - /etc/sudoers.d/{www-data-lldpq, www-data-provision}
#   - /etc/nginx/sites-{available,enabled}/lldpq + reload nginx
#   - LLDPq DHCP config markers (does NOT touch dhcp service itself unless --remove-dhcp)
#   - Telemetry docker stack + volumes (always)
#   - User www-data from $LLDPQ_USER group (best effort)

set -u
set -o pipefail

# ─── Args ──────────────────────────────────────────────────────────────
AUTO_YES=false
DRY_RUN=false
KEEP_DATA=false
REMOVE_DHCP=false
REMOVE_NGINX_PKG=false
REMOVE_DOCKER_PKG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes) AUTO_YES=true ;;
        --dry-run) DRY_RUN=true ;;
        --keep-data) KEEP_DATA=true ;;
        --remove-dhcp) REMOVE_DHCP=true ;;
        --remove-nginx) REMOVE_NGINX_PKG=true ;;
        --remove-docker) REMOVE_DOCKER_PKG=true ;;
        -h|--help)
            sed -n '1,30p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

# ─── Colors ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

run() {
    if $DRY_RUN; then
        echo "DRY-RUN  $*"
    else
        eval "$@"
    fi
}

step() {
    echo ""
    echo -e "${CYAN}→ $1${NC}"
}

# ─── Detect install paths ─────────────────────────────────────────────
LLDPQ_INSTALL_DIR=""
LLDPQ_USER=""
WEB_ROOT="/var/www/html"

if [[ -f /etc/lldpq.conf ]]; then
    # shellcheck disable=SC1091
    source /etc/lldpq.conf 2>/dev/null || true
    LLDPQ_INSTALL_DIR="${LLDPQ_DIR:-}"
    LLDPQ_USER="${LLDPQ_USER:-}"
    WEB_ROOT="${WEB_ROOT:-/var/www/html}"
fi

if [[ -z "$LLDPQ_INSTALL_DIR" ]]; then
    if [[ $EUID -eq 0 ]]; then
        LLDPQ_INSTALL_DIR="/opt/lldpq"
    else
        LLDPQ_INSTALL_DIR="$HOME/lldpq"
    fi
fi

[[ -z "$LLDPQ_USER" ]] && LLDPQ_USER="$(whoami)"

# ─── Banner ───────────────────────────────────────────────────────────
echo -e "${YELLOW}LLDPq Uninstall${NC}"
echo "================================================"
echo "Install dir:    $LLDPQ_INSTALL_DIR"
echo "Install user:   $LLDPQ_USER"
echo "Web root:       $WEB_ROOT"
echo "Dry run:        $DRY_RUN"
echo "Keep data:      $KEEP_DATA"
echo "Remove DHCP:    $REMOVE_DHCP"
echo "Remove nginx:   $REMOVE_NGINX_PKG"
echo "Remove docker:  $REMOVE_DOCKER_PKG"
echo "================================================"

if ! $AUTO_YES && ! $DRY_RUN; then
    echo -e "${RED}This will permanently remove LLDPq from this system.${NC}"
    read -p "Type 'YES' to continue: " confirm
    if [[ "$confirm" != "YES" ]]; then
        echo "Aborted."
        exit 1
    fi
fi

# ─── 1. Stop running processes ────────────────────────────────────────
step "Stopping LLDPq processes..."
for proc in lldpq-trigger lldpq-ai-analyze fabric-scan.sh monitor.sh check-lldp.sh assets.sh; do
    if pgrep -f "/usr/local/bin/$proc" >/dev/null 2>&1 || \
       pgrep -f "$LLDPQ_INSTALL_DIR/$proc" >/dev/null 2>&1; then
        run "sudo pkill -f '$proc' 2>/dev/null || true"
        echo "  killed $proc"
    fi
done

# ─── 2. Telemetry stack ───────────────────────────────────────────────
step "Removing telemetry stack..."
if [[ -f "$LLDPQ_INSTALL_DIR/telemetry/docker-compose.yaml" ]]; then
    if command -v docker >/dev/null 2>&1; then
        run "(cd '$LLDPQ_INSTALL_DIR/telemetry' && (docker compose down -v 2>/dev/null || docker-compose down -v 2>/dev/null || sudo docker compose down -v 2>/dev/null || sudo docker-compose down -v 2>/dev/null || true))"
    fi
    echo "  telemetry containers + volumes removed"
fi

# ─── 3. Cron jobs ─────────────────────────────────────────────────────
step "Removing LLDPq cron jobs..."
if [[ -f /etc/crontab ]]; then
    run "sudo sed -i '/lldpq\\|monitor\\|get-conf\\|fabric-scan\\|ai-analyze/d' /etc/crontab"
    echo "  /etc/crontab cleaned"
fi
if [[ -f /etc/cron.d/lldpq ]]; then
    run "sudo rm -f /etc/cron.d/lldpq"
    echo "  /etc/cron.d/lldpq removed"
fi

# ─── 4. Bin scripts ───────────────────────────────────────────────────
step "Removing CLI tools..."
for bin in lldpq lldpq-trigger lldpq-ai-analyze zzh pping send-cmd get-conf netprobe-ai; do
    if [[ -e "/usr/local/bin/$bin" ]]; then
        run "sudo rm -f /usr/local/bin/$bin"
        echo "  removed /usr/local/bin/$bin"
    fi
done

# ─── 5. Sudoers ───────────────────────────────────────────────────────
step "Removing sudoers files..."
for f in www-data-lldpq www-data-provision; do
    if [[ -f "/etc/sudoers.d/$f" ]]; then
        run "sudo rm -f /etc/sudoers.d/$f"
        echo "  removed /etc/sudoers.d/$f"
    fi
done

# ─── 6. Auth + sessions + config ──────────────────────────────────────
step "Removing config + auth files..."
for f in /etc/lldpq.conf /etc/lldpq.conf.lock /etc/lldpq-users.conf; do
    if [[ -e "$f" ]]; then
        run "sudo rm -f '$f'"
        echo "  removed $f"
    fi
done
if [[ -d /var/lib/lldpq ]]; then
    run "sudo rm -rf /var/lib/lldpq"
    echo "  removed /var/lib/lldpq"
fi

# ─── 7. nginx site ────────────────────────────────────────────────────
step "Removing nginx site..."
if [[ -L /etc/nginx/sites-enabled/lldpq ]] || [[ -f /etc/nginx/sites-enabled/lldpq ]]; then
    run "sudo rm -f /etc/nginx/sites-enabled/lldpq"
    echo "  removed sites-enabled/lldpq"
fi
if [[ -f /etc/nginx/sites-available/lldpq ]]; then
    run "sudo rm -f /etc/nginx/sites-available/lldpq"
    echo "  removed sites-available/lldpq"
fi
if command -v nginx >/dev/null 2>&1; then
    run "sudo nginx -t >/dev/null 2>&1 && sudo systemctl reload nginx 2>/dev/null || true"
fi

# ─── 8. Web content ───────────────────────────────────────────────────
step "Removing web content under $WEB_ROOT..."
WEB_TARGETS=(
    "$WEB_ROOT/index.html" "$WEB_ROOT/login.html" "$WEB_ROOT/start.html"
    "$WEB_ROOT/assets.html" "$WEB_ROOT/device.html" "$WEB_ROOT/configs.html"
    "$WEB_ROOT/lldp.html" "$WEB_ROOT/lldp-problem.html" "$WEB_ROOT/archive.html"
    "$WEB_ROOT/dev-conf.html" "$WEB_ROOT/edit-config.sh" "$WEB_ROOT/edit-devices.sh"
    "$WEB_ROOT/edit-topology.sh" "$WEB_ROOT/editor-test.html"
    "$WEB_ROOT/fabric-api.sh" "$WEB_ROOT/fabric-config.html" "$WEB_ROOT/fabric-deploy.html"
    "$WEB_ROOT/fabric-editor.html" "$WEB_ROOT/fabric-exit.html"
    "$WEB_ROOT/auth-api.sh" "$WEB_ROOT/ansible-api.sh"
    "$WEB_ROOT/ai-api.sh" "$WEB_ROOT/ai.html"
    "$WEB_ROOT/provision.html" "$WEB_ROOT/provision-api.sh"
    "$WEB_ROOT/search.html" "$WEB_ROOT/search-api.sh"
    "$WEB_ROOT/setup-api.sh" "$WEB_ROOT/telemetry.html"
    "$WEB_ROOT/tracepath.html" "$WEB_ROOT/transceiver.html"
    "$WEB_ROOT/vlan-report.html" "$WEB_ROOT/vrf-report.html"
    "$WEB_ROOT/lldpq-ztp-new-device-flow.html"
    "$WEB_ROOT/trigger-assets.sh" "$WEB_ROOT/trigger-configs.sh"
    "$WEB_ROOT/trigger-lldp.sh" "$WEB_ROOT/trigger-monitor.sh"
    "$WEB_ROOT/cumulus-ztp.sh" "$WEB_ROOT/serial-mapping.txt"
    "$WEB_ROOT/topology.dot" "$WEB_ROOT/topology_config.yaml"
    "$WEB_ROOT/VERSION"
    "$WEB_ROOT/device-cache.json" "$WEB_ROOT/fabric-scan-cache.json"
    "$WEB_ROOT/discovery-cache.json" "$WEB_ROOT/inventory.json"
    "$WEB_ROOT/ai-analysis.json"
)
WEB_DIRS=(
    "$WEB_ROOT/css" "$WEB_ROOT/png" "$WEB_ROOT/topology"
    "$WEB_ROOT/configs" "$WEB_ROOT/hstr" "$WEB_ROOT/monitor-results"
    "$WEB_ROOT/generated_config_folder" "$WEB_ROOT/monaco"
)

for f in "${WEB_TARGETS[@]}"; do
    [[ -e "$f" ]] && run "sudo rm -f '$f'" && echo "  removed $f"
done
for d in "${WEB_DIRS[@]}"; do
    if $KEEP_DATA && [[ "$d" == *"monitor-results"* || "$d" == *"configs"* || "$d" == *"hstr"* ]]; then
        echo "  kept $d (--keep-data)"
        continue
    fi
    [[ -d "$d" ]] && run "sudo rm -rf '$d'" && echo "  removed $d"
done

# ─── 9. Install directory ─────────────────────────────────────────────
step "Removing install directory..."
if [[ -d "$LLDPQ_INSTALL_DIR" ]]; then
    if $KEEP_DATA; then
        # Keep monitor-results / lldp-results / alert-states / devices.yaml
        run "find '$LLDPQ_INSTALL_DIR' -mindepth 1 -maxdepth 1 ! -name 'monitor-results' ! -name 'lldp-results' ! -name 'alert-states' ! -name 'devices.yaml' ! -name 'notifications.yaml' -exec sudo rm -rf {} +"
        echo "  cleaned $LLDPQ_INSTALL_DIR (kept data)"
    else
        run "sudo rm -rf '$LLDPQ_INSTALL_DIR'"
        echo "  removed $LLDPQ_INSTALL_DIR"
    fi
fi

# ─── 10. DHCP config (LLDPq markers only) ────────────────────────────
step "Cleaning DHCP markers..."
if $REMOVE_DHCP; then
    run "sudo systemctl stop isc-dhcp-server 2>/dev/null || true"
    run "sudo systemctl disable isc-dhcp-server 2>/dev/null || true"
    for f in /etc/dhcp/dhcpd.conf /etc/dhcp/dhcpd.hosts /etc/default/isc-dhcp-server /var/lib/dhcp/dhcpd.leases; do
        [[ -e "$f" ]] && run "sudo rm -f '$f'" && echo "  removed $f"
    done
    run "sudo apt-get remove -y --purge isc-dhcp-server >/dev/null 2>&1 || true"
else
    echo "  --remove-dhcp not set, leaving DHCP service config alone"
fi

# ─── 11. Group membership cleanup ─────────────────────────────────────
step "Cleaning group memberships..."
if id www-data >/dev/null 2>&1; then
    run "sudo gpasswd -d www-data '$LLDPQ_USER' 2>/dev/null || true"
    run "sudo gpasswd -d '$LLDPQ_USER' www-data 2>/dev/null || true"
    echo "  removed group cross-membership"
fi

# ─── 12. Optional package removal ─────────────────────────────────────
if $REMOVE_NGINX_PKG; then
    step "Removing nginx + fcgiwrap packages..."
    run "sudo systemctl stop nginx fcgiwrap 2>/dev/null || true"
    run "sudo apt-get remove -y --purge nginx fcgiwrap >/dev/null 2>&1 || true"
fi

if $REMOVE_DOCKER_PKG; then
    step "Removing Docker packages..."
    run "sudo systemctl stop docker 2>/dev/null || true"
    run "sudo apt-get remove -y --purge docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin >/dev/null 2>&1 || true"
    run "sudo rm -rf /var/lib/docker /var/lib/containerd 2>/dev/null || true"
fi

# ─── Done ─────────────────────────────────────────────────────────────
echo ""
if $DRY_RUN; then
    echo -e "${YELLOW}Dry run complete. No changes were made.${NC}"
else
    echo -e "${GREEN}LLDPq has been uninstalled.${NC}"
fi
echo ""
echo "Verify with:"
echo "  ls /etc/lldpq* 2>/dev/null   # should be empty"
echo "  ls $LLDPQ_INSTALL_DIR 2>/dev/null  # should not exist"
echo "  systemctl status nginx       # nginx state (if you kept it)"
echo "  crontab -l; cat /etc/crontab # no LLDPq lines"
