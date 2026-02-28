#!/bin/bash
# dr-failover.sh
# Disaster Recovery failover procedure for Harbor
#
# Usage: ./dr-failover.sh [check|failover|failback]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

PRIMARY_URL="${PRIMARY_URL:-https://harbor-moscow.company.local}"
DR_URL="${DR_URL:-https://harbor-spb.company.local}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"

ACTION="${1:-}"

echo -e "${BLUE}Harbor Disaster Recovery Manager${NC}"
echo "=========================================="
echo ""

# Check credentials
if [ -z "$ADMIN_PASS" ]; then
    read -sp "Enter Harbor admin password: " ADMIN_PASS
    echo ""
fi

# Function: Check sync status
check_sync() {
    echo -e "${YELLOW}Checking synchronization status...${NC}"
    echo ""
    
    # Check primary availability
    echo "Testing primary Harbor..."
    if curl -k -s -o /dev/null -w "%{http_code}" -u "$ADMIN_USER:$ADMIN_PASS" \
        "$PRIMARY_URL/api/v2.0/systeminfo" | grep -q "200"; then
        echo -e "${GREEN}✓ Primary Harbor is accessible${NC}"
        PRIMARY_UP=true
    else
        echo -e "${RED}✗ Primary Harbor is DOWN${NC}"
        PRIMARY_UP=false
    fi
    
    # Check DR availability
    echo "Testing DR Harbor..."
    if curl -k -s -o /dev/null -w "%{http_code}" -u "$ADMIN_USER:$ADMIN_PASS" \
        "$DR_URL/api/v2.0/systeminfo" | grep -q "200"; then
        echo -e "${GREEN}✓ DR Harbor is accessible${NC}"
        DR_UP=true
    else
        echo -e "${RED}✗ DR Harbor is DOWN${NC}"
        DR_UP=false
    fi
    
    if [ "$PRIMARY_UP" = false ] && [ "$DR_UP" = false ]; then
        echo -e "${RED}ERROR: Both sites are down!${NC}"
        exit 1
    fi
    
    echo ""
    
    # Compare statistics
    if [ "$PRIMARY_UP" = true ]; then
        PRIMARY_STATS=$(curl -k -s -u "$ADMIN_USER:$ADMIN_PASS" \
            "$PRIMARY_URL/api/v2.0/statistics")
        PRIMARY_REPOS=$(echo "$PRIMARY_STATS" | jq -r '.total_repo_count')
        PRIMARY_PROJECTS=$(echo "$PRIMARY_STATS" | jq -r '.total_project_count')
        
        echo "Primary Harbor:"
        echo "  Projects: $PRIMARY_PROJECTS"
        echo "  Repositories: $PRIMARY_REPOS"
    fi
    
    if [ "$DR_UP" = true ]; then
        DR_STATS=$(curl -k -s -u "$ADMIN_USER:$ADMIN_PASS" \
            "$DR_URL/api/v2.0/statistics")
        DR_REPOS=$(echo "$DR_STATS" | jq -r '.total_repo_count')
        DR_PROJECTS=$(echo "$DR_STATS" | jq -r '.total_project_count')
        
        echo "DR Harbor:"
        echo "  Projects: $DR_PROJECTS"
        echo "  Repositories: $DR_REPOS"
    fi
    
    echo ""
    
    if [ "$PRIMARY_UP" = true ] && [ "$DR_UP" = true ]; then
        # Check replication status
        echo "Checking replication status..."
        
        LAST_REPLICATION=$(curl -k -s -u "$ADMIN_USER:$ADMIN_PASS" \
            "$PRIMARY_URL/api/v2.0/replication/executions?page_size=1" | \
            jq -r '.[0] | "Status: \(.status) End: \(.end_time)"')
        
        echo "Last replication: $LAST_REPLICATION"
        echo ""
        
        # Compare counts
        if [ "$PRIMARY_REPOS" == "$DR_REPOS" ]; then
            echo -e "${GREEN}✓ Repository counts match${NC}"
        else
            DIFF=$((PRIMARY_REPOS - DR_REPOS))
            echo -e "${YELLOW}⚠ Repository count mismatch (diff: $DIFF)${NC}"
        fi
    fi
    
    echo ""
    echo "=========================================="
    echo "Sync Status Summary"
    echo "=========================================="
    echo "Primary: $([ "$PRIMARY_UP" = true ] && echo "UP" || echo "DOWN")"
    echo "DR: $([ "$DR_UP" = true ] && echo "UP" || echo "DOWN")"
    
    if [ "$PRIMARY_UP" = true ] && [ "$DR_UP" = true ]; then
        SYNC_PERCENT=$((DR_REPOS * 100 / PRIMARY_REPOS))
        echo "Sync: ${SYNC_PERCENT}%"
    fi
    echo ""
}

# Function: Perform failover
perform_failover() {
    echo -e "${RED}=========================================${NC}"
    echo -e "${RED}DISASTER RECOVERY FAILOVER${NC}"
    echo -e "${RED}=========================================${NC}"
    echo ""
    echo "This will:"
    echo "1. Verify DR Harbor is ready"
    echo "2. Provide DNS update instructions"
    echo "3. Disable replication rules"
    echo ""
    
    read -p "Continue with failover? (type 'YES' to confirm): " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Failover cancelled"
        exit 0
    fi
    
    echo ""
    
    # Step 1: Verify DR is accessible
    echo -e "${YELLOW}Step 1: Verifying DR Harbor...${NC}"
    
    if ! curl -k -s -o /dev/null -w "%{http_code}" -u "$ADMIN_USER:$ADMIN_PASS" \
        "$DR_URL/api/v2.0/systeminfo" | grep -q "200"; then
        echo -e "${RED}ERROR: DR Harbor is not accessible${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ DR Harbor is ready${NC}"
    echo ""
    
    # Step 2: Get DR statistics
    echo -e "${YELLOW}Step 2: Checking DR content...${NC}"
    
    DR_STATS=$(curl -k -s -u "$ADMIN_USER:$ADMIN_PASS" \
        "$DR_URL/api/v2.0/statistics")
    
    echo "DR Harbor contains:"
    echo "  Projects: $(echo "$DR_STATS" | jq -r '.total_project_count')"
    echo "  Repositories: $(echo "$DR_STATS" | jq -r '.total_repo_count')"
    echo ""
    
    # Step 3: DNS update instructions
    echo -e "${YELLOW}Step 3: DNS Update Required${NC}"
    echo ""
    echo "Update DNS to point to DR Harbor:"
    echo ""
    echo "Option A - DNS Update:"
    echo "  1. Edit DNS server configuration"
    echo "  2. Change: harbor.company.local → DR IP"
    echo "  3. Propagate DNS changes"
    echo ""
    echo "Option B - /etc/hosts (temporary):"
    echo "  On each Docker host, update /etc/hosts:"
    echo "  # Old: <primary-ip> harbor.company.local"
    echo "  <dr-ip> harbor.company.local"
    echo ""
    
    read -p "DNS updated? (y/N) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Complete DNS update and re-run this script"
        exit 0
    fi
    
    # Step 4: Disable replication rules on primary (if accessible)
    echo ""
    echo -e "${YELLOW}Step 4: Disabling replication rules...${NC}"
    
    if curl -k -s -o /dev/null -w "%{http_code}" -u "$ADMIN_USER:$ADMIN_PASS" \
        "$PRIMARY_URL/api/v2.0/systeminfo" | grep -q "200"; then
        
        echo "Primary is still accessible, disabling replication rules..."
        
        RULES=$(curl -k -s -u "$ADMIN_USER:$ADMIN_PASS" \
            "$PRIMARY_URL/api/v2.0/replication/policies" | \
            jq -r '.[].id')
        
        for RULE_ID in $RULES; do
            curl -k -s -X PUT -u "$ADMIN_USER:$ADMIN_PASS" \
                -H "Content-Type: application/json" \
                "$PRIMARY_URL/api/v2.0/replication/policies/$RULE_ID" \
                -d '{"enabled": false}' >/dev/null
            echo "  Disabled rule ID: $RULE_ID"
        done
    else
        echo "Primary is not accessible (as expected during disaster)"
    fi
    
    echo ""
    
    # Step 5: Summary
    echo "=========================================="
    echo -e "${GREEN}Failover Complete${NC}"
    echo "=========================================="
    echo ""
    echo "DR Harbor is now PRIMARY"
    echo "URL: $DR_URL"
    echo ""
    echo "Next steps:"
    echo "1. Test Docker login from hosts:"
    echo "   docker login harbor.company.local"
    echo ""
    echo "2. Verify image pulls:"
    echo "   docker pull harbor.company.local/library/alpine:3.18"
    echo ""
    echo "3. Monitor DR Harbor for issues"
    echo ""
    echo "4. When original primary recovered:"
    echo "   Run: ./dr-failover.sh failback"
    echo ""
}

# Function: Perform failback
perform_failback() {
    echo -e "${YELLOW}=========================================${NC}"
    echo -e "${YELLOW}FAILBACK TO PRIMARY${NC}"
    echo -e "${YELLOW}=========================================${NC}"
    echo ""
    echo "This will:"
    echo "1. Sync DR → Primary (reverse replication)"
    echo "2. Verify primary is ready"
    echo "3. Provide DNS restore instructions"
    echo ""
    
    read -p "Continue with failback? (type 'YES' to confirm): " CONFIRM
    
    if [ "$CONFIRM" != "YES" ]; then
        echo "Failback cancelled"
        exit 0
    fi
    
    echo ""
    
    # Step 1: Verify primary is back
    echo -e "${YELLOW}Step 1: Checking primary Harbor...${NC}"
    
    if ! curl -k -s -o /dev/null -w "%{http_code}" -u "$ADMIN_USER:$ADMIN_PASS" \
        "$PRIMARY_URL/api/v2.0/systeminfo" | grep -q "200"; then
        echo -e "${RED}ERROR: Primary Harbor is not accessible${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Primary Harbor is accessible${NC}"
    echo ""
    
    # Step 2: Setup reverse replication
    echo -e "${YELLOW}Step 2: Reverse replication setup...${NC}"
    echo ""
    echo "Manual steps required:"
    echo "1. In DR Harbor (current primary):"
    echo "   - Add original primary as registry endpoint"
    echo "   - Create replication rule: DR → Primary"
    echo "   - Trigger replication"
    echo ""
    echo "2. Wait for replication to complete"
    echo "3. Verify both sites have same content"
    echo ""
    
    read -p "Reverse replication complete? (y/N) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Complete replication and re-run"
        exit 0
    fi
    
    # Step 3: DNS restore
    echo ""
    echo -e "${YELLOW}Step 3: DNS Restore${NC}"
    echo ""
    echo "Restore DNS to point back to primary:"
    echo "  harbor.company.local → Primary IP"
    echo ""
    
    read -p "DNS restored? (y/N) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Complete DNS restore and re-run"
        exit 0
    fi
    
    # Step 4: Re-enable original replication
    echo ""
    echo -e "${YELLOW}Step 4: Re-enabling original replication...${NC}"
    
    RULES=$(curl -k -s -u "$ADMIN_USER:$ADMIN_PASS" \
        "$PRIMARY_URL/api/v2.0/replication/policies" | \
        jq -r '.[].id')
    
    for RULE_ID in $RULES; do
        curl -k -s -X PUT -u "$ADMIN_USER:$ADMIN_PASS" \
            -H "Content-Type: application/json" \
            "$PRIMARY_URL/api/v2.0/replication/policies/$RULE_ID" \
            -d '{"enabled": true}' >/dev/null
        echo "  Enabled rule ID: $RULE_ID"
    done
    
    echo ""
    
    # Summary
    echo "=========================================="
    echo -e "${GREEN}Failback Complete${NC}"
    echo "=========================================="
    echo ""
    echo "Primary Harbor restored"
    echo "Replication: Primary → DR active"
    echo ""
    echo "Verify:"
    echo "1. Test from Docker hosts"
    echo "2. Monitor replication"
    echo "3. Disable reverse replication in DR"
    echo ""
}

# Main
case "$ACTION" in
    check)
        check_sync
        ;;
    failover)
        perform_failover
        ;;
    failback)
        perform_failback
        ;;
    *)
        echo "Usage: $0 [check|failover|failback]"
        echo ""
        echo "Actions:"
        echo "  check    - Check sync status between primary and DR"
        echo "  failover - Perform DR failover (primary → DR)"
        echo "  failback - Failback to primary (DR → primary)"
        echo ""
        echo "Environment variables:"
        echo "  PRIMARY_URL=$PRIMARY_URL"
        echo "  DR_URL=$DR_URL"
        echo "  ADMIN_USER=$ADMIN_USER"
        echo ""
        exit 1
        ;;
esac
