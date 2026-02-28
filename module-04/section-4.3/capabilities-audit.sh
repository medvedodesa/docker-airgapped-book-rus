#!/bin/bash
# capabilities-audit.sh
# Audit container capabilities and detect dangerous configurations
#
# Usage: sudo ./capabilities-audit.sh

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Docker Capabilities Audit${NC}"
echo "=========================================="
echo ""

ISSUES=0

# Dangerous capabilities
DANGEROUS_CAPS=(
    "SYS_ADMIN"
    "SYS_MODULE"
    "SYS_RAWIO"
    "SYS_PTRACE"
    "SYS_BOOT"
    "MAC_ADMIN"
    "MAC_OVERRIDE"
    "DAC_READ_SEARCH"
)

# Check each running container
for CID in $(docker ps -q); do
    NAME=$(docker inspect $CID --format '{{.Name}}' | sed 's/\///')
    
    echo -e "${YELLOW}Container: $NAME${NC}"
    
    # Get capabilities
    CAP_ADD=$(docker inspect $CID --format '{{.HostConfig.CapAdd}}')
    CAP_DROP=$(docker inspect $CID --format '{{.HostConfig.CapDrop}}')
    
    echo "  CapAdd: $CAP_ADD"
    echo "  CapDrop: $CAP_DROP"
    
    # Check for dangerous capabilities
    for CAP in "${DANGEROUS_CAPS[@]}"; do
        if echo "$CAP_ADD" | grep -q "$CAP"; then
            echo -e "  ${RED}✗ CRITICAL: $CAP capability granted${NC}"
            ISSUES=$((ISSUES + 1))
        fi
    done
    
    # Check if ALL capabilities dropped (best practice)
    if echo "$CAP_DROP" | grep -q "ALL"; then
        echo -e "  ${GREEN}✓ All capabilities dropped (good)${NC}"
    else
        echo -e "  ${YELLOW}⚠ Not all capabilities dropped${NC}"
    fi
    
    # Runtime capability check
    if command -v capsh >/dev/null 2>&1; then
        RUNTIME_CAPS=$(docker exec $CID capsh --print 2>/dev/null | grep Current || echo "Unable to check")
        echo "  Runtime: $RUNTIME_CAPS"
    fi
    
    echo ""
done

# Summary
echo "=========================================="
if [ "$ISSUES" -eq 0 ]; then
    echo -e "${GREEN}No dangerous capabilities detected${NC}"
else
    echo -e "${RED}Found $ISSUES dangerous capability grants${NC}"
fi
echo ""

echo "Recommendations:"
echo "  • Drop ALL capabilities: --cap-drop=ALL"
echo "  • Add only required: --cap-add=NET_BIND_SERVICE"
echo "  • Never grant: SYS_ADMIN, SYS_MODULE, SYS_RAWIO"
echo ""
