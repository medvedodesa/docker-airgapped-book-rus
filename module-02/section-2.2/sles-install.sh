#!/bin/bash
# sles-install.sh
# Install Docker from offline bundle on SUSE Linux Enterprise Server
#
# Usage: sudo ./sles-install.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BUNDLE_DIR="docker-offline-v1.0"
REPO_DIR="/var/local-zypp-repo/docker"

echo -e "${GREEN}Docker Offline Installation for SLES${NC}"
echo "======================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Check OS
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}ERROR: Cannot determine OS${NC}"
    exit 1
fi

if ! grep -qi "suse\|sles" /etc/os-release; then
    echo -e "${RED}ERROR: This script is for SUSE Linux Enterprise Server${NC}"
    exit 1
fi

echo -e "${YELLOW}System Information:${NC}"
cat /etc/os-release | grep -E "NAME|VERSION"
echo "Architecture: $(uname -m)"
echo "Kernel: $(uname -r)"
echo ""

# Check if bundle exists
if [ ! -d "$BUNDLE_DIR" ]; then
    echo -e "${RED}ERROR: Bundle directory not found: $BUNDLE_DIR${NC}"
    echo "Please extract docker-offline-v1.0.tar.gz first"
    exit 1
fi

# Check disk space
FREE_SPACE=$(df /var | tail -1 | awk '{print $4}')
if [ "$FREE_SPACE" -lt 20971520 ]; then  # 20GB in KB
    echo -e "${YELLOW}WARNING: Less than 20GB free space on /var${NC}"
    df -h /var
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Step 1: Remove old Docker
echo -e "${YELLOW}Step 1: Removing old Docker installations...${NC}"
systemctl stop docker 2>/dev/null || true
zypper remove -y docker \
                 docker-runc \
                 containerd 2>/dev/null || true

echo -e "${GREEN}✓ Old Docker removed${NC}"
echo ""

# Step 2: Create local repository
echo -e "${YELLOW}Step 2: Creating local zypper repository...${NC}"
mkdir -p "$REPO_DIR"
cp -v "$BUNDLE_DIR/packages"/*.rpm "$REPO_DIR/"

# Create repo metadata (use createrepo_c if available, fallback to createrepo)
cd "$REPO_DIR"
if command -v createrepo_c &> /dev/null; then
    createrepo_c .
elif command -v createrepo &> /dev/null; then
    createrepo .
else
    echo -e "${RED}ERROR: Neither createrepo_c nor createrepo found${NC}"
    echo "Install with: zypper install createrepo_c"
    exit 1
fi

echo -e "${GREEN}✓ Local repository created${NC}"
echo ""

# Step 3: Configure zypper
echo -e "${YELLOW}Step 3: Configuring zypper...${NC}"
zypper addrepo --no-check \
    file://"$REPO_DIR" \
    docker-local

zypper refresh

echo -e "${GREEN}✓ zypper configured${NC}"
echo ""

# Step 4: Install Docker
echo -e "${YELLOW}Step 4: Installing Docker Engine...${NC}"
zypper install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

echo -e "${GREEN}✓ Docker installed${NC}"
echo ""

# Step 5: Start Docker
echo -e "${YELLOW}Step 5: Starting Docker service...${NC}"
systemctl enable docker
systemctl enable containerd
systemctl start containerd
systemctl start docker

echo -e "${GREEN}✓ Docker service started${NC}"
echo ""

# Step 6: Add current user to docker group
if [ -n "$SUDO_USER" ]; then
    echo -e "${YELLOW}Step 6: Adding user $SUDO_USER to docker group...${NC}"
    usermod -aG docker "$SUDO_USER"
    echo -e "${GREEN}✓ User added to docker group${NC}"
    echo -e "${YELLOW}Note: User must logout/login or run 'newgrp docker'${NC}"
else
    echo -e "${YELLOW}Step 6: Skipping user group (no SUDO_USER)${NC}"
fi
echo ""

# Verification
echo -e "${GREEN}Installation Complete!${NC}"
echo "=========================================="
echo ""
echo "Verification:"
docker --version
docker compose version
echo ""

echo -e "${YELLOW}Next steps:${NC}"
echo "1. Logout and login (or run: newgrp docker)"
echo "2. Test: docker run --rm alpine:3.18 echo 'Works!'"
echo "3. Run post-install-verify.sh for comprehensive check"
echo ""

echo -e "${GREEN}✓ Installation successful!${NC}"
