#!/bin/bash
# harbor-resource-calculator.sh
# Calculate required resources for Harbor deployment
#
# Usage: ./harbor-resource-calculator.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Harbor Resource Calculator${NC}"
echo "=========================================="
echo ""

# Get inputs
read -p "Number of Docker hosts: " HOSTS
read -p "Number of developers/users: " USERS
read -p "Average images per host: " IMAGES_PER_HOST
read -p "Average image size (MB): " AVG_IMAGE_SIZE
read -p "Deployment type (single/ha): " DEPLOYMENT_TYPE

echo ""
echo -e "${YELLOW}Calculating requirements...${NC}"
echo ""

# Calculate total images
TOTAL_IMAGES=$((HOSTS * IMAGES_PER_HOST))

# Calculate storage with deduplication factor (Docker layers are shared)
# Typical deduplication ratio: 3:1
DEDUP_FACTOR=3
RAW_STORAGE=$((TOTAL_IMAGES * AVG_IMAGE_SIZE))
EFFECTIVE_STORAGE=$((RAW_STORAGE / DEDUP_FACTOR))

# Add overhead for PostgreSQL, logs, etc (20%)
OVERHEAD=$((EFFECTIVE_STORAGE / 5))
TOTAL_STORAGE=$((EFFECTIVE_STORAGE + OVERHEAD))

# Calculate RAM based on users and hosts
# Base: 4GB
# Per 10 hosts: +1GB
# Per 20 users: +1GB
BASE_RAM=4
HOST_RAM=$((HOSTS / 10))
USER_RAM=$((USERS / 20))
TOTAL_RAM=$((BASE_RAM + HOST_RAM + USER_RAM))

# HA requires more resources
if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    TOTAL_RAM=$((TOTAL_RAM * 3))  # 3 nodes
    RECOMMENDED_NODES=3
else
    RECOMMENDED_NODES=1
fi

# CPU calculation
# Base: 4 cores
# Per 50 hosts: +2 cores
BASE_CPU=4
ADDITIONAL_CPU=$((HOSTS / 50 * 2))
TOTAL_CPU=$((BASE_CPU + ADDITIONAL_CPU))

if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    TOTAL_CPU_PER_NODE=$TOTAL_CPU
    TOTAL_CPU=$((TOTAL_CPU * 3))
else
    TOTAL_CPU_PER_NODE=$TOTAL_CPU
fi

# Network bandwidth estimation
# Assume 20% of hosts pull images daily
# Average pull: 500MB
DAILY_PULLS=$((HOSTS / 5))
DAILY_TRAFFIC=$((DAILY_PULLS * 500))
PEAK_BANDWIDTH=$((DAILY_TRAFFIC / 8 / 3600))  # MB/s during 8 working hours

# Results
echo "=========================================="
echo -e "${GREEN}Resource Requirements${NC}"
echo "=========================================="
echo ""

echo "Deployment Type: $DEPLOYMENT_TYPE"
if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    echo "Number of Nodes: $RECOMMENDED_NODES"
fi
echo ""

echo "STORAGE:"
echo "  Raw image storage: ${RAW_STORAGE} MB (~$((RAW_STORAGE / 1024)) GB)"
echo "  With deduplication: ${EFFECTIVE_STORAGE} MB (~$((EFFECTIVE_STORAGE / 1024)) GB)"
echo "  Total (with overhead): ${TOTAL_STORAGE} MB (~$((TOTAL_STORAGE / 1024)) GB)"
echo "  Recommended: $((TOTAL_STORAGE / 1024 * 2)) GB (2x for growth)"
echo ""

if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    echo "CPU (per node):"
    echo "  Cores: $TOTAL_CPU_PER_NODE"
    echo "  Total across cluster: $TOTAL_CPU cores"
else
    echo "CPU:"
    echo "  Cores: $TOTAL_CPU"
fi
echo ""

if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    echo "RAM (per node):"
    echo "  Memory: $((TOTAL_RAM / 3)) GB"
    echo "  Total across cluster: $TOTAL_RAM GB"
else
    echo "RAM:"
    echo "  Memory: $TOTAL_RAM GB"
fi
echo ""

echo "NETWORK:"
echo "  Daily traffic: ~${DAILY_TRAFFIC} MB (~$((DAILY_TRAFFIC / 1024)) GB)"
echo "  Peak bandwidth: ~${PEAK_BANDWIDTH} MB/s"
if [ $PEAK_BANDWIDTH -lt 100 ]; then
    echo "  Recommended: 1 Gbps NIC"
else
    echo "  Recommended: 10 Gbps NIC"
fi
echo ""

echo "=========================================="
echo -e "${GREEN}Hardware Recommendation${NC}"
echo "=========================================="
echo ""

if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    echo "3x Harbor Nodes:"
    echo "  CPU: $TOTAL_CPU_PER_NODE cores per node"
    echo "  RAM: $((TOTAL_RAM / 3)) GB per node"
    echo "  Disk: $((TOTAL_STORAGE / 1024 * 2)) GB shared storage (NFS/S3)"
    echo ""
    echo "External Services:"
    echo "  PostgreSQL HA Cluster: 3 nodes, 4 cores, 8GB RAM each"
    echo "  Redis Sentinel: 3 nodes, 2 cores, 2GB RAM each"
    echo "  Load Balancer: 2 nodes (active-passive)"
else
    echo "Single Harbor Node:"
    echo "  CPU: $TOTAL_CPU cores"
    echo "  RAM: $TOTAL_RAM GB"
    echo "  Disk: $((TOTAL_STORAGE / 1024 * 2)) GB"
    echo ""
    echo "Embedded Services:"
    echo "  PostgreSQL: Included (embedded)"
    echo "  Redis: Included (embedded)"
fi
echo ""

# Cost estimation
echo "=========================================="
echo -e "${GREEN}Estimated Costs (rough)${NC}"
echo "=========================================="
echo ""

if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    # 3x servers + 3x postgres + 3x redis + 2x LB + shared storage
    SERVER_COST=$((3 * 5000))
    POSTGRES_COST=$((3 * 3000))
    REDIS_COST=$((3 * 1000))
    LB_COST=$((2 * 2000))
    STORAGE_COST=$((TOTAL_STORAGE / 1024 / 1024 * 200))  # $200/TB
    TOTAL_COST=$((SERVER_COST + POSTGRES_COST + REDIS_COST + LB_COST + STORAGE_COST))
    
    echo "Hardware (one-time):"
    echo "  Harbor servers: \$$SERVER_COST"
    echo "  PostgreSQL cluster: \$$POSTGRES_COST"
    echo "  Redis cluster: \$$REDIS_COST"
    echo "  Load balancers: \$$LB_COST"
    echo "  Shared storage: \$$STORAGE_COST"
    echo "  Total: \$$TOTAL_COST"
else
    # Single server
    SERVER_COST=5000
    STORAGE_COST=$((TOTAL_STORAGE / 1024 / 1024 * 200))
    TOTAL_COST=$((SERVER_COST + STORAGE_COST))
    
    echo "Hardware (one-time):"
    echo "  Harbor server: \$$SERVER_COST"
    echo "  Storage: \$$STORAGE_COST"
    echo "  Total: \$$TOTAL_COST"
fi
echo ""

echo "Software:"
echo "  Harbor license: \$0 (open source)"
echo "  Support (optional): \$10,000-50,000/year"
echo ""

echo "=========================================="
echo -e "${GREEN}Summary${NC}"
echo "=========================================="
echo ""
echo "For $HOSTS Docker hosts with $USERS users:"
echo "  - $((TOTAL_STORAGE / 1024 * 2)) GB storage required"
if [ "$DEPLOYMENT_TYPE" = "ha" ]; then
    echo "  - 3 Harbor nodes ($TOTAL_CPU_PER_NODE cores, $((TOTAL_RAM / 3))GB RAM each)"
else
    echo "  - 1 Harbor node ($TOTAL_CPU cores, ${TOTAL_RAM}GB RAM)"
fi
echo "  - Estimated cost: \$$TOTAL_COST (hardware)"
echo ""
