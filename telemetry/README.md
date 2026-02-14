# LLDPq Streaming Telemetry

This directory contains the Docker Compose configuration for running the LLDPq telemetry stack.

## Components

- **OpenTelemetry Collector**: Receives OTLP telemetry from Cumulus Linux switches
- **Prometheus**: Stores and queries time-series metrics
- **Alertmanager**: Handles alerts based on Prometheus rules

## Quick Start

```bash
# Start the telemetry stack
./start.sh start

# Check status
./start.sh status

# View logs
./start.sh logs

# Stop the stack
./start.sh stop
```

## Configuration

### OTEL Collector (`config/otel-config.yaml`)
- Listens on port 4317 (gRPC) and 4318 (HTTP)
- Exports metrics to Prometheus exporter on port 8889

### Prometheus (`config/prometheus.yaml`)
- Scrapes metrics from OTEL Collector
- Stores data for 30 days
- Evaluates alert rules every 15 seconds

### Alertmanager (`config/alertmanager.yaml`)
- Edit this file to configure notification channels (Slack, email, etc.)

### Alert Rules (`config/alert_rules.yaml`)
- Pre-configured alerts for:
  - Interface down
  - High interface utilization (>80%)
  - High error/drop rates
  - BGP session down
  - High CPU temperature
  - Fan failure

## Stack Management

The telemetry stack (Docker containers) is managed separately from device configuration:

```bash
# Start stack
./install.sh --enable-telemetry

# Stop stack
./install.sh --disable-telemetry
```

The stack runs continuously once started. Enabling/disabling telemetry on devices does NOT stop the stack.

## Enabling Telemetry on Switches

From the LLDPq web interface:
1. Navigate to **Telemetry** page
2. Click **Enable Telemetry**
3. Enter the OTEL Collector IP (this server's IP)
4. Select devices (grouped by inventory)
5. Click **Enable on Selected Devices**

Or manually on each switch:

```bash
nv set system telemetry ai-ethernet-stats export state enabled
nv set system telemetry ai-ethernet-stats sample-interval 30
nv set system telemetry export otlp grpc destination <COLLECTOR_IP> port 4317
nv set system telemetry export otlp grpc insecure enabled
nv set system telemetry export otlp state enabled
nv set system telemetry export vrf mgmt
nv set system telemetry interface-stats export state enabled
nv set system telemetry interface-stats sample-interval 30
nv config apply -y
```

## LLDPq Configuration

Add Prometheus URL to `/etc/lldpq.conf`:

```bash
PROMETHEUS_URL=http://localhost:9090
```

## Ports

| Service | Port | Description |
|---------|------|-------------|
| OTEL Collector | 4317 | OTLP gRPC receiver |
| OTEL Collector | 4318 | OTLP HTTP receiver |
| OTEL Collector | 8889 | Prometheus exporter |
| Prometheus | 9090 | Web UI & API |
| Alertmanager | 9093 | Web UI & API |

## Troubleshooting

### Check if telemetry is being received:

```bash
# Check OTEL collector logs
docker logs lldpq-otel-collector

# Query Prometheus for metrics
curl 'http://localhost:9090/api/v1/query?query=up'
curl 'http://localhost:9090/api/v1/query?query=cumulus_nvswitch_interface_if_out_octets'
```

### Verify switch telemetry config:

```bash
nv show system telemetry
```
