#!/bin/bash
# docker-bench-setup.sh
# Install Docker Bench Security for offline air-gapped environments
#
# Usage: ./docker-bench-setup.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

INSTALL_DIR="/opt/docker-bench-security"
VERSION="${VERSION:-master}"

echo -e "${BLUE}Docker Bench Security Installer${NC}"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Step 1: Check for existing installation
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${YELLOW}Docker Bench Security already installed at $INSTALL_DIR${NC}"
    read -p "Remove and reinstall? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$INSTALL_DIR"
    else
        echo "Installation cancelled"
        exit 0
    fi
fi

# Step 2: Check for archive or git repo
echo -e "${YELLOW}Step 1: Checking for Docker Bench Security source...${NC}"

if [ -f "./docker-bench-security.tar.gz" ]; then
    echo "Found local archive: docker-bench-security.tar.gz"
    mkdir -p "$INSTALL_DIR"
    tar xzf docker-bench-security.tar.gz -C "$INSTALL_DIR" --strip-components=1
    echo -e "${GREEN}✓ Extracted from archive${NC}"
    
elif [ -d "./docker-bench-security" ]; then
    echo "Found local directory: docker-bench-security"
    cp -r ./docker-bench-security "$INSTALL_DIR"
    echo -e "${GREEN}✓ Copied from directory${NC}"
    
else
    echo -e "${RED}ERROR: Docker Bench Security source not found${NC}"
    echo ""
    echo "Please provide one of:"
    echo "  1. docker-bench-security.tar.gz (from GitHub release)"
    echo "  2. docker-bench-security/ directory"
    echo ""
    echo "To obtain on external machine with internet:"
    echo "  git clone https://github.com/docker/docker-bench-security.git"
    echo "  cd docker-bench-security"
    echo "  tar czf ../docker-bench-security.tar.gz ."
    echo ""
    echo "Then transfer the archive to this air-gapped system"
    exit 1
fi

# Step 3: Make executable
echo ""
echo -e "${YELLOW}Step 2: Setting permissions...${NC}"
chmod +x "$INSTALL_DIR/docker-bench-security.sh"
echo -e "${GREEN}✓ Permissions set${NC}"

# Step 4: Create wrapper script
echo ""
echo -e "${YELLOW}Step 3: Creating wrapper script...${NC}"

cat > /usr/local/bin/docker-bench << 'EOF'
#!/bin/bash
# Docker Bench Security wrapper

cd /opt/docker-bench-security
./docker-bench-security.sh "$@"
EOF

chmod +x /usr/local/bin/docker-bench
echo -e "${GREEN}✓ Wrapper created: /usr/local/bin/docker-bench${NC}"

# Step 5: Create systemd timer for automated scans (optional)
echo ""
echo -e "${YELLOW}Step 4: Setting up automated scanning...${NC}"

cat > /etc/systemd/system/docker-bench.service << 'EOF'
[Unit]
Description=Docker Bench Security Scan
After=docker.service

[Service]
Type=oneshot
ExecStart=/opt/docker-bench-security/docker-bench-security.sh -l /var/log/docker-bench.log
StandardOutput=journal
StandardError=journal
EOF

cat > /etc/systemd/system/docker-bench.timer << 'EOF'
[Unit]
Description=Run Docker Bench Security weekly

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload

read -p "Enable weekly automated scans? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl enable docker-bench.timer
    systemctl start docker-bench.timer
    echo -e "${GREEN}✓ Weekly scans enabled${NC}"
else
    echo "Automated scans not enabled (can enable later with: systemctl enable docker-bench.timer)"
fi

# Step 6: Create log directory
echo ""
echo -e "${YELLOW}Step 5: Creating log directory...${NC}"
mkdir -p /var/log/docker-bench
echo -e "${GREEN}✓ Log directory created${NC}"

# Step 7: Run initial scan
echo ""
echo -e "${YELLOW}Step 6: Running initial scan...${NC}"
echo ""

read -p "Run initial scan now? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd "$INSTALL_DIR"
    ./docker-bench-security.sh | tee /var/log/docker-bench/initial-scan-$(date +%Y%m%d-%H%M%S).log
else
    echo "Skipping initial scan"
fi

# Summary
echo ""
echo "=========================================="
echo -e "${GREEN}Installation Complete${NC}"
echo "=========================================="
echo ""
echo "Installation directory: $INSTALL_DIR"
echo "Command: docker-bench"
echo "Logs: /var/log/docker-bench/"
echo ""
echo "Usage:"
echo "  docker-bench                    # Run full scan"
echo "  docker-bench -l /path/to/log    # Save to specific log"
echo "  docker-bench -c 1,2             # Run only sections 1 and 2"
echo "  docker-bench -e 5.1,5.2         # Exclude specific checks"
echo ""
echo "Automated scans:"
if systemctl is-enabled docker-bench.timer >/dev/null 2>&1; then
    echo "  Status: Enabled (weekly)"
    echo "  Next run: $(systemctl status docker-bench.timer | grep 'Trigger:' | cut -d: -f2-)"
else
    echo "  Status: Disabled"
    echo "  Enable: systemctl enable docker-bench.timer"
fi
echo ""
echo "View results:"
echo "  ls -lh /var/log/docker-bench/"
echo ""
