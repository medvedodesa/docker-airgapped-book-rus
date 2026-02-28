#!/bin/bash
# post-install-verify.sh
# Comprehensive Docker installation verification
#
# Usage: ./post-install-verify.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

check_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

check_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

check_warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Docker Post-Installation Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check 1: Docker version
echo -e "${YELLOW}[1/12] Checking Docker version...${NC}"
if docker --version &> /dev/null; then
    VERSION=$(docker --version)
    check_pass "Docker version: $VERSION"
else
    check_fail "Docker command not found"
fi
echo ""

# Check 2: Docker Compose version
echo -e "${YELLOW}[2/12] Checking Docker Compose version...${NC}"
if docker compose version &> /dev/null; then
    COMPOSE_VERSION=$(docker compose version)
    check_pass "Docker Compose: $COMPOSE_VERSION"
else
    check_fail "Docker Compose not working"
fi
echo ""

# Check 3: Docker service status
echo -e "${YELLOW}[3/12] Checking Docker service status...${NC}"
if systemctl is-active docker &> /dev/null; then
    check_pass "Docker service is active"
else
    check_fail "Docker service is not active"
fi
echo ""

# Check 4: Containerd service status
echo -e "${YELLOW}[4/12] Checking Containerd service status...${NC}"
if systemctl is-active containerd &> /dev/null; then
    check_pass "Containerd service is active"
else
    check_fail "Containerd service is not active"
fi
echo ""

# Check 5: Storage Driver
echo -e "${YELLOW}[5/12] Checking Storage Driver...${NC}"
STORAGE_DRIVER=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "unknown")
if [ "$STORAGE_DRIVER" = "overlay2" ]; then
    check_pass "Storage Driver: overlay2"
elif [ "$STORAGE_DRIVER" = "unknown" ]; then
    check_fail "Cannot determine storage driver"
else
    check_warn "Storage Driver: $STORAGE_DRIVER (overlay2 recommended)"
fi
echo ""

# Check 6: Cgroup Driver
echo -e "${YELLOW}[6/12] Checking Cgroup Driver...${NC}"
CGROUP_DRIVER=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo "unknown")
if [ "$CGROUP_DRIVER" = "systemd" ]; then
    check_pass "Cgroup Driver: systemd"
elif [ "$CGROUP_DRIVER" = "cgroupfs" ]; then
    check_warn "Cgroup Driver: cgroupfs (systemd recommended for Kubernetes)"
else
    check_fail "Cannot determine Cgroup Driver"
fi
echo ""

# Check 7: Docker networks
echo -e "${YELLOW}[7/12] Checking Docker networks...${NC}"
NETWORKS=$(docker network ls --format '{{.Name}}' 2>/dev/null | sort)
if echo "$NETWORKS" | grep -q "bridge" && \
   echo "$NETWORKS" | grep -q "host" && \
   echo "$NETWORKS" | grep -q "none"; then
    check_pass "Default networks present (bridge, host, none)"
else
    check_fail "Missing default networks"
fi
echo ""

# Check 8: Permissions (non-root access)
echo -e "${YELLOW}[8/12] Checking Docker permissions...${NC}"
if docker ps &> /dev/null; then
    check_pass "Docker accessible without sudo"
else
    if sudo docker ps &> /dev/null; then
        check_warn "Docker requires sudo (user not in docker group)"
        echo "  Fix: sudo usermod -aG docker \$USER && newgrp docker"
    else
        check_fail "Docker not accessible"
    fi
fi
echo ""

# Check 9: Disk space
echo -e "${YELLOW}[9/12] Checking disk space...${NC}"
DOCKER_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo "/var/lib/docker")
FREE_SPACE_MB=$(df -BM "$DOCKER_ROOT" | tail -1 | awk '{print $4}' | sed 's/M//')
if [ "$FREE_SPACE_MB" -gt 10240 ]; then  # 10GB
    check_pass "Free space: ${FREE_SPACE_MB}MB (>10GB)"
elif [ "$FREE_SPACE_MB" -gt 5120 ]; then  # 5GB
    check_warn "Free space: ${FREE_SPACE_MB}MB (low, <10GB recommended)"
else
    check_fail "Free space: ${FREE_SPACE_MB}MB (critical, <5GB)"
fi
echo ""

# Check 10: Docker daemon logs
echo -e "${YELLOW}[10/12] Checking Docker daemon logs for errors...${NC}"
ERROR_COUNT=$(sudo journalctl -u docker --since "10 minutes ago" | grep -ic "error\|fatal" || echo 0)
if [ "$ERROR_COUNT" -eq 0 ]; then
    check_pass "No errors in recent daemon logs"
else
    check_warn "Found $ERROR_COUNT error(s) in recent logs"
    echo "  Check: sudo journalctl -u docker -n 50"
fi
echo ""

# Check 11: Kernel version
echo -e "${YELLOW}[11/12] Checking Kernel version...${NC}"
KERNEL_VERSION=$(uname -r | cut -d. -f1-2)
KERNEL_MAJOR=$(echo "$KERNEL_VERSION" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL_VERSION" | cut -d. -f2)

if [ "$KERNEL_MAJOR" -gt 5 ] || \
   ([ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -ge 0 ]) || \
   ([ "$KERNEL_MAJOR" -eq 3 ] && [ "$KERNEL_MINOR" -ge 10 ]); then
    check_pass "Kernel version: $(uname -r)"
else
    check_fail "Kernel version too old: $(uname -r) (need >= 3.10)"
fi
echo ""

# Check 12: Test container run
echo -e "${YELLOW}[12/12] Testing container execution...${NC}"
if docker run --rm hello-world &> /dev/null 2>&1; then
    check_pass "Test container (hello-world) executed successfully"
elif docker run --rm alpine:3.18 echo "test" &> /dev/null 2>&1; then
    check_pass "Test container (alpine) executed successfully"
else
    check_warn "Cannot run test container (no images available)"
    echo "  This is normal in air-gapped environment without base images"
fi
echo ""

# Summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Verification Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "Passed:   ${GREEN}$PASSED${NC}"
echo -e "Failed:   ${RED}$FAILED${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ All checks passed! Docker is ready to use.${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠ Installation complete with warnings.${NC}"
        echo "Review warnings above and fix if needed."
        exit 0
    fi
else
    echo -e "${RED}✗ Installation has issues.${NC}"
    echo "Please fix failed checks before using Docker in production."
    exit 1
fi
