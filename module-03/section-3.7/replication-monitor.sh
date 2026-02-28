#!/bin/bash
# replication-monitor.sh
# Monitor Harbor replication status and alert on failures
#
# Usage: ./replication-monitor.sh [--alert-command "notify.sh"]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

HARBOR_URL="${HARBOR_URL:-https://harbor.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
ALERT_COMMAND="${2:-}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-24}"

echo "Harbor Replication Monitor"
echo "=========================================="
echo ""

# Check credentials
if [ -z "$HARBOR_PASS" ]; then
    read -sp "Enter Harbor admin password: " HARBOR_PASS
    echo ""
fi

# Get all replication policies
POLICIES=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/replication/policies")

if ! echo "$POLICIES" | jq -e '.[0]' >/dev/null 2>&1; then
    echo "No replication policies found"
    exit 0
fi

POLICY_COUNT=$(echo "$POLICIES" | jq 'length')
echo "Found $POLICY_COUNT replication policies"
echo ""

# Track issues
FAILED_POLICIES=()
STALE_POLICIES=()
CURRENT_TIMESTAMP=$(date +%s)

# Check each policy
echo "$POLICIES" | jq -r '.[] | "\(.id)|\(.name)|\(.enabled)"' | \
while IFS='|' read -r POLICY_ID POLICY_NAME ENABLED; do
    
    echo -e "${YELLOW}Policy: $POLICY_NAME${NC}"
    echo "  ID: $POLICY_ID"
    echo "  Enabled: $ENABLED"
    
    if [ "$ENABLED" != "true" ]; then
        echo -e "  ${YELLOW}⚠ Policy is disabled${NC}"
        echo ""
        continue
    fi
    
    # Get recent executions
    EXECUTIONS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/replication/executions?policy_id=$POLICY_ID&page_size=5")
    
    EXEC_COUNT=$(echo "$EXECUTIONS" | jq 'length')
    
    if [ "$EXEC_COUNT" -eq 0 ]; then
        echo -e "  ${YELLOW}⚠ No executions found${NC}"
        STALE_POLICIES+=("$POLICY_NAME:never_run")
        echo ""
        continue
    fi
    
    # Get latest execution
    LATEST=$(echo "$EXECUTIONS" | jq -r '.[0]')
    
    STATUS=$(echo "$LATEST" | jq -r '.status')
    END_TIME=$(echo "$LATEST" | jq -r '.end_time')
    TOTAL=$(echo "$LATEST" | jq -r '.total')
    SUCCESS=$(echo "$LATEST" | jq -r '.succeed')
    FAILED=$(echo "$LATEST" | jq -r '.failed')
    
    echo "  Latest execution:"
    echo "    Status: $STATUS"
    echo "    Total: $TOTAL, Success: $SUCCESS, Failed: $FAILED"
    echo "    End time: $END_TIME"
    
    # Check status
    if [ "$STATUS" == "Failed" ] || [ "$STATUS" == "Stopped" ]; then
        echo -e "  ${RED}✗ Replication failed${NC}"
        FAILED_POLICIES+=("$POLICY_NAME:$STATUS")
    elif [ "$STATUS" == "Succeed" ]; then
        echo -e "  ${GREEN}✓ Replication succeeded${NC}"
    elif [ "$STATUS" == "InProgress" ]; then
        echo -e "  ${YELLOW}⟳ Replication in progress${NC}"
    fi
    
    # Check age
    if [ "$END_TIME" != "null" ]; then
        END_TIMESTAMP=$(date -d "$END_TIME" +%s 2>/dev/null || echo "0")
        
        if [ "$END_TIMESTAMP" -gt 0 ]; then
            AGE_HOURS=$(( (CURRENT_TIMESTAMP - END_TIMESTAMP) / 3600 ))
            
            echo "    Age: ${AGE_HOURS}h"
            
            if [ "$AGE_HOURS" -gt "$MAX_AGE_HOURS" ]; then
                echo -e "  ${YELLOW}⚠ Replication is stale (>${MAX_AGE_HOURS}h)${NC}"
                STALE_POLICIES+=("$POLICY_NAME:${AGE_HOURS}h")
            fi
        fi
    fi
    
    # Show failed tasks if any
    if [ "$FAILED" -gt 0 ]; then
        echo "  Failed tasks:"
        
        TASKS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
            "$HARBOR_URL/api/v2.0/replication/executions/$(echo "$LATEST" | jq -r '.id')/tasks")
        
        echo "$TASKS" | jq -r '.[] | select(.status=="Failed") | 
            "    - \(.resource_type): \(.src_resource) → \(.dst_resource)"' | head -5
    fi
    
    echo ""
done

# Summary
echo "=========================================="
echo "Replication Monitor Summary"
echo "=========================================="
echo ""

if [ ${#FAILED_POLICIES[@]} -eq 0 ] && [ ${#STALE_POLICIES[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All replication policies healthy${NC}"
    EXIT_CODE=0
else
    if [ ${#FAILED_POLICIES[@]} -gt 0 ]; then
        echo -e "${RED}Failed Policies (${#FAILED_POLICIES[@]}):${NC}"
        for POLICY in "${FAILED_POLICIES[@]}"; do
            echo "  - $POLICY"
        done
        echo ""
    fi
    
    if [ ${#STALE_POLICIES[@]} -gt 0 ]; then
        echo -e "${YELLOW}Stale Policies (${#STALE_POLICIES[@]}):${NC}"
        for POLICY in "${STALE_POLICIES[@]}"; do
            echo "  - $POLICY"
        done
        echo ""
    fi
    
    EXIT_CODE=1
    
    # Send alert if command provided
    if [ -n "$ALERT_COMMAND" ]; then
        echo "Sending alert..."
        
        MESSAGE="Harbor Replication Alert:\\n"
        MESSAGE+="Failed: ${#FAILED_POLICIES[@]}\\n"
        MESSAGE+="Stale: ${#STALE_POLICIES[@]}\\n"
        
        if [ ${#FAILED_POLICIES[@]} -gt 0 ]; then
            MESSAGE+="\\nFailed policies:\\n"
            for POLICY in "${FAILED_POLICIES[@]}"; do
                MESSAGE+="- $POLICY\\n"
            done
        fi
        
        if command -v "$ALERT_COMMAND" >/dev/null 2>&1; then
            echo -e "$MESSAGE" | $ALERT_COMMAND
            echo "Alert sent"
        else
            echo "WARNING: Alert command not found: $ALERT_COMMAND"
        fi
    fi
fi

echo ""
exit $EXIT_CODE
