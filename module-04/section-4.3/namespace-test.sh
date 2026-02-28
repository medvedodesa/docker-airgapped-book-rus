#!/bin/bash
# namespace-test.sh
# Test all namespace isolation mechanisms
#
# Usage: sudo ./namespace-test.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Docker Namespace Isolation Tests${NC}"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

PASS=0
FAIL=0

# Function: Test result
test_result() {
    local TEST_NAME=$1
    local STATUS=$2
    local DETAILS=$3
    
    if [ "$STATUS" = "PASS" ]; then
        echo -e "${GREEN}[PASS]${NC} $TEST_NAME"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}[FAIL]${NC} $TEST_NAME"
        echo "       $DETAILS"
        FAIL=$((FAIL + 1))
    fi
}

# Test 1: PID Namespace
echo -e "${YELLOW}Test 1: PID Namespace Isolation${NC}"

# Start container
docker run -d --name ns-test-pid alpine sleep 1000 >/dev/null 2>&1

# Check PID inside container
CONTAINER_PID=$(docker exec ns-test-pid sh -c 'ps aux | grep "sleep 1000" | grep -v grep | awk "{print \$1}"')

if [ "$CONTAINER_PID" = "1" ]; then
    test_result "PID namespace" "PASS" ""
else
    test_result "PID namespace" "FAIL" "Expected PID 1, got $CONTAINER_PID"
fi

# Check host cannot see container PID 1
HOST_PID=$(ps aux | grep "sleep 1000" | grep -v grep | awk '{print $2}' | head -1)
if [ "$HOST_PID" != "1" ]; then
    test_result "PID isolation from host" "PASS" ""
else
    test_result "PID isolation from host" "FAIL" "Container PID visible as 1 on host"
fi

docker rm -f ns-test-pid >/dev/null 2>&1
echo ""

# Test 2: NET Namespace
echo -e "${YELLOW}Test 2: Network Namespace Isolation${NC}"

# Create two separate networks
docker network create test-net-1 >/dev/null 2>&1 || true
docker network create test-net-2 >/dev/null 2>&1 || true

docker run -d --name ns-test-net1 --network test-net-1 alpine sleep 1000 >/dev/null 2>&1
docker run -d --name ns-test-net2 --network test-net-2 alpine sleep 1000 >/dev/null 2>&1

# Get IPs
IP1=$(docker inspect ns-test-net1 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
IP2=$(docker inspect ns-test-net2 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')

# Test isolation
if docker exec ns-test-net1 ping -c 1 -W 1 $IP2 >/dev/null 2>&1; then
    test_result "Network isolation" "FAIL" "Containers on different networks can communicate"
else
    test_result "Network isolation" "PASS" ""
fi

# Test container has own network stack
INTERFACES=$(docker exec ns-test-net1 ip addr | grep -c "inet ")
if [ "$INTERFACES" -ge 2 ]; then  # lo + eth0
    test_result "Container network stack" "PASS" ""
else
    test_result "Container network stack" "FAIL" "Expected at least 2 interfaces"
fi

# Cleanup
docker rm -f ns-test-net1 ns-test-net2 >/dev/null 2>&1
docker network rm test-net-1 test-net-2 >/dev/null 2>&1
echo ""

# Test 3: MNT Namespace
echo -e "${YELLOW}Test 3: Mount Namespace Isolation${NC}"

docker run -d --name ns-test-mnt alpine sleep 1000 >/dev/null 2>&1

# Check container cannot see host mounts
HOST_MOUNTS=$(mount | wc -l)
CONTAINER_MOUNTS=$(docker exec ns-test-mnt mount | wc -l)

if [ "$CONTAINER_MOUNTS" -lt "$HOST_MOUNTS" ]; then
    test_result "Mount namespace" "PASS" ""
else
    test_result "Mount namespace" "FAIL" "Container sees all host mounts"
fi

# Check container filesystem is isolated
if docker exec ns-test-mnt ls /home >/dev/null 2>&1; then
    # /home exists in container (may be empty)
    CONTAINER_HOME=$(docker exec ns-test-mnt ls /home | wc -l)
    HOST_HOME=$(ls /home | wc -l)
    
    if [ "$CONTAINER_HOME" -ne "$HOST_HOME" ]; then
        test_result "Filesystem isolation" "PASS" ""
    else
        test_result "Filesystem isolation" "WARN" "Same number of entries (may be coincidence)"
    fi
else
    test_result "Filesystem isolation" "PASS" ""
fi

docker rm -f ns-test-mnt >/dev/null 2>&1
echo ""

# Test 4: UTS Namespace
echo -e "${YELLOW}Test 4: UTS Namespace (Hostname) Isolation${NC}"

HOST_HOSTNAME=$(hostname)
docker run -d --name ns-test-uts --hostname container-host alpine sleep 1000 >/dev/null 2>&1

CONTAINER_HOSTNAME=$(docker exec ns-test-uts hostname)

if [ "$CONTAINER_HOSTNAME" != "$HOST_HOSTNAME" ]; then
    test_result "UTS namespace" "PASS" ""
else
    test_result "UTS namespace" "FAIL" "Container has same hostname as host"
fi

if [ "$CONTAINER_HOSTNAME" = "container-host" ]; then
    test_result "Custom hostname" "PASS" ""
else
    test_result "Custom hostname" "FAIL" "Expected 'container-host', got '$CONTAINER_HOSTNAME'"
fi

docker rm -f ns-test-uts >/dev/null 2>&1
echo ""

# Test 5: IPC Namespace
echo -e "${YELLOW}Test 5: IPC Namespace Isolation${NC}"

# Create shared memory on host
ipcmk -M 1024 >/dev/null 2>&1 || true

HOST_IPC=$(ipcs -m | grep -c "^0x" || echo "0")
docker run -d --name ns-test-ipc alpine sleep 1000 >/dev/null 2>&1
CONTAINER_IPC=$(docker exec ns-test-ipc sh -c 'ipcs -m | grep -c "^0x" || echo "0"')

if [ "$CONTAINER_IPC" -lt "$HOST_IPC" ] || [ "$CONTAINER_IPC" = "0" ]; then
    test_result "IPC namespace" "PASS" ""
else
    test_result "IPC namespace" "FAIL" "Container sees host IPC resources"
fi

docker rm -f ns-test-ipc >/dev/null 2>&1
echo ""

# Test 6: USER Namespace
echo -e "${YELLOW}Test 6: USER Namespace (if enabled)${NC}"

# Check if user namespace is enabled
USERNS_ENABLED=$(docker info 2>/dev/null | grep -i "userns" || echo "")

if [ -n "$USERNS_ENABLED" ]; then
    docker run -d --name ns-test-user alpine sleep 1000 >/dev/null 2>&1
    
    # Inside container: UID 0
    CONTAINER_UID=$(docker exec ns-test-user id -u)
    
    # On host: remapped UID
    HOST_UID=$(ps aux | grep "sleep 1000" | grep -v grep | awk '{print $1}' | head -1)
    
    if [ "$CONTAINER_UID" = "0" ] && [ "$HOST_UID" != "root" ] && [ "$HOST_UID" != "0" ]; then
        test_result "USER namespace remapping" "PASS" ""
    else
        test_result "USER namespace remapping" "FAIL" "Container UID not remapped"
    fi
    
    docker rm -f ns-test-user >/dev/null 2>&1
else
    echo "  User namespace not enabled (optional Level 2 control)"
    echo "  To enable: Add \"userns-remap\": \"dockremap\" to daemon.json"
fi
echo ""

# Test 7: Host network mode (should fail isolation)
echo -e "${YELLOW}Test 7: Host Network Mode (negative test)${NC}"

docker run -d --name ns-test-hostnet --net=host alpine sleep 1000 >/dev/null 2>&1

HOST_IFACES=$(ip addr | grep -c "inet ")
CONTAINER_IFACES=$(docker exec ns-test-hostnet ip addr | grep -c "inet ")

if [ "$CONTAINER_IFACES" -eq "$HOST_IFACES" ]; then
    test_result "Host network disables isolation" "PASS" "As expected"
else
    test_result "Host network disables isolation" "FAIL" "Unexpected behavior"
fi

docker rm -f ns-test-hostnet >/dev/null 2>&1
echo ""

# Test 8: Privileged mode (should disable some isolation)
echo -e "${YELLOW}Test 8: Privileged Mode (negative test)${NC}"

docker run -d --name ns-test-priv --privileged alpine sleep 1000 >/dev/null 2>&1

# Privileged container can see all devices
DEVICES=$(docker exec ns-test-priv ls /dev | wc -l)

if [ "$DEVICES" -gt 50 ]; then  # Privileged has many devices
    test_result "Privileged mode reduces isolation" "PASS" "As expected (AVOID in production!)"
else
    test_result "Privileged mode reduces isolation" "FAIL" "Unexpected device count"
fi

docker rm -f ns-test-priv >/dev/null 2>&1
echo ""

# Summary
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}PASS:${NC} $PASS"
echo -e "${RED}FAIL:${NC} $FAIL"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}All namespace isolation tests passed!${NC}"
    echo ""
    echo "Key findings:"
    echo "  ✓ PID namespace isolates process tree"
    echo "  ✓ NET namespace isolates network stack"
    echo "  ✓ MNT namespace isolates filesystem mounts"
    echo "  ✓ UTS namespace isolates hostname"
    echo "  ✓ IPC namespace isolates IPC resources"
    if [ -n "$USERNS_ENABLED" ]; then
        echo "  ✓ USER namespace remaps UIDs"
    fi
    echo ""
    echo "Security recommendations:"
    echo "  • Never use --net=host in production"
    echo "  • Never use --privileged in production"
    echo "  • Consider enabling user namespace remapping"
    echo "  • Use custom bridge networks for inter-container comm"
else
    echo -e "${RED}Some tests failed. Review isolation configuration.${NC}"
fi
echo ""

exit $FAIL
