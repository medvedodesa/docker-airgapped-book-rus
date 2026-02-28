#!/bin/bash
# replication-setup.sh
# Setup Harbor replication between sites
#
# Usage: ./replication-setup.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

SOURCE_HARBOR="${SOURCE_HARBOR:-https://harbor-moscow.company.local}"
SOURCE_USER="${SOURCE_USER:-admin}"
SOURCE_PASS="${SOURCE_PASS:-}"

echo -e "${BLUE}Harbor Replication Setup${NC}"
echo "=========================================="
echo "Source Harbor: $SOURCE_HARBOR"
echo ""

# Check source credentials
if [ -z "$SOURCE_PASS" ]; then
    read -sp "Enter source Harbor admin password: " SOURCE_PASS
    echo ""
fi

# Test source connection
STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -u "$SOURCE_USER:$SOURCE_PASS" \
    "$SOURCE_HARBOR/api/v2.0/systeminfo")

if [ "$STATUS" != "200" ]; then
    echo -e "${RED}ERROR: Cannot connect to source Harbor${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Connected to source Harbor${NC}"
echo ""

# Step 1: Add destination registry
echo -e "${YELLOW}Step 1: Adding destination registry...${NC}"

read -p "Destination Harbor URL (e.g., https://harbor-spb.company.local): " DEST_URL
read -p "Destination Harbor username: " DEST_USER
read -sp "Destination Harbor password: " DEST_PASS
echo ""
read -p "Registry name (e.g., harbor-spb): " REGISTRY_NAME

echo ""
echo "Testing connection to destination..."

# Test destination connectivity
if curl -k -s -o /dev/null -w "%{http_code}" -u "$DEST_USER:$DEST_PASS" \
    "$DEST_URL/api/v2.0/systeminfo" | grep -q "200"; then
    echo -e "${GREEN}✓ Destination is accessible${NC}"
else
    echo -e "${RED}ERROR: Cannot connect to destination${NC}"
    exit 1
fi

# Check if registry already exists
EXISTING=$(curl -k -s -u "$SOURCE_USER:$SOURCE_PASS" \
    "$SOURCE_HARBOR/api/v2.0/registries" | \
    jq -r ".[] | select(.name==\"$REGISTRY_NAME\") | .id")

if [ -n "$EXISTING" ]; then
    echo "Registry '$REGISTRY_NAME' already exists (ID: $EXISTING)"
    read -p "Delete and recreate? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        curl -k -s -X DELETE -u "$SOURCE_USER:$SOURCE_PASS" \
            "$SOURCE_HARBOR/api/v2.0/registries/$EXISTING"
        echo "Deleted existing registry"
    else
        REGISTRY_ID=$EXISTING
    fi
fi

if [ -z "${REGISTRY_ID:-}" ]; then
    # Create registry endpoint
    RESPONSE=$(curl -k -s -X POST -u "$SOURCE_USER:$SOURCE_PASS" \
        -H "Content-Type: application/json" \
        "$SOURCE_HARBOR/api/v2.0/registries" \
        -d "{
          \"name\": \"$REGISTRY_NAME\",
          \"url\": \"$DEST_URL\",
          \"credential\": {
            \"access_key\": \"$DEST_USER\",
            \"access_secret\": \"$DEST_PASS\",
            \"type\": \"basic\"
          },
          \"insecure\": false,
          \"type\": \"harbor\"
        }")
    
    REGISTRY_ID=$(echo "$RESPONSE" | jq -r '.id')
    
    if [ "$REGISTRY_ID" != "null" ] && [ -n "$REGISTRY_ID" ]; then
        echo -e "${GREEN}✓ Registry endpoint created (ID: $REGISTRY_ID)${NC}"
    else
        echo -e "${RED}ERROR: Failed to create registry${NC}"
        echo "$RESPONSE" | jq '.'
        exit 1
    fi
fi
echo ""

# Step 2: Create replication rule
echo -e "${YELLOW}Step 2: Creating replication rule...${NC}"

read -p "Rule name (e.g., DR-Continuous-Sync): " RULE_NAME

echo ""
echo "Replication trigger type:"
echo "1. Event-based (real-time, on push)"
echo "2. Scheduled (cron)"
echo "3. Manual"
read -p "Select (1-3): " TRIGGER_TYPE

case $TRIGGER_TYPE in
    1)
        TRIGGER='{"type":"event_based","trigger_settings":{"cron":""}}'
        ;;
    2)
        read -p "Cron schedule (e.g., 0 2 * * * for 2 AM daily): " CRON
        TRIGGER="{\"type\":\"scheduled\",\"trigger_settings\":{\"cron\":\"$CRON\"}}"
        ;;
    3)
        TRIGGER='{"type":"manual","trigger_settings":{"cron":""}}'
        ;;
    *)
        echo "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "Replication scope:"
echo "1. All projects"
echo "2. Specific projects"
read -p "Select (1-2): " SCOPE_TYPE

if [ "$SCOPE_TYPE" == "2" ]; then
    read -p "Project names (comma-separated, e.g., library,team-billing): " PROJECTS
    PROJECT_FILTER="\"name\": \"$PROJECTS\""
else
    PROJECT_FILTER='"name": ""'
fi

echo ""
read -p "Replicate deletions (mirror mode)? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    DELETION="true"
else
    DELETION="false"
fi

# Create replication rule
echo ""
echo "Creating replication rule..."

RULE_RESPONSE=$(curl -k -s -X POST -u "$SOURCE_USER:$SOURCE_PASS" \
    -H "Content-Type: application/json" \
    "$SOURCE_HARBOR/api/v2.0/replication/policies" \
    -d "{
      \"name\": \"$RULE_NAME\",
      \"description\": \"Replication from $SOURCE_HARBOR to $DEST_URL\",
      \"src_registry\": null,
      \"dest_registry\": {
        \"id\": $REGISTRY_ID
      },
      \"dest_namespace\": \"\",
      \"dest_namespace_replace_count\": -1,
      \"trigger\": $TRIGGER,
      \"filters\": [
        {
          \"type\": \"resource\",
          \"value\": \"image\"
        },
        {
          \"type\": \"name\",
          $PROJECT_FILTER
        },
        {
          \"type\": \"tag\",
          \"value\": \"**\"
        }
      ],
      \"deletion\": $DELETION,
      \"override\": true,
      \"enabled\": true
    }")

RULE_ID=$(echo "$RULE_RESPONSE" | jq -r '.id // empty')

if [ -n "$RULE_ID" ]; then
    echo -e "${GREEN}✓ Replication rule created (ID: $RULE_ID)${NC}"
else
    echo -e "${RED}ERROR: Failed to create replication rule${NC}"
    echo "$RULE_RESPONSE" | jq '.'
    exit 1
fi
echo ""

# Step 3: Test replication
echo -e "${YELLOW}Step 3: Testing replication...${NC}"

read -p "Trigger test replication now? (y/N) " -n 1 -r
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Triggering replication..."
    
    curl -k -s -X POST -u "$SOURCE_USER:$SOURCE_PASS" \
        "$SOURCE_HARBOR/api/v2.0/replication/executions" \
        -H "Content-Type: application/json" \
        -d "{\"policy_id\": $RULE_ID}" >/dev/null
    
    echo "Replication triggered. Check status in Harbor UI:"
    echo "  Replications → $RULE_NAME → Executions"
    echo ""
    
    sleep 3
    
    # Check status
    EXECUTIONS=$(curl -k -s -u "$SOURCE_USER:$SOURCE_PASS" \
        "$SOURCE_HARBOR/api/v2.0/replication/executions?policy_id=$RULE_ID" | \
        jq -r '.[0] | "Status: \(.status) Total: \(.total) Success: \(.succeed)"')
    
    echo "Latest execution: $EXECUTIONS"
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Replication Setup Complete${NC}"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Source: $SOURCE_HARBOR"
echo "  Destination: $DEST_URL"
echo "  Registry ID: $REGISTRY_ID"
echo "  Rule ID: $RULE_ID"
echo "  Rule Name: $RULE_NAME"
echo "  Trigger: $(echo $TRIGGER | jq -r '.type')"
echo ""
echo "Next steps:"
echo "1. Monitor replication: Replications → $RULE_NAME"
echo "2. Verify images appear on destination"
echo "3. Test pull from destination Harbor"
echo "4. Setup monitoring/alerts for failures"
echo ""
echo "Management:"
echo "  View executions: $SOURCE_HARBOR/harbor/replications"
echo "  Trigger manually: Replications → $RULE_NAME → Replicate"
echo "  Edit rule: Replications → $RULE_NAME → Edit"
echo ""
