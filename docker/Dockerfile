# LLDPq - Network Monitoring for Cumulus Linux Switches
# Single container: nginx + fcgiwrap + python3 + ssh + cron
FROM ubuntu:22.04

LABEL maintainer="ali@lldpq.dev"
LABEL description="LLDPq Network Monitoring"
LABEL version="2.2.3"

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install all dependencies in one layer
# bsdmainutils + bsdextrautils: 'column' command (moved in Ubuntu 22.04)
# openssh-client + sshpass: SSH to switches
# python3-yaml: devices.yaml parsing
# ruamel.yaml via pip: comment-preserving YAML editing
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx fcgiwrap \
    python3 python3-yaml python3-pip \
    openssh-client sshpass \
    sudo cron \
    iproute2 iputils-ping dnsutils tcpdump \
    curl jq git bsdmainutils bsdextrautils \
    isc-dhcp-server \
    && pip3 install --no-cache-dir ruamel.yaml requests \
    && rm -rf /var/lib/apt/lists/*

# Create lldpq user (matches host user pattern)
RUN useradd -m -s /bin/bash -G www-data lldpq \
    && echo "lldpq ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/lldpq

# Allow www-data to sudo as lldpq (for SSH operations from CGI + SSH Setup)
RUN echo "www-data ALL=(lldpq) NOPASSWD: ALL" > /etc/sudoers.d/www-data-lldpq

# Create directory structure
RUN mkdir -p /home/lldpq/lldpq/monitor-results/fabric-tables \
    && mkdir -p /var/www/html/hstr \
    && mkdir -p /var/www/html/configs \
    && mkdir -p /var/www/html/monitor-results \
    && mkdir -p /var/www/html/topology \
    && mkdir -p /home/lldpq/.ssh \
    && chmod 700 /home/lldpq/.ssh

# Copy web content
COPY html/ /var/www/html/
COPY VERSION /var/www/html/

# Copy lldpq scripts
COPY lldpq/ /home/lldpq/lldpq/
COPY bin/ /usr/local/bin/

# Copy nginx config
COPY etc/nginx/sites-available/lldpq /etc/nginx/sites-available/lldpq
RUN rm -f /etc/nginx/sites-enabled/default \
    && ln -sf /etc/nginx/sites-available/lldpq /etc/nginx/sites-enabled/lldpq

# Set ALL permissions explicitly (never rely on host umask or chmod +x)
# /var/www/html: lldpq:www-data, dirs=775, files=664, scripts=775
RUN chown -R lldpq:www-data /var/www/html/ \
    && find /var/www/html -type d -exec chmod 775 {} \; \
    && find /var/www/html -type f -exec chmod 664 {} \; \
    && find /var/www/html -name '*.sh' -exec chmod 775 {} \;
# /usr/local/bin: root-owned, readable+executable by ALL users (755)
RUN chmod 755 /usr/local/bin/*
# /home/lldpq: lldpq-owned, scripts=755
RUN chown -R lldpq:lldpq /home/lldpq/ \
    && find /home/lldpq/lldpq -name '*.sh' -exec chmod 755 {} \; \
    && find /home/lldpq/lldpq -name '*.py' -exec chmod 755 {} \;

# Setup topology files: real files in web root, symlinks in lldpq dir
# Same pattern as native install - web UI edits files in /var/www/html/
# Scripts access them via symlink in /home/lldpq/lldpq/
RUN mv /home/lldpq/lldpq/topology.dot /var/www/html/topology.dot \
    && mv /home/lldpq/lldpq/topology_config.yaml /var/www/html/topology_config.yaml \
    && ln -sf /var/www/html/topology.dot /home/lldpq/lldpq/topology.dot \
    && ln -sf /var/www/html/topology_config.yaml /home/lldpq/lldpq/topology_config.yaml \
    && chown lldpq:www-data /var/www/html/topology.dot /var/www/html/topology_config.yaml \
    && chmod 664 /var/www/html/topology.dot /var/www/html/topology_config.yaml \
    && chown lldpq:www-data /home/lldpq/lldpq/devices.yaml \
    && chmod 664 /home/lldpq/lldpq/devices.yaml

# Prepare DHCP server directories and config
RUN mkdir -p /etc/dhcp /var/lib/dhcp /var/run \
    && touch /var/lib/dhcp/dhcpd.leases \
    && touch /etc/dhcp/dhcpd.hosts \
    && chown lldpq:www-data /etc/dhcp/dhcpd.hosts \
    && chmod 664 /etc/dhcp/dhcpd.hosts

# Create lldpq config
RUN echo '# LLDPq Configuration (Docker)\n\
LLDPQ_DIR=/home/lldpq/lldpq\n\
LLDPQ_USER=lldpq\n\
WEB_ROOT=/var/www/html\n\
DHCP_HOSTS_FILE=/etc/dhcp/dhcpd.hosts\n\
DHCP_CONF_FILE=/etc/dhcp/dhcpd.conf\n\
DHCP_LEASES_FILE=/var/lib/dhcp/dhcpd.leases\n\
ZTP_SCRIPT_FILE=/var/www/html/cumulus-ztp.sh\n\
BASE_CONFIG_DIR=/home/lldpq/lldpq/sw-base\n\
ANSIBLE_DIR=NoNe' > /etc/lldpq.conf

# Create auth users file + sessions directory
# Entrypoint also recreates these if missing (self-healing)
RUN ADMIN_HASH=$(echo -n "admin" | openssl dgst -sha256 | awk '{print $2}') \
    && OPERATOR_HASH=$(echo -n "operator" | openssl dgst -sha256 | awk '{print $2}') \
    && echo "admin:$ADMIN_HASH:admin" > /etc/lldpq-users.conf \
    && echo "operator:$OPERATOR_HASH:operator" >> /etc/lldpq-users.conf \
    && chmod 600 /etc/lldpq-users.conf \
    && chown www-data:www-data /etc/lldpq-users.conf \
    && mkdir -p /var/lib/lldpq/sessions \
    && chown -R www-data:www-data /var/lib/lldpq \
    && chmod 700 /var/lib/lldpq/sessions

# Create cache files with correct permissions (assets.sh, fabric-scan, provision, AI need these)
RUN for f in device-cache.json fabric-scan-cache.json discovery-cache.json inventory.json ai-analysis.json; do \
        echo '{}' > /var/www/html/$f; \
    done \
    && chown lldpq:www-data /var/www/html/device-cache.json /var/www/html/fabric-scan-cache.json \
       /var/www/html/discovery-cache.json /var/www/html/inventory.json /var/www/html/ai-analysis.json \
    && chmod 664 /var/www/html/device-cache.json /var/www/html/fabric-scan-cache.json \
       /var/www/html/discovery-cache.json /var/www/html/inventory.json /var/www/html/ai-analysis.json

# Copy entrypoint
COPY docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]
