#!/bin/bash
# post-install-verify.sh
# Comprehensive Harbor installation verification
#
# Usage: ./post-install-verify.sh [harbor-hostname]

set -euo pipefail

HARBOR_HOST="${1:-harbor.company.local}"
ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345!}"

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
echo -e "${BLUE}Harbor Post-Installation Verification${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Harbor Host: $HARBOR_HOST"
echo ""

# Check 1: DNS Resolution
echo -e "${YELLOW}[1/10] Checking DNS resolution...${NC}"
if nslookup "$HARBOR_HOST" >/dev/null 2>&1; then
    IP=$(nslookup "$HARBOR_HOST" | grep "Address:" | tail -1 | awk '{print $2}')
    check_pass "DNS resolves to $IP"
else
    check_fail "DNS resolution failed"
fi
echo ""

# Check 2: HTTPS Access
echo -e "${YELLOW}[2/10] Checking HTTPS access...${NC}"
if curl -k -s "https://$HARBOR_HOST" | grep -q "Harbor"; then
    check_pass "HTTPS access successful"
else
    check_fail "Cannot access Harbor Web UI"
fi
echo ""

# Check 3: API Health
echo -e "${YELLOW}[3/10] Checking API health...${NC}"
HEALTH=$(curl -k -s "https://$HARBOR_HOST/api/v2.0/health")
if echo "$HEALTH" | grep -q '"status":"healthy"'; then
    check_pass "Harbor API is healthy"
else
    check_warn "Harbor API returned: $HEALTH"
fi
echo ""

# Check 4: Docker Containers
echo -e "${YELLOW}[4/10] Checking Docker containers...${NC}"
CONTAINER_COUNT=$(docker ps --filter "name=harbor" | wc -l)
if [ "$CONTAINER_COUNT" -ge 9 ]; then
    check_pass "$((CONTAINER_COUNT - 1)) Harbor containers running"
else
    check_fail "Only $((CONTAINER_COUNT - 1)) containers running (expected 9+)"
fi

# Check individual containers
for container in nginx harbor-core harbor-portal harbor-jobservice harbor-db redis registry; do
    if docker ps | grep -q "$container"; then
        echo -e "  ${GREEN}✓${NC} $container"
    else
        echo -e "  ${RED}✗${NC} $container (NOT RUNNING)"
        FAILED=$((FAILED + 1))
    fi
done
echo ""

# Check 5: Docker Login
echo -e "${YELLOW}[5/10] Testing Docker login...${NC}"
if echo "$ADMIN_PASSWORD" | docker login "$HARBOR_HOST" -u admin --password-stdin >/dev/null 2>&1; then
    check_pass "Docker login successful"
else
    check_fail "Docker login failed"
fi
echo ""

# Check 6: Push/Pull Test
echo -e "${YELLOW}[6/10] Testing image push/pull...${NC}"
if docker pull alpine:3.18 >/dev/null 2>&1; then
    docker tag alpine:3.18 "$HARBOR_HOST/library/alpine:3.18"
    
    if docker push "$HARBOR_HOST/library/alpine:3.18" >/dev/null 2>&1; then
        check_pass "Image push successful"
        
        docker rmi alpine:3.18 "$HARBOR_HOST/library/alpine:3.18" >/dev/null 2>&1
        
        if docker pull "$HARBOR_HOST/library/alpine:3.18" >/dev/null 2>&1; then
            check_pass "Image pull successful"
        else
            check_fail "Image pull failed"
        fi
    else
        check_fail "Image push failed"
    fi
else
    check_warn "Cannot pull alpine:3.18 for testing (expected in air-gap)"
fi
echo ""

# Check 7: PostgreSQL
echo -e "${YELLOW}[7/10] Checking PostgreSQL...${NC}"
if docker exec harbor-db psql -U postgres -d harbor -c "SELECT 1;" >/dev/null 2>&1; then
    check_pass "PostgreSQL is accessible"
    
    # Check tables
    TABLE_COUNT=$(docker exec harbor-db psql -U postgres -d harbor -c "\dt" | grep "public" | wc -l)
    if [ "$TABLE_COUNT" -gt 10 ]; then
        check_pass "Harbor tables created ($TABLE_COUNT tables)"
    else
        check_warn "Only $TABLE_COUNT tables found"
    fi
else
    check_fail "Cannot connect to PostgreSQL"
fi
echo ""

# Check 8: Redis
echo -e "${YELLOW}[8/10] Checking Redis...${NC}"
if docker exec redis redis-cli ping | grep -q "PONG"; then
    check_pass "Redis is responding"
else
    check_fail "Redis is not responding"
fi
echo ""

# Check 9: Storage
echo -e "${YELLOW}[9/10] Checking storage...${NC}"
if [ -d /data/harbor/registry ]; then
    STORAGE_SIZE=$(du -sh /data/harbor/registry 2>/dev/null | cut -f1)
    check_pass "Registry storage exists ($STORAGE_SIZE)"
    
    # Check disk space
    FREE_SPACE=$(df /data/harbor | tail -1 | awk '{print $4}')
    FREE_SPACE_GB=$((FREE_SPACE / 1024 / 1024))
    if [ "$FREE_SPACE_GB" -gt 10 ]; then
        check_pass "Free space: ${FREE_SPACE_GB}GB (>10GB)"
    else
        check_warn "Free space: ${FREE_SPACE_GB}GB (low)"
    fi
else
    check_fail "/data/harbor/registry not found"
fi
echo ""

# Check 10: Logs
echo -e "${YELLOW}[10/10] Checking for errors in logs...${NC}"
ERROR_COUNT=$(docker-compose -f /data/harbor/docker-compose.yml logs --tail=100 2>/dev/null | grep -i error | wc -l)
if [ "$ERROR_COUNT" -eq 0 ]; then
    check_pass "No errors in recent logs"
else
    check_warn "Found $ERROR_COUNT error(s) in logs"
    echo "  Check: docker-compose -f /data/harbor/docker-compose.yml logs"
fi
echo ""

# Summary
echo "========================================"
echo -e "${BLUE}Verification Summary${NC}"
echo "========================================"
echo ""
echo -e "Passed:   ${GREEN}$PASSED${NC}"
echo -e "Failed:   ${RED}$FAILED${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    if [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✓ All checks passed! Harbor is ready to use.${NC}"
        echo ""
        echo "Next steps:"
        echo "1. Login to Web UI: https://$HARBOR_HOST (admin/$ADMIN_PASSWORD)"
        echo "2. Change admin password"
        echo "3. Create projects"
        echo "4. Configure RBAC"
        echo "5. Setup vulnerability scanning"
        exit 0
    else
        echo -e "${YELLOW}⚠ Harbor is operational with warnings.${NC}"
        echo "Review warnings above."
        exit 0
    fi
else
    echo -e "${RED}✗ Harbor has issues that need to be fixed.${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo "1. Check container logs: docker-compose logs"
    echo "2. Verify harbor.yml configuration"
    echo "3. Check TLS certificates"
    echo "4. Verify DNS and network"
    echo "5. Check disk space"
    exit 1
fi
