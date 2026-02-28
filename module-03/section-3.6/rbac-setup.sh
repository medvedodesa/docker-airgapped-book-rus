#!/bin/bash
# rbac-setup.sh
# Setup RBAC configuration for Harbor projects
#
# Usage: ./rbac-setup.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

HARBOR_URL="${HARBOR_URL:-https://harbor.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"

echo -e "${BLUE}Harbor RBAC Setup${NC}"
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

# Step 1: Create Projects
echo -e "${YELLOW}Step 1: Creating projects...${NC}"

declare -A PROJECTS=(
    ["library"]="true:0"           # public:quota(0=unlimited)
    ["team-billing"]="false:107374182400"   # 100GB
    ["team-analytics"]="false:107374182400"
    ["shared-infra"]="false:53687091200"    # 50GB
)

for PROJECT in "${!PROJECTS[@]}"; do
    IFS=':' read -r PUBLIC QUOTA <<< "${PROJECTS[$PROJECT]}"
    
    # Check if project exists
    if curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects?name=$PROJECT" | \
        jq -e '.[0].name' >/dev/null 2>&1; then
        echo "  Project '$PROJECT' already exists"
    else
        echo "  Creating project '$PROJECT'..."
        
        curl -k -s -X POST -u "$HARBOR_USER:$HARBOR_PASS" \
            -H "Content-Type: application/json" \
            "$HARBOR_URL/api/v2.0/projects" \
            -d "{
              \"project_name\": \"$PROJECT\",
              \"public\": $PUBLIC,
              \"storage_limit\": $QUOTA,
              \"metadata\": {
                \"auto_scan\": \"true\",
                \"prevent_vul\": \"true\",
                \"severity\": \"critical,high\"
              }
            }" >/dev/null
        
        echo -e "    ${GREEN}✓${NC} Created (public=$PUBLIC, quota=$QUOTA)"
    fi
done
echo ""

# Step 2: Add Users to Projects
echo -e "${YELLOW}Step 2: Adding users to projects...${NC}"

# Get project IDs
declare -A PROJECT_IDS
for PROJECT in "${!PROJECTS[@]}"; do
    PROJECT_ID=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects?name=$PROJECT" | \
        jq -r '.[0].project_id')
    PROJECT_IDS[$PROJECT]=$PROJECT_ID
done

# Define memberships
# Format: project:username:role_id
# Role IDs: 1=Admin, 2=Developer, 3=Guest, 4=Maintainer
MEMBERSHIPS=(
    "team-billing:alice:2"      # Developer
    "team-billing:bob:4"        # Maintainer
    "team-billing:charlie:1"    # Project Admin
    "team-analytics:david:2"    # Developer
    "team-analytics:eve:4"      # Maintainer
    "shared-infra:frank:1"      # Project Admin
)

for MEMBERSHIP in "${MEMBERSHIPS[@]}"; do
    IFS=':' read -r PROJECT USERNAME ROLE_ID <<< "$MEMBERSHIP"
    PROJECT_ID=${PROJECT_IDS[$PROJECT]}
    
    # Check if user exists in Harbor
    USER_EXISTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/users/search?username=$USERNAME" | \
        jq -e '.[0].username' >/dev/null 2>&1 && echo "true" || echo "false")
    
    if [ "$USER_EXISTS" == "false" ]; then
        echo "  WARNING: User '$USERNAME' does not exist in Harbor"
        echo "    (User will be created on first LDAP/OIDC login)"
        continue
    fi
    
    # Check if already member
    IS_MEMBER=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT_ID/members" | \
        jq -e ".[] | select(.entity_name==\"$USERNAME\")" >/dev/null 2>&1 && echo "true" || echo "false")
    
    if [ "$IS_MEMBER" == "true" ]; then
        echo "  User '$USERNAME' already member of '$PROJECT'"
    else
        echo "  Adding '$USERNAME' to '$PROJECT' (role_id=$ROLE_ID)..."
        
        curl -k -s -X POST -u "$HARBOR_USER:$HARBOR_PASS" \
            -H "Content-Type: application/json" \
            "$HARBOR_URL/api/v2.0/projects/$PROJECT_ID/members" \
            -d "{
              \"role_id\": $ROLE_ID,
              \"member_user\": {
                \"username\": \"$USERNAME\"
              }
            }" >/dev/null
        
        echo -e "    ${GREEN}✓${NC} Added"
    fi
done
echo ""

# Step 3: Summary
echo -e "${YELLOW}Step 3: Configuration summary...${NC}"

for PROJECT in "${!PROJECT_IDS[@]}"; do
    PROJECT_ID=${PROJECT_IDS[$PROJECT]}
    
    echo "  Project: $PROJECT (ID: $PROJECT_ID)"
    
    # Get members
    MEMBERS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT_ID/members")
    
    MEMBER_COUNT=$(echo "$MEMBERS" | jq 'length')
    echo "    Members: $MEMBER_COUNT"
    
    echo "$MEMBERS" | jq -r '.[] | "      - \(.entity_name): role_id \(.role_id)"' 2>/dev/null || echo "      (none)"
    
    # Get quota
    SUMMARY=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT_ID/summary")
    
    QUOTA_HARD=$(echo "$SUMMARY" | jq -r '.quota.hard.storage // "unlimited"')
    QUOTA_USED=$(echo "$SUMMARY" | jq -r '.quota.used.storage // 0')
    
    if [ "$QUOTA_HARD" != "unlimited" ] && [ "$QUOTA_HARD" != "null" ]; then
        QUOTA_HARD_GB=$((QUOTA_HARD / 1024 / 1024 / 1024))
        QUOTA_USED_GB=$((QUOTA_USED / 1024 / 1024 / 1024))
        echo "    Quota: ${QUOTA_USED_GB}GB / ${QUOTA_HARD_GB}GB"
    else
        echo "    Quota: unlimited"
    fi
    
    echo ""
done

# Summary
echo "=========================================="
echo -e "${GREEN}RBAC Setup Complete${NC}"
echo "=========================================="
echo ""
echo "Projects created: ${#PROJECTS[@]}"
echo "Role assignments: ${#MEMBERSHIPS[@]}"
echo ""
echo "Role IDs Reference:"
echo "  1 = Project Admin"
echo "  2 = Developer"
echo "  3 = Guest"
echo "  4 = Maintainer"
echo "  5 = Limited Guest"
echo ""
echo "Next steps:"
echo "1. Verify configuration in Harbor Web UI"
echo "2. Test access with different users"
echo "3. Configure LDAP/OIDC group mappings"
echo "4. Create robot accounts for CI/CD"
echo ""
