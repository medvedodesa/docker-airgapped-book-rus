#!/bin/bash
# apply-daemon-config.sh
# Safely apply Docker daemon.json configuration
#
# Usage: sudo ./apply-daemon-config.sh [daemon.json]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NEW_CONFIG="${1:-daemon.json.production}"
DAEMON_JSON="/etc/docker/daemon.json"
BACKUP_DIR="/etc/docker/backups"

echo -e "${GREEN}Docker daemon.json Configuration Tool${NC}"
echo "========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Check if new config exists
if [ ! -f "$NEW_CONFIG" ]; then
    echo -e "${RED}ERROR: Configuration file not found: $NEW_CONFIG${NC}"
    exit 1
fi

# Validate new configuration
echo -e "${YELLOW}Step 1: Validating new configuration...${NC}"
if command -v jq &> /dev/null; then
    if ! jq empty "$NEW_CONFIG" 2>/dev/null; then
        echo -e "${RED}ERROR: Invalid JSON in $NEW_CONFIG${NC}"
        jq empty "$NEW_CONFIG" 2>&1 || true
        exit 1
    fi
    echo -e "${GREEN}✓ JSON syntax valid${NC}"
elif command -v python3 &> /dev/null; then
    if ! python3 -m json.tool "$NEW_CONFIG" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Invalid JSON in $NEW_CONFIG${NC}"
        python3 -m json.tool "$NEW_CONFIG" 2>&1 || true
        exit 1
    fi
    echo -e "${GREEN}✓ JSON syntax valid${NC}"
else
    echo -e "${YELLOW}⚠ Cannot validate JSON (jq/python3 not found)${NC}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi
echo ""

# Create backup
echo -e "${YELLOW}Step 2: Creating backup...${NC}"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/daemon.json.$(date +%Y%m%d-%H%M%S)"

if [ -f "$DAEMON_JSON" ]; then
    cp "$DAEMON_JSON" "$BACKUP_FILE"
    echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"
else
    echo -e "${YELLOW}⚠ No existing configuration to backup${NC}"
fi
echo ""

# Show diff
if [ -f "$DAEMON_JSON" ]; then
    echo -e "${YELLOW}Step 3: Configuration changes:${NC}"
    echo "---"
    if command -v diff &> /dev/null; then
        diff -u "$DAEMON_JSON" "$NEW_CONFIG" || true
    else
        echo "Current config:"
        cat "$DAEMON_JSON"
        echo ""
        echo "New config:"
        cat "$NEW_CONFIG"
    fi
    echo "---"
    echo ""
fi

# Confirm
read -p "Apply this configuration? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi
echo ""

# Apply configuration
echo -e "${YELLOW}Step 4: Applying configuration...${NC}"
cp "$NEW_CONFIG" "$DAEMON_JSON"
chmod 644 "$DAEMON_JSON"
chown root:root "$DAEMON_JSON"
echo -e "${GREEN}✓ Configuration copied${NC}"
echo ""

# Reload systemd
echo -e "${YELLOW}Step 5: Reloading systemd...${NC}"
systemctl daemon-reload
echo -e "${GREEN}✓ systemd reloaded${NC}"
echo ""

# Restart Docker
echo -e "${YELLOW}Step 6: Restarting Docker daemon...${NC}"
if systemctl restart docker; then
    echo -e "${GREEN}✓ Docker restarted successfully${NC}"
else
    echo -e "${RED}✗ Docker failed to restart!${NC}"
    echo ""
    echo "Restoring backup..."
    if [ -f "$BACKUP_FILE" ]; then
        cp "$BACKUP_FILE" "$DAEMON_JSON"
        systemctl daemon-reload
        systemctl restart docker
        echo -e "${GREEN}✓ Backup restored${NC}"
    fi
    echo ""
    echo "Check logs: sudo journalctl -u docker -n 50"
    exit 1
fi
echo ""

# Verify
echo -e "${YELLOW}Step 7: Verifying configuration...${NC}"
sleep 2

if systemctl is-active docker &> /dev/null; then
    echo -e "${GREEN}✓ Docker is running${NC}"
else
    echo -e "${RED}✗ Docker is not running${NC}"
    exit 1
fi

# Show applied settings
echo ""
echo -e "${GREEN}Applied Configuration:${NC}"
echo "---"
docker info | grep -E "Cgroup Driver|Storage Driver|Logging Driver" || true
echo "---"
echo ""

echo -e "${GREEN}✓ Configuration applied successfully!${NC}"
echo ""
echo "Backup location: $BACKUP_FILE"
echo ""
echo "To verify all settings: docker info"
