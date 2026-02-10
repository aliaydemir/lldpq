#!/bin/bash
# LLDPq Docker Entrypoint
# Starts: nginx + fcgiwrap + cron

set -e

echo "╔══════════════════════════════════════╗"
echo "║      LLDPq Network Monitoring        ║"
echo "║      Docker Container v$(cat /var/www/html/VERSION 2>/dev/null || echo '?')        ║"
echo "╚══════════════════════════════════════╝"

# ─── SSH Key Setup ───
if [ -f /home/lldpq/.ssh/id_rsa ] || [ -f /home/lldpq/.ssh/id_ed25519 ]; then
    echo "✓ SSH keys found"
else
    echo "⚠ No SSH keys yet"
    echo "  Run: docker exec -it lldpq bash"
    echo "  Then: cd ~/lldpq && ./send-key.sh"
fi

# ─── devices.yaml Setup ───
# If devices.yaml is mounted, symlink it
if [ -f /home/lldpq/lldpq/devices.yaml ]; then
    chown lldpq:www-data /home/lldpq/lldpq/devices.yaml
    chmod 664 /home/lldpq/lldpq/devices.yaml
    echo "✓ devices.yaml loaded ($(grep -c '^\s*[0-9]' /home/lldpq/lldpq/devices.yaml 2>/dev/null || echo 0) devices)"
else
    echo "⚠ No devices.yaml found"
    echo "  Mount with: -v /path/to/devices.yaml:/home/lldpq/lldpq/devices.yaml"
fi

# ─── Persistent data directories ───
# Ensure correct ownership for mounted volumes
for dir in /home/lldpq/lldpq/monitor-results \
           /var/www/html/hstr \
           /var/www/html/configs \
           /var/www/html/monitor-results \
           /var/www/html/topology; do
    mkdir -p "$dir"
    chown -R lldpq:www-data "$dir"
    chmod 775 "$dir"
done

# Symlink monitor-results to web root
ln -sf /home/lldpq/lldpq/monitor-results /var/www/html/monitor-results 2>/dev/null || true

# ─── Cron Setup ───
# Setup cron jobs for lldpq user
cat > /etc/cron.d/lldpq << 'CRON'
# LLDPq monitoring - every 5 minutes
*/5 * * * * lldpq cd /home/lldpq/lldpq && ./check-lldp.sh > /dev/null 2>&1 && ./monitor.sh > /dev/null 2>&1
# Fabric scan - every minute
* * * * * lldpq cd /home/lldpq/lldpq && ./fabric-scan.sh > /dev/null 2>&1
# Config backup - every 12 hours
0 */12 * * * lldpq /usr/local/bin/get-conf > /dev/null 2>&1
CRON
chmod 644 /etc/cron.d/lldpq

# ─── Start Services ───
echo ""
echo "Starting services..."

# Start cron
service cron start > /dev/null 2>&1
echo "  ✓ cron"

# Start fcgiwrap (as www-data for CGI scripts)
/usr/sbin/fcgiwrap -f -s unix:/var/run/fcgiwrap.socket &
sleep 0.5
# Fix socket permissions so nginx can connect
chown www-data:www-data /var/run/fcgiwrap.socket
chmod 660 /var/run/fcgiwrap.socket
echo "  ✓ fcgiwrap"

# Start nginx (foreground - keeps container alive)
echo "  ✓ nginx (port 80)"
echo ""
echo "LLDPq is ready! Access: http://localhost:${LLDPQ_PORT:-80}"
echo ""

exec nginx -g 'daemon off;'
