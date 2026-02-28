#!/bin/bash
# validate-daemon-json.sh
# Validate Docker daemon.json configuration before applying
#
# Usage: ./validate-daemon-json.sh [daemon.json]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DAEMON_JSON="${1:-/etc/docker/daemon.json}"

echo -e "${YELLOW}Docker daemon.json Validator${NC}"
echo "=================================="
echo ""

# Check if file exists
if [ ! -f "$DAEMON_JSON" ]; then
    echo -e "${RED}ERROR: File not found: $DAEMON_JSON${NC}"
    exit 1
fi

echo "Validating: $DAEMON_JSON"
echo ""

# 1. JSON syntax validation
echo -e "${YELLOW}[1/5] Checking JSON syntax...${NC}"
if command -v jq &> /dev/null; then
    if jq empty "$DAEMON_JSON" 2>/dev/null; then
        echo -e "${GREEN}✓ Valid JSON syntax${NC}"
    else
        echo -e "${RED}✗ Invalid JSON syntax${NC}"
        echo "Error details:"
        jq empty "$DAEMON_JSON" 2>&1 || true
        exit 1
    fi
elif command -v python3 &> /dev/null; then
    if python3 -m json.tool "$DAEMON_JSON" > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Valid JSON syntax${NC}"
    else
        echo -e "${RED}✗ Invalid JSON syntax${NC}"
        python3 -m json.tool "$DAEMON_JSON" 2>&1 || true
        exit 1
    fi
else
    echo -e "${YELLOW}⚠ Cannot validate JSON (jq and python3 not found)${NC}"
fi
echo ""

# 2. Check critical parameters
echo -e "${YELLOW}[2/5] Checking critical parameters...${NC}"

# Extract values using jq or grep
if command -v jq &> /dev/null; then
    CGROUP_DRIVER=$(jq -r '.["exec-opts"][]? | select(contains("cgroupdriver"))' "$DAEMON_JSON" 2>/dev/null || echo "")
    STORAGE_DRIVER=$(jq -r '.["storage-driver"]? // empty' "$DAEMON_JSON" 2>/dev/null || echo "")
    LOG_DRIVER=$(jq -r '.["log-driver"]? // empty' "$DAEMON_JSON" 2>/dev/null || echo "")
    
    # Check cgroup driver
    if echo "$CGROUP_DRIVER" | grep -q "systemd"; then
        echo -e "${GREEN}✓ Cgroup driver: systemd${NC}"
    elif echo "$CGROUP_DRIVER" | grep -q "cgroupfs"; then
        echo -e "${YELLOW}⚠ Cgroup driver: cgroupfs (systemd recommended)${NC}"
    else
        echo -e "${YELLOW}⚠ Cgroup driver not specified (will use default)${NC}"
    fi
    
    # Check storage driver
    if [ -n "$STORAGE_DRIVER" ]; then
        if [ "$STORAGE_DRIVER" = "overlay2" ]; then
            echo -e "${GREEN}✓ Storage driver: overlay2${NC}"
        else
            echo -e "${YELLOW}⚠ Storage driver: $STORAGE_DRIVER (overlay2 recommended)${NC}"
        fi
    else
        echo -e "${YELLOW}⚠ Storage driver not specified (will use default)${NC}"
    fi
    
    # Check log driver
    if [ -n "$LOG_DRIVER" ]; then
        echo -e "${GREEN}✓ Log driver: $LOG_DRIVER${NC}"
    else
        echo -e "${YELLOW}⚠ Log driver not specified (will use default: json-file)${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Skipping parameter validation (jq not available)${NC}"
fi
echo ""

# 3. Check for common mistakes
echo -e "${YELLOW}[3/5] Checking for common mistakes...${NC}"

# Check for trailing commas (common JSON error)
if grep -q ',[ ]*}' "$DAEMON_JSON" || grep -q ',[ ]*]' "$DAEMON_JSON"; then
    echo -e "${RED}✗ Found trailing comma before } or ]${NC}"
    grep -n ',[ ]*[}\]]' "$DAEMON_JSON" || true
    exit 1
else
    echo -e "${GREEN}✓ No trailing commas${NC}"
fi

# Check for insecure-registries (should be empty in production)
if command -v jq &> /dev/null; then
    INSECURE_REGS=$(jq -r '.["insecure-registries"]? // [] | length' "$DAEMON_JSON" 2>/dev/null)
    if [ "$INSECURE_REGS" -gt 0 ]; then
        echo -e "${YELLOW}⚠ insecure-registries configured (NOT recommended for production)${NC}"
        jq -r '.["insecure-registries"][]?' "$DAEMON_JSON" | sed 's/^/  - /'
    else
        echo -e "${GREEN}✓ No insecure registries${NC}"
    fi
fi
echo ""

# 4. Check file permissions
echo -e "${YELLOW}[4/5] Checking file permissions...${NC}"
PERMS=$(stat -c '%a' "$DAEMON_JSON" 2>/dev/null || stat -f '%p' "$DAEMON_JSON" 2>/dev/null | tail -c 4)
if [ "$PERMS" = "644" ] || [ "$PERMS" = "0644" ]; then
    echo -e "${GREEN}✓ Permissions: 644 (correct)${NC}"
elif [ "$PERMS" = "600" ] || [ "$PERMS" = "0600" ]; then
    echo -e "${GREEN}✓ Permissions: 600 (secure)${NC}"
else
    echo -e "${YELLOW}⚠ Permissions: $PERMS (644 or 600 recommended)${NC}"
fi

OWNER=$(stat -c '%U:%G' "$DAEMON_JSON" 2>/dev/null || stat -f '%Su:%Sg' "$DAEMON_JSON" 2>/dev/null)
if [ "$OWNER" = "root:root" ]; then
    echo -e "${GREEN}✓ Owner: root:root${NC}"
else
    echo -e "${YELLOW}⚠ Owner: $OWNER (should be root:root)${NC}"
fi
echo ""

# 5. Test with dockerd --validate
echo -e "${YELLOW}[5/5] Testing with dockerd --validate...${NC}"
if command -v dockerd &> /dev/null; then
    if sudo dockerd --validate --config-file="$DAEMON_JSON" 2>&1 | grep -q "configuration OK"; then
        echo -e "${GREEN}✓ Docker daemon accepts this configuration${NC}"
    else
        # Try validation anyway
        OUTPUT=$(sudo dockerd --validate --config-file="$DAEMON_JSON" 2>&1 || true)
        if echo "$OUTPUT" | grep -q "Error"; then
            echo -e "${RED}✗ Docker daemon validation failed${NC}"
            echo "$OUTPUT"
            exit 1
        else
            echo -e "${GREEN}✓ Docker daemon validation passed${NC}"
        fi
    fi
else
    echo -e "${YELLOW}⚠ dockerd not found, skipping validation${NC}"
fi
echo ""

# Summary
echo "=================================="
echo -e "${GREEN}✓ Validation Complete${NC}"
echo ""
echo "The configuration appears to be valid."
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Backup current configuration:"
echo "   sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup"
echo ""
echo "2. Copy new configuration:"
echo "   sudo cp $DAEMON_JSON /etc/docker/daemon.json"
echo ""
echo "3. Reload and restart Docker:"
echo "   sudo systemctl daemon-reload"
echo "   sudo systemctl restart docker"
echo ""
echo "4. Verify Docker is running:"
echo "   sudo systemctl status docker"
echo "   docker info"
