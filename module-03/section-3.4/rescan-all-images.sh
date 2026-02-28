#!/bin/bash
# rescan-all-images.sh
# Rescan all images in Harbor after Trivy DB update
#
# Usage: ./rescan-all-images.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HARBOR_URL="${HARBOR_URL:-https://harbor.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"

echo -e "${BLUE}Harbor Image Rescan Tool${NC}"
echo "=========================================="
echo ""

# Check credentials
if [ -z "$HARBOR_PASS" ]; then
    echo -e "${YELLOW}Harbor password not set in environment${NC}"
    read -sp "Enter Harbor admin password: " HARBOR_PASS
    echo ""
fi

# Test connection
echo -e "${YELLOW}Testing Harbor connection...${NC}"
STATUS=$(curl -k -s -o /dev/null -w "%{http_code}" -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/systeminfo")

if [ "$STATUS" != "200" ]; then
    echo -e "${RED}ERROR: Cannot connect to Harbor (HTTP $STATUS)${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to Harbor${NC}"
echo ""

# Get all projects
echo -e "${YELLOW}Fetching projects...${NC}"
PROJECTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$HARBOR_URL/api/v2.0/projects" | jq -r '.[].name')

if [ -z "$PROJECTS" ]; then
    echo "No projects found"
    exit 0
fi

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)
echo -e "${GREEN}Found $PROJECT_COUNT projects${NC}"
echo ""

# Statistics
TOTAL_SCANNED=0
TOTAL_FAILED=0

# Scan each project
for PROJECT in $PROJECTS; do
    echo -e "${BLUE}Project: $PROJECT${NC}"
    
    # Get repositories
    REPOS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
        "$HARBOR_URL/api/v2.0/projects/$PROJECT/repositories" | \
        jq -r '.[].name' 2>/dev/null || echo "")
    
    if [ -z "$REPOS" ]; then
        echo "  No repositories"
        continue
    fi
    
    REPO_COUNT=$(echo "$REPOS" | wc -l)
    echo "  Repositories: $REPO_COUNT"
    
    for REPO in $REPOS; do
        REPO_NAME=$(echo $REPO | sed "s|$PROJECT/||")
        echo "    Repository: $REPO_NAME"
        
        # Get artifacts
        ARTIFACTS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
            "$HARBOR_URL/api/v2.0/projects/$PROJECT/repositories/$REPO_NAME/artifacts" | \
            jq -r '.[].digest' 2>/dev/null || echo "")
        
        if [ -z "$ARTIFACTS" ]; then
            echo "      No artifacts"
            continue
        fi
        
        # Scan each artifact
        for DIGEST in $ARTIFACTS; do
            # Get tags for this artifact
            TAGS=$(curl -k -s -u "$HARBOR_USER:$HARBOR_PASS" \
                "$HARBOR_URL/api/v2.0/projects/$PROJECT/repositories/$REPO_NAME/artifacts/$DIGEST" | \
                jq -r '.tags[]?.name // "untagged"' 2>/dev/null)
            
            TAG_DISPLAY=$(echo "$TAGS" | head -1)
            echo -n "      Scanning $TAG_DISPLAY... "
            
            # Trigger scan
            SCAN_RESULT=$(curl -k -s -o /dev/null -w "%{http_code}" -X POST \
                -u "$HARBOR_USER:$HARBOR_PASS" \
                "$HARBOR_URL/api/v2.0/projects/$PROJECT/repositories/$REPO_NAME/artifacts/$DIGEST/scan")
            
            if [ "$SCAN_RESULT" == "202" ] || [ "$SCAN_RESULT" == "201" ]; then
                echo -e "${GREEN}OK${NC}"
                TOTAL_SCANNED=$((TOTAL_SCANNED + 1))
            else
                echo -e "${YELLOW}SKIP (HTTP $SCAN_RESULT)${NC}"
                TOTAL_FAILED=$((TOTAL_FAILED + 1))
            fi
            
            # Rate limiting
            sleep 0.5
        done
    done
    echo ""
done

# Summary
echo "=========================================="
echo -e "${GREEN}Rescan Complete${NC}"
echo "=========================================="
echo ""
echo "Projects scanned: $PROJECT_COUNT"
echo "Images scanned: $TOTAL_SCANNED"
echo "Failed/Skipped: $TOTAL_FAILED"
echo ""
echo "Note: Scans are running in background."
echo "Check progress in Harbor Web UI:"
echo "  Administration → Interrogation Services → Vulnerability"
echo ""
