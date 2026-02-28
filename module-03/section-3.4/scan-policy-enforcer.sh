#!/bin/bash
# scan-policy-enforcer.sh
# Enforce vulnerability scan policies across all Harbor projects
#
# Usage: ./scan-policy-enforcer.sh [--dry-run]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

HARBOR_URL="${HARBOR_URL:-https://harbor.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
DRY_RUN=false

# Parse arguments
if [ "${1:-}" == "--dry-run" ]; then
    DRY_RUN=true
    echo -e "${YELLOW}Running in DRY-RUN mode (no changes will be made)${NC}"
    echo ""
fi

echo -e "${BLUE}Harbor Scan Policy Enforcer${NC}"
echo "=========================================="
echo ""

# Check credentials
if [ -z "$HARBOR_PASS" ]; then
    read -sp "Enter Harbor admin password: " HARBOR_PASS
    echo ""
fi

# Test connection
STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/systeminfo")

if [ "$STATUS" != "200" ]; then
    echo -e "${RED}ERROR: Cannot connect to Harbor${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to Harbor${NC}"
echo ""

# Policy Configuration
POLICY_AUTO_SCAN=true
POLICY_PREVENT_VULNERABLE=true
POLICY_SEVERITY="critical,high"

echo "Policy Configuration:"
echo "  Auto scan on push: $POLICY_AUTO_SCAN"
echo "  Prevent vulnerable images: $POLICY_PREVENT_VULNERABLE"
echo "  Block severity: $POLICY_SEVERITY"
echo ""

# Get all projects
echo -e "${YELLOW}Fetching projects...${NC}"
PROJECTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/projects" | jq -r '.[].name')

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)
echo -e "${GREEN}Found $PROJECT_COUNT projects${NC}"
echo ""

# Statistics
UPDATED=0
ALREADY_COMPLIANT=0
FAILED=0

# Process each project
for PROJECT in $PROJECTS; do
    echo -e "${BLUE}Project: $PROJECT${NC}"
    
    # Get current project config
    PROJECT_DATA=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects?name=$PROJECT" | jq -r '.[0]')
    
    PROJECT_ID=$(echo "$PROJECT_DATA" | jq -r '.project_id')
    
    # Get current metadata
    CURRENT_AUTO_SCAN=$(echo "$PROJECT_DATA" | jq -r '.metadata.auto_scan // "false"')
    CURRENT_PREVENT=$(echo "$PROJECT_DATA" | jq -r '.metadata.prevent_vul // "false"')
    CURRENT_SEVERITY=$(echo "$PROJECT_DATA" | jq -r '.metadata.severity // ""')
    
    echo "  Current settings:"
    echo "    Auto scan: $CURRENT_AUTO_SCAN"
    echo "    Prevent vulnerable: $CURRENT_PREVENT"
    echo "    Severity: $CURRENT_SEVERITY"
    
    # Check if update needed
    NEEDS_UPDATE=false
    
    if [ "$CURRENT_AUTO_SCAN" != "$POLICY_AUTO_SCAN" ]; then
        NEEDS_UPDATE=true
    fi
    
    if [ "$CURRENT_PREVENT" != "$POLICY_PREVENT_VULNERABLE" ]; then
        NEEDS_UPDATE=true
    fi
    
    if [ "$CURRENT_SEVERITY" != "$POLICY_SEVERITY" ]; then
        NEEDS_UPDATE=true
    fi
    
    if [ "$NEEDS_UPDATE" == "false" ]; then
        echo -e "  ${GREEN}✓ Already compliant${NC}"
        ALREADY_COMPLIANT=$((ALREADY_COMPLIANT + 1))
    else
        echo -e "  ${YELLOW}⚠ Update required${NC}"
        
        if [ "$DRY_RUN" == "true" ]; then
            echo "  [DRY-RUN] Would update project settings"
            UPDATED=$((UPDATED + 1))
        else
            # Update project metadata
            UPDATE_RESULT=$(curl -k -s -o /dev/null -w "%{http_code}" -X PUT \
                -u "$HARBOR_USER:$HARBOR_PASS" \
                -H "Content-Type: application/json" \
                "$HARBOR_URL/api/v2.0/projects/$PROJECT_ID" \
                -d "{
                  \"metadata\": {
                    \"auto_scan\": \"$POLICY_AUTO_SCAN\",
                    \"prevent_vul\": \"$POLICY_PREVENT_VULNERABLE\",
                    \"severity\": \"$POLICY_SEVERITY\"
                  }
                }")
            
            if [ "$UPDATE_RESULT" == "200" ]; then
                echo -e "  ${GREEN}✓ Updated successfully${NC}"
                UPDATED=$((UPDATED + 1))
            else
                echo -e "  ${RED}✗ Update failed (HTTP $UPDATE_RESULT)${NC}"
                FAILED=$((FAILED + 1))
            fi
        fi
    fi
    echo ""
done

# Global Harbor configuration
echo -e "${YELLOW}Checking global Harbor settings...${NC}"

# Check if auto-scan is enabled globally
SYSTEM_CONFIG=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/configurations")

GLOBAL_AUTO_SCAN=$(echo "$SYSTEM_CONFIG" | jq -r '.scan_all_policy.type // "none"')

echo "Global auto-scan: $GLOBAL_AUTO_SCAN"

if [ "$GLOBAL_AUTO_SCAN" == "none" ]; then
    echo -e "${YELLOW}⚠ Global auto-scan is disabled${NC}"
    echo "Enable in Harbor UI:"
    echo "  Configuration → Interrogation Services → Vulnerability"
    echo "  Check 'Automatically scan images on push'"
else
    echo -e "${GREEN}✓ Global auto-scan is enabled${NC}"
fi
echo ""

# Summary
echo "=========================================="
if [ "$DRY_RUN" == "true" ]; then
    echo -e "${YELLOW}DRY-RUN Summary${NC}"
else
    echo -e "${GREEN}Enforcement Summary${NC}"
fi
echo "=========================================="
echo ""
echo "Total projects: $PROJECT_COUNT"
echo "Already compliant: $ALREADY_COMPLIANT"
echo "Updated: $UPDATED"
echo "Failed: $FAILED"
echo ""

if [ "$DRY_RUN" == "true" ]; then
    echo "Run without --dry-run to apply changes"
elif [ "$UPDATED" -gt 0 ]; then
    echo -e "${GREEN}✓ Policy enforcement complete${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Verify settings in Harbor UI for each project"
    echo "2. Test by pushing a vulnerable image"
    echo "3. Confirm that pull is blocked"
else
    echo -e "${GREEN}✓ All projects already compliant${NC}"
fi
echo ""
