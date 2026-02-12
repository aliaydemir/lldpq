#!/bin/bash
# Start LLDPq Telemetry Stack (OTEL Collector + Prometheus + Alertmanager)
# Usage: ./start.sh [start|stop|restart|status|logs]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

case "${1:-start}" in
    start)
        echo "Starting LLDPq Telemetry Stack..."
        docker-compose up -d
        echo ""
        echo "Services started:"
        echo "  - OTEL Collector: http://localhost:4317 (gRPC), http://localhost:4318 (HTTP)"
        echo "  - Prometheus:     http://localhost:9090"
        echo "  - Alertmanager:   http://localhost:9093"
        echo ""
        echo "To view logs: ./start.sh logs"
        ;;
    stop)
        echo "Stopping LLDPq Telemetry Stack..."
        docker-compose down
        ;;
    restart)
        echo "Restarting LLDPq Telemetry Stack..."
        docker-compose restart
        ;;
    status)
        docker-compose ps
        ;;
    logs)
        docker-compose logs -f --tail=100
        ;;
    *)
        echo "Usage: $0 [start|stop|restart|status|logs]"
        exit 1
        ;;
esac
