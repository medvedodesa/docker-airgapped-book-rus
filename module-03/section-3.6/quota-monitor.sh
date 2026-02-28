#!/bin/bash
# quota-monitor.sh
# Monitor Harbor storage quotas and send alerts
#
# Usage: ./quota-monitor.sh [--threshold 80] [--alert-command "slack-notify.sh"]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

HARBOR_URL="${HARBOR_URL:-https://harbor.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
THRESHOLD="${2:-80}"  # Alert if usage > 80%
ALERT_COMMAND="${4:-}"

echo "Harbor Quota Monitor"
echo "=========================================="
echo "Threshold: ${THRESHOLD}%"
echo ""

# Check credentials
if [ -z "$HARBOR_PASS" ]; then
    read -sp "Enter Harbor admin password: " HARBOR_PASS
    echo ""
fi

# Get all projects
PROJECTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/projects")

if ! echo "$PROJECTS" | jq -e '.[0]' >/dev/null 2>&1; then
    echo "ERROR: Cannot fetch projects"
    exit 1
fi

# Track alerts
ALERTS=()

# Process each project
echo "$PROJECTS" | jq -r '.[] | "\(.project_id)|\(.name)"' | while IFS='|' read -r PROJECT_ID PROJECT_NAME; do
    # Get quota summary
    SUMMARY=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT_ID/summary")
    
    HARD=$(echo "$SUMMARY" | jq -r '.quota.hard.storage // 0')
    USED=$(echo "$SUMMARY" | jq -r '.quota.used.storage // 0')
    
    # Skip if no quota set
    if [ "$HARD" -eq 0 ] || [ "$HARD" == "null" ]; then
        echo "Project: $PROJECT_NAME (unlimited quota)"
        continue
    fi
    
    # Calculate percentage
    PERCENT=$((USED * 100 / HARD))
    
    # Convert to GB for display
    HARD_GB=$((HARD / 1024 / 1024 / 1024))
    USED_GB=$((USED / 1024 / 1024 / 1024))
    
    # Display status
    if [ "$PERCENT" -ge "$THRESHOLD" ]; then
        echo -e "${RED}⚠ Project: $PROJECT_NAME${NC}"
        echo -e "${RED}  Usage: ${USED_GB}GB / ${HARD_GB}GB (${PERCENT}%)${NC}"
        
        # Add to alerts
        ALERTS+=("$PROJECT_NAME:${PERCENT}%:${USED_GB}GB/${HARD_GB}GB")
        
    elif [ "$PERCENT" -ge 70 ]; then
        echo -e "${YELLOW}⚠ Project: $PROJECT_NAME${NC}"
        echo -e "${YELLOW}  Usage: ${USED_GB}GB / ${HARD_GB}GB (${PERCENT}%)${NC}"
        
    else
        echo -e "${GREEN}✓ Project: $PROJECT_NAME${NC}"
        echo "  Usage: ${USED_GB}GB / ${HARD_GB}GB (${PERCENT}%)"
    fi
    
    # Show top repositories
    REPOS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT_NAME/repositories?page_size=5")
    
    if echo "$REPOS" | jq -e '.[0]' >/dev/null 2>&1; then
        echo "  Top repositories:"
        echo "$REPOS" | jq -r '.[] | "    - \(.name): \(.artifact_count) artifacts"' | head -3
    fi
    
    echo ""
done

# Send alerts if threshold exceeded
if [ ${#ALERTS[@]} -gt 0 ]; then
    echo "=========================================="
    echo -e "${RED}QUOTA ALERTS (${#ALERTS[@]} projects)${NC}"
    echo "=========================================="
    echo ""
    
    for ALERT in "${ALERTS[@]}"; do
        IFS=':' read -r PROJECT PERCENT USAGE <<< "$ALERT"
        echo "  $PROJECT: $USAGE ($PERCENT)"
    done
    echo ""
    
    # Execute alert command if provided
    if [ -n "$ALERT_COMMAND" ]; then
        echo "Executing alert command: $ALERT_COMMAND"
        
        MESSAGE="Harbor Quota Alert: ${#ALERTS[@]} projects over ${THRESHOLD}%"
        for ALERT in "${ALERTS[@]}"; do
            IFS=':' read -r PROJECT PERCENT USAGE <<< "$ALERT"
            MESSAGE="$MESSAGE\n- $PROJECT: $USAGE ($PERCENT)"
        done
        
        if command -v "$ALERT_COMMAND" >/dev/null 2>&1; then
            echo -e "$MESSAGE" | $ALERT_COMMAND
        else
            echo "WARNING: Alert command not found: $ALERT_COMMAND"
        fi
    fi
    
    # Exit with error code if alerts
    exit 1
else
    echo "=========================================="
    echo -e "${GREEN}✓ All projects within quota limits${NC}"
    echo "=========================================="
    exit 0
fi
