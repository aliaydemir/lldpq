#!/bin/bash
# LLDPq Docker Build Script
# Builds Docker image on nvidia server and exports as tar.gz
#
# Usage: ./docker-build.sh
#
# Output: ~/lldpq.tar.gz

set -e

BUILD_HOST="nvidia"
BUILD_DIR="~/lldpq-docker"
IMAGE_NAME="lldpq"
IMAGE_TAG="latest"
OUTPUT_FILE="~/lldpq.tar.gz"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║    LLDPq Docker Build Script         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# Get script directory (repo root)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "dev")

echo -e "${YELLOW}[1/5]${NC} Syncing repo to ${BUILD_HOST}..."
rsync -avz --delete \
    --exclude='.git' \
    --exclude='.cursor' \
    --exclude='assets' \
    --exclude='*.tar.gz' \
    "$SCRIPT_DIR/" "${BUILD_HOST}:${BUILD_DIR}/" 2>&1 | tail -3
echo -e "${GREEN}  ✓ Synced${NC}"
echo ""

echo -e "${YELLOW}[2/5]${NC} Building Docker image (${IMAGE_NAME}:${IMAGE_TAG})..."
ssh "$BUILD_HOST" "cd ${BUILD_DIR} && sudo docker build -f docker/Dockerfile -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:${VERSION} . 2>&1" | tail -5
echo -e "${GREEN}  ✓ Built${NC}"
echo ""

echo -e "${YELLOW}[3/5]${NC} Image info:"
ssh "$BUILD_HOST" "sudo docker images ${IMAGE_NAME} --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}'"
echo ""

echo -e "${YELLOW}[4/5]${NC} Exporting image to ${OUTPUT_FILE}..."
ssh "$BUILD_HOST" "sudo docker save ${IMAGE_NAME}:${IMAGE_TAG} | gzip > ${OUTPUT_FILE}"
SIZE=$(ssh "$BUILD_HOST" "ls -lh ${OUTPUT_FILE} | awk '{print \$5}'")
echo -e "${GREEN}  ✓ Exported: ${OUTPUT_FILE} (${SIZE})${NC}"
echo ""

echo -e "${YELLOW}[5/5]${NC} Cleaning up old containers..."
ssh "$BUILD_HOST" "sudo docker rm -f lldpq-test 2>/dev/null || true"
echo -e "${GREEN}  ✓ Clean${NC}"
echo ""

echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Build Complete!                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "Image: ${CYAN}${IMAGE_NAME}:${VERSION}${NC} (${SIZE})"
echo -e "File:  ${CYAN}${BUILD_HOST}:${OUTPUT_FILE}${NC}"
echo ""
echo -e "Download:  ${YELLOW}scp ${BUILD_HOST}:${OUTPUT_FILE} .${NC}"
echo -e "Load:      ${YELLOW}docker load < lldpq.tar.gz${NC}"
echo -e "Run:       ${YELLOW}docker run -d --name lldpq -p 80:80 devices.yaml:/home/lldpq/lldpq/devices.yaml lldpq:latest${NC}"
