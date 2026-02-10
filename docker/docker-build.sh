#!/bin/bash
# LLDPq Docker Build Script
# Builds Docker image and exports as tar.gz
#
# Usage: ./docker/docker-build.sh
# Run from repo root directory, on any machine with Docker installed
#
# Output: ~/lldpq.tar.gz

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

IMAGE_NAME="lldpq"
IMAGE_TAG="latest"
OUTPUT_FILE="$HOME/lldpq.tar.gz"

# Find repo root (script is in docker/ subfolder)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION=$(cat "$REPO_ROOT/VERSION" 2>/dev/null || echo "dev")

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    LLDPq Docker Build v${VERSION}         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# Check Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker not installed${NC}"
    exit 1
fi

echo -e "${YELLOW}[1/4]${NC} Building Docker image..."
cd "$REPO_ROOT"
sudo docker build -f docker/Dockerfile -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:${VERSION} . 2>&1 | tail -5
echo -e "${GREEN}  ✓ Built${NC}"
echo ""

echo -e "${YELLOW}[2/4]${NC} Image info:"
sudo docker images ${IMAGE_NAME} --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}'
echo ""

echo -e "${YELLOW}[3/4]${NC} Exporting to ${OUTPUT_FILE}..."
sudo docker save ${IMAGE_NAME}:${IMAGE_TAG} | gzip > "${OUTPUT_FILE}"
SIZE=$(ls -lh "${OUTPUT_FILE}" | awk '{print $5}')
echo -e "${GREEN}  ✓ Exported (${SIZE})${NC}"
echo ""

echo -e "${YELLOW}[4/4]${NC} Cleaning up old test containers..."
sudo docker rm -f lldpq-test 2>/dev/null || true
echo -e "${GREEN}  ✓ Clean${NC}"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Build Complete!                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "Image:  ${CYAN}${IMAGE_NAME}:${VERSION}${NC} (${SIZE})"
echo -e "File:   ${CYAN}${OUTPUT_FILE}${NC}"
echo ""
echo -e "Run:    ${YELLOW}docker run -d -p 80:80 -v devices.yaml:/home/lldpq/lldpq/devices.yaml lldpq:latest${NC}"
echo -e "Upload: ${YELLOW}scp ~/lldpq.tar.gz user@host:~/${NC}"
echo -e "Load:   ${YELLOW}docker load < lldpq.tar.gz${NC}"
