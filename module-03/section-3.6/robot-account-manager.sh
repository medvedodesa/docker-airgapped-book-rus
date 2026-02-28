#!/bin/bash
# robot-account-manager.sh
# Manage Harbor robot accounts for CI/CD automation
#
# Usage: ./robot-account-manager.sh [create|list|delete|rotate]

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

ACTION="${1:-}"

echo -e "${BLUE}Harbor Robot Account Manager${NC}"
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

# Function: Create robot account
create_robot() {
    read -p "Project name: " PROJECT
    read -p "Robot account name: " ROBOT_NAME
    read -p "Description: " DESCRIPTION
    read -p "Expiration (days, 0=never): " DURATION
    
    echo ""
    echo "Permissions:"
    echo "1. Pull only"
    echo "2. Pull + Push"
    echo "3. Pull + Push + Delete"
    echo "4. All (Pull + Push + Delete + Scan)"
    read -p "Select (1-4): " PERM_CHOICE
    
    case $PERM_CHOICE in
        1)
            ACTIONS='[{"action":"pull","resource":"repository"}]'
            ;;
        2)
            ACTIONS='[{"action":"pull","resource":"repository"},{"action":"push","resource":"repository"}]'
            ;;
        3)
            ACTIONS='[{"action":"pull","resource":"repository"},{"action":"push","resource":"repository"},{"action":"delete","resource":"repository"}]'
            ;;
        4)
            ACTIONS='[{"action":"pull","resource":"repository"},{"action":"push","resource":"repository"},{"action":"delete","resource":"repository"},{"action":"read","resource":"scan"}]'
            ;;
        *)
            echo "Invalid choice"
            return 1
            ;;
    esac
    
    echo ""
    echo "Creating robot account..."
    
    RESPONSE=$(curl -k -s -X POST -u "$HARBOR_USER:$HARBOR_PASS" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT/robots" \
        -d "{
          \"name\": \"$ROBOT_NAME\",
          \"description\": \"$DESCRIPTION\",
          \"duration\": $DURATION,
          \"permissions\": [
            {
              \"kind\": \"project\",
              \"namespace\": \"$PROJECT\",
              \"access\": $ACTIONS
            }
          ]
        }")
    
    if echo "$RESPONSE" | jq -e '.name' >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Robot account created${NC}"
        echo ""
        echo "========================================"
        echo "SAVE THESE CREDENTIALS (shown only once)"
        echo "========================================"
        echo ""
        echo "Name: $(echo "$RESPONSE" | jq -r '.name')"
        echo "Token: $(echo "$RESPONSE" | jq -r '.secret')"
        echo ""
        echo "Docker login command:"
        echo "docker login $HARBOR_URL \\"
        echo "  -u '$(echo "$RESPONSE" | jq -r '.name')' \\"
        echo "  -p '$(echo "$RESPONSE" | jq -r '.secret')'"
        echo ""
        echo "GitLab CI/CD variables:"
        echo "HARBOR_ROBOT_USERNAME=$(echo "$RESPONSE" | jq -r '.name')"
        echo "HARBOR_ROBOT_TOKEN=$(echo "$RESPONSE" | jq -r '.secret')"
        echo ""
    else
        echo -e "${RED}✗ Failed to create robot account${NC}"
        echo "$RESPONSE" | jq '.'
        return 1
    fi
}

# Function: List robot accounts
list_robots() {
    read -p "Project name (empty for all): " PROJECT
    
    if [ -z "$PROJECT" ]; then
        # List all projects
        PROJECTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
            "$HARBOR_URL/api/v2.0/projects" | jq -r '.[].name')
        
        echo "Robot accounts across all projects:"
        echo ""
        
        for PROJ in $PROJECTS; do
            ROBOTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
                "$HARBOR_URL/api/v2.0/projects/$PROJ/robots")
            
            COUNT=$(echo "$ROBOTS" | jq 'length')
            
            if [ "$COUNT" -gt 0 ]; then
                echo -e "${BLUE}Project: $PROJ${NC}"
                echo "$ROBOTS" | jq -r '.[] | "  \(.id) - \(.name) (expires: \(.expires_at // "never"))"'
                echo ""
            fi
        done
    else
        # List for specific project
        ROBOTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
            "$HARBOR_URL/api/v2.0/projects/$PROJECT/robots")
        
        echo -e "${BLUE}Robot accounts in project: $PROJECT${NC}"
        echo ""
        
        if echo "$ROBOTS" | jq -e '.[0]' >/dev/null 2>&1; then
            echo "$ROBOTS" | jq -r '.[] | 
                "ID: \(.id)\n" +
                "Name: \(.name)\n" +
                "Description: \(.description)\n" +
                "Expires: \(.expires_at // "never")\n" +
                "Disabled: \(.disabled)\n" +
                "---"'
        else
            echo "No robot accounts found"
        fi
    fi
}

# Function: Delete robot account
delete_robot() {
    read -p "Project name: " PROJECT
    read -p "Robot account ID: " ROBOT_ID
    
    echo ""
    read -p "Are you sure you want to delete robot $ROBOT_ID? (y/N) " -n 1 -r
    echo
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        return 0
    fi
    
    STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -X DELETE \
        -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT/robots/$ROBOT_ID")
    
    if [ "$STATUS" == "200" ]; then
        echo -e "${GREEN}✓ Robot account deleted${NC}"
    else
        echo -e "${RED}✗ Failed to delete robot account (HTTP $STATUS)${NC}"
    fi
}

# Function: Rotate robot account
rotate_robot() {
    echo "Robot account rotation process:"
    echo ""
    echo "1. Create new robot account with same permissions"
    echo "2. Update CI/CD credentials with new token"
    echo "3. Test new credentials"
    echo "4. Delete old robot account"
    echo ""
    
    read -p "Project name: " PROJECT
    read -p "Old robot account ID to replace: " OLD_ROBOT_ID
    
    # Get old robot details
    OLD_ROBOT=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT/robots/$OLD_ROBOT_ID")
    
    if ! echo "$OLD_ROBOT" | jq -e '.name' >/dev/null 2>&1; then
        echo -e "${RED}ERROR: Robot account not found${NC}"
        return 1
    fi
    
    OLD_NAME=$(echo "$OLD_ROBOT" | jq -r '.name' | sed 's/.*+//')
    DESCRIPTION=$(echo "$OLD_ROBOT" | jq -r '.description')
    
    echo ""
    echo "Old robot: $(echo "$OLD_ROBOT" | jq -r '.name')"
    echo "Creating new robot with name: ${OLD_NAME}-new"
    echo ""
    
    # Create new robot (simplified - same permissions as old)
    NEW_ROBOT=$(curl -k -s -X POST -u "$HARBOR_USER:$HARBOR_PASS" \
        -H "Content-Type: application/json" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT/robots" \
        -d "{
          \"name\": \"${OLD_NAME}-new\",
          \"description\": \"${DESCRIPTION} (rotated)\",
          \"duration\": 365,
          \"permissions\": $(echo "$OLD_ROBOT" | jq '.permissions')
        }")
    
    if echo "$NEW_ROBOT" | jq -e '.name' >/dev/null 2>&1; then
        echo -e "${GREEN}✓ New robot account created${NC}"
        echo ""
        echo "========================================"
        echo "NEW CREDENTIALS"
        echo "========================================"
        echo ""
        echo "Name: $(echo "$NEW_ROBOT" | jq -r '.name')"
        echo "Token: $(echo "$NEW_ROBOT" | jq -r '.secret')"
        echo ""
        echo "NEXT STEPS:"
        echo "1. Update CI/CD variables with new credentials"
        echo "2. Test new credentials"
        echo "3. Delete old robot: ./robot-account-manager.sh delete"
        echo "   (Old robot ID: $OLD_ROBOT_ID)"
        echo ""
    else
        echo -e "${RED}✗ Failed to create new robot${NC}"
        return 1
    fi
}

# Main menu
case "$ACTION" in
    create)
        create_robot
        ;;
    list)
        list_robots
        ;;
    delete)
        delete_robot
        ;;
    rotate)
        rotate_robot
        ;;
    *)
        echo "Usage: $0 [create|list|delete|rotate]"
        echo ""
        echo "Actions:"
        echo "  create  - Create new robot account"
        echo "  list    - List existing robot accounts"
        echo "  delete  - Delete robot account"
        echo "  rotate  - Rotate robot account credentials"
        echo ""
        exit 1
        ;;
esac
