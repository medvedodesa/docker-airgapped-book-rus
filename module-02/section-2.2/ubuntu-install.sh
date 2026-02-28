#!/bin/bash
# ubuntu-install.sh
# Install Docker from offline bundle on Ubuntu/Debian
#
# Usage: sudo ./ubuntu-install.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

BUNDLE_DIR="docker-offline-v1.0"
REPO_DIR="/var/local-apt-repo/docker"

echo -e "${GREEN}Docker Offline Installation for Ubuntu/Debian${NC}"
echo "================================================"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Check OS
if [ ! -f /etc/lsb-release ] && [ ! -f /etc/debian_version ]; then
    echo -e "${RED}ERROR: This script is for Ubuntu/Debian${NC}"
    exit 1
fi

echo -e "${YELLOW}System Information:${NC}"
if command -v lsb_release &> /dev/null; then
    lsb_release -a 2>/dev/null | grep -E "Distributor|Description|Release|Codename"
else
    cat /etc/os-release | grep PRETTY_NAME
fi
echo "Architecture: $(dpkg --print-architecture)"
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
apt-get remove -y \
    docker \
    docker-engine \
    docker.io \
    containerd \
    runc 2>/dev/null || true

echo -e "${GREEN}✓ Old Docker removed${NC}"
echo ""

# Step 2: Create local repository
echo -e "${YELLOW}Step 2: Creating local APT repository...${NC}"
mkdir -p "$REPO_DIR"
cp -v "$BUNDLE_DIR/packages"/*.deb "$REPO_DIR/"

# Create Packages index
cd "$REPO_DIR"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

if [ ! -f Packages.gz ]; then
    echo -e "${RED}ERROR: Failed to create Packages.gz${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Local repository created${NC}"
echo ""

# Step 3: Configure APT
echo -e "${YELLOW}Step 3: Configuring APT...${NC}"
cat > /etc/apt/sources.list.d/docker-local.list <<EOF
deb [trusted=yes] file://$REPO_DIR ./
EOF

apt-get update

echo -e "${GREEN}✓ APT configured${NC}"
echo ""

# Step 4: Install Docker
echo -e "${YELLOW}Step 4: Installing Docker Engine...${NC}"
apt-get install -y \
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
