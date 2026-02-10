# LLDPq - Network Monitoring for Cumulus Linux Switches
# Single container: nginx + fcgiwrap + python3 + ssh + cron
FROM ubuntu:22.04

LABEL maintainer="aaydemir@nvidia.com"
LABEL description="LLDPq Network Monitoring"
LABEL version="2.2.3"

# Prevent interactive prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install all dependencies in one layer
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    fcgiwrap \
    python3 \
    python3-yaml \
    python3-pip \
    openssh-client \
    sudo \
    cron \
    iproute2 \
    iputils-ping \
    dnsutils \
    curl \
    jq \
    git \
    && rm -rf /var/lib/apt/lists/*

# Create lldpq user (matches host user pattern)
RUN useradd -m -s /bin/bash -G www-data lldpq \
    && echo "lldpq ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/lldpq

# Allow www-data to sudo as lldpq (for SSH operations from CGI)
RUN echo "www-data ALL=(lldpq) NOPASSWD: /usr/bin/timeout, /usr/bin/ssh" > /etc/sudoers.d/www-data-lldpq

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

# Set permissions
RUN chown -R lldpq:www-data /var/www/html/ \
    && find /var/www/html -type d -exec chmod 775 {} \; \
    && find /var/www/html -type f -exec chmod 664 {} \; \
    && chmod +x /var/www/html/*.sh \
    && chown -R lldpq:lldpq /home/lldpq/ \
    && chmod +x /usr/local/bin/pping /usr/local/bin/zzh /usr/local/bin/send-cmd \
    && chmod +x /home/lldpq/lldpq/*.sh /home/lldpq/lldpq/*.py 2>/dev/null || true

# Create lldpq config
RUN echo '# LLDPq Configuration (Docker)\n\
LLDPQ_DIR=/home/lldpq/lldpq\n\
LLDPQ_USER=lldpq\n\
WEB_ROOT=/var/www/html' > /etc/lldpq.conf

# Copy entrypoint
COPY docker/docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/docker-entrypoint.sh"]
