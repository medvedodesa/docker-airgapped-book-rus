#!/bin/bash
# cgroups-limits.sh
# Set and verify resource limits using cgroups
#
# Usage: ./cgroups-limits.sh [container_name]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

CONTAINER_NAME="${1:-resource-limited-demo}"

echo -e "${BLUE}Cgroups Resource Limits Demo${NC}"
echo "=========================================="
echo ""

# Function: Format bytes
format_bytes() {
    local bytes=$1
    if [ "$bytes" -eq 0 ]; then
        echo "unlimited"
    elif [ "$bytes" -lt 1048576 ]; then
        echo "$((bytes / 1024))K"
    elif [ "$bytes" -lt 1073741824 ]; then
        echo "$((bytes / 1048576))M"
    else
        echo "$((bytes / 1073741824))G"
    fi
}

# Clean up any existing container
docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true

echo -e "${YELLOW}Creating container with resource limits...${NC}"
echo ""

# Create container with comprehensive limits
docker run -d \
    --name $CONTAINER_NAME \
    --memory=512m \
    --memory-reservation=256m \
    --memory-swap=1g \
    --cpus=0.5 \
    --cpu-shares=512 \
    --pids-limit=100 \
    alpine sleep 1000

echo -e "${GREEN}✓ Container created with limits${NC}"
echo ""

# Display limits
echo "=========================================="
echo "Configured Resource Limits"
echo "=========================================="
echo ""

# Memory limits
echo -e "${BLUE}Memory Limits:${NC}"
MEMORY=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.Memory}}')
MEMORY_RES=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.MemoryReservation}}')
MEMORY_SWAP=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.MemorySwap}}')

echo "  Hard limit:        $(format_bytes $MEMORY)"
echo "  Soft limit:        $(format_bytes $MEMORY_RES)"
echo "  Memory + Swap:     $(format_bytes $MEMORY_SWAP)"
echo ""

# CPU limits
echo -e "${BLUE}CPU Limits:${NC}"
CPU_QUOTA=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.CpuQuota}}')
CPU_PERIOD=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.CpuPeriod}}')
CPU_SHARES=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.CpuShares}}')

if [ "$CPU_QUOTA" -gt 0 ]; then
    CPU_PERCENT=$(echo "scale=2; $CPU_QUOTA / $CPU_PERIOD" | bc)
    echo "  CPU quota:         ${CPU_PERCENT} cores"
else
    echo "  CPU quota:         unlimited"
fi
echo "  CPU shares:        $CPU_SHARES (relative weight)"
echo ""

# PID limit
echo -e "${BLUE}Process Limits:${NC}"
PIDS=$(docker inspect $CONTAINER_NAME --format '{{.HostConfig.PidsLimit}}')
echo "  Max processes:     $PIDS"
echo ""

# Test limits
echo "=========================================="
echo "Testing Resource Limits"
echo "=========================================="
echo ""

# Test 1: Memory limit
echo -e "${YELLOW}Test 1: Memory limit enforcement${NC}"
echo "Attempting to allocate 1GB (limit is 512MB)..."

if docker exec $CONTAINER_NAME sh -c 'dd if=/dev/zero of=/tmp/bigfile bs=1M count=1024' >/dev/null 2>&1; then
    echo -e "${RED}✗ Memory limit not enforced${NC}"
else
    echo -e "${GREEN}✓ Memory limit enforced (process killed)${NC}"
fi
echo ""

# Test 2: CPU limit
echo -e "${YELLOW}Test 2: CPU limit (0.5 cores)${NC}"
echo "Running CPU-intensive task for 5 seconds..."

# Start CPU-intensive process
docker exec -d $CONTAINER_NAME sh -c 'while true; do :; done' >/dev/null 2>&1

# Monitor CPU usage
sleep 2
CPU_USAGE=$(docker stats $CONTAINER_NAME --no-stream --format "{{.CPUPerc}}" | sed 's/%//')

echo "CPU usage: ${CPU_USAGE}%"

if (( $(echo "$CPU_USAGE < 60" | bc -l) )); then
    echo -e "${GREEN}✓ CPU limit enforced (usage < 60%)${NC}"
else
    echo -e "${YELLOW}⚠ CPU usage higher than expected${NC}"
fi

# Stop CPU task
docker exec $CONTAINER_NAME pkill -f "while true" >/dev/null 2>&1 || true
echo ""

# Test 3: PID limit
echo -e "${YELLOW}Test 3: PID limit (100 processes)${NC}"
echo "Attempting fork bomb..."

if docker exec $CONTAINER_NAME sh -c 'for i in $(seq 1 150); do sleep 1000 & done' >/dev/null 2>&1; then
    echo -e "${RED}✗ PID limit not enforced${NC}"
else
    echo -e "${GREEN}✓ PID limit enforced (cannot fork)${NC}"
fi

# Cleanup background processes
docker exec $CONTAINER_NAME pkill sleep >/dev/null 2>&1 || true
echo ""

# Real-time monitoring
echo "=========================================="
echo "Real-time Resource Usage"
echo "=========================================="
echo ""

echo "Monitoring for 5 seconds (Ctrl+C to stop)..."
echo ""

docker stats $CONTAINER_NAME --no-stream

echo ""
echo "=========================================="
echo "Cgroup Filesystem (Advanced)"
echo "=========================================="
echo ""

# Find container cgroup
CONTAINER_ID=$(docker inspect $CONTAINER_NAME --format '{{.Id}}')

echo "Container cgroup paths:"
echo "  /sys/fs/cgroup/memory/docker/$CONTAINER_ID"
echo "  /sys/fs/cgroup/cpu/docker/$CONTAINER_ID"
echo "  /sys/fs/cgroup/pids/docker/$CONTAINER_ID"
echo ""

# Show actual cgroup values
if [ -d "/sys/fs/cgroup/memory/docker/$CONTAINER_ID" ]; then
    echo "Memory cgroup values:"
    echo "  limit_in_bytes: $(cat /sys/fs/cgroup/memory/docker/$CONTAINER_ID/memory.limit_in_bytes 2>/dev/null || echo 'N/A')"
    echo "  usage_in_bytes: $(cat /sys/fs/cgroup/memory/docker/$CONTAINER_ID/memory.usage_in_bytes 2>/dev/null || echo 'N/A')"
fi
echo ""

# Cleanup
echo "=========================================="
echo "Cleanup"
echo "=========================================="
echo ""

read -p "Remove test container? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1
    echo -e "${GREEN}✓ Container removed${NC}"
else
    echo "Container $CONTAINER_NAME left running for further testing"
    echo "To remove: docker rm -f $CONTAINER_NAME"
fi

echo ""
echo "=========================================="
echo "Best Practices Summary"
echo "=========================================="
echo ""
echo "Memory:"
echo "  • Always set memory limits in production"
echo "  • Set to actual application needs + buffer"
echo "  • Monitor memory usage to tune limits"
echo "  • Use memory-reservation for soft limits"
echo ""
echo "CPU:"
echo "  • Use --cpus for simple percentage limits"
echo "  • Use --cpu-shares for relative prioritization"
echo "  • Consider --cpuset-cpus for performance-critical apps"
echo ""
echo "PIDs:"
echo "  • Set realistic PID limits (50-200 typical)"
echo "  • Prevents fork bomb attacks"
echo "  • Monitor actual PID usage"
echo ""
echo "Example docker-compose.yml:"
echo "---"
cat << 'EOF'
services:
  app:
    image: myapp
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
    pids_limit: 100
EOF
echo ""
