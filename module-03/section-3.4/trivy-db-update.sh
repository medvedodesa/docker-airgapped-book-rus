#!/bin/bash
# trivy-db-update.sh
# Update Trivy vulnerability database in Harbor (air-gap)
#
# Usage: sudo ./trivy-db-update.sh <trivy-db-archive.tar.gz>

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DB_ARCHIVE="${1:-}"
TRIVY_DB_PATH="/data/harbor/trivy-adapter/trivy/db"
HARBOR_DIR="/data/harbor"

echo -e "${YELLOW}Trivy Database Update for Harbor${NC}"
echo "=========================================="
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Run as root${NC}"
    exit 1
fi

# Check argument
if [ -z "$DB_ARCHIVE" ]; then
    echo -e "${RED}ERROR: Database archive required${NC}"
    echo "Usage: $0 <trivy-db-archive.tar.gz>"
    exit 1
fi

if [ ! -f "$DB_ARCHIVE" ]; then
    echo -e "${RED}ERROR: File not found: $DB_ARCHIVE${NC}"
    exit 1
fi

# Step 1: Verify archive
echo -e "${YELLOW}Step 1: Verifying archive...${NC}"
if tar tzf "$DB_ARCHIVE" | grep -q "trivy.db"; then
    echo -e "${GREEN}✓ Archive contains trivy.db${NC}"
else
    echo -e "${RED}ERROR: Archive does not contain trivy.db${NC}"
    exit 1
fi
echo ""

# Step 2: Show current database version
echo -e "${YELLOW}Step 2: Current database version...${NC}"
if [ -f "$TRIVY_DB_PATH/metadata.json" ]; then
    CURRENT_VERSION=$(cat "$TRIVY_DB_PATH/metadata.json" | jq -r '.UpdatedAt // "Unknown"')
    echo "Current DB updated: $CURRENT_VERSION"
else
    echo "No existing database found"
fi
echo ""

# Step 3: Backup current database
echo -e "${YELLOW}Step 3: Backing up current database...${NC}"
BACKUP_DIR="$TRIVY_DB_PATH/backups"
mkdir -p "$BACKUP_DIR"

if [ -f "$TRIVY_DB_PATH/trivy.db" ]; then
    BACKUP_FILE="$BACKUP_DIR/trivy-db-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar czf "$BACKUP_FILE" -C "$TRIVY_DB_PATH" trivy.db metadata.json 2>/dev/null || true
    echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"
else
    echo "No existing database to backup"
fi
echo ""

# Step 4: Stop Harbor
echo -e "${YELLOW}Step 4: Stopping Harbor...${NC}"
cd "$HARBOR_DIR"
if [ -f docker-compose.yml ]; then
    docker-compose stop
    echo -e "${GREEN}✓ Harbor stopped${NC}"
else
    echo -e "${RED}ERROR: docker-compose.yml not found in $HARBOR_DIR${NC}"
    exit 1
fi
echo ""

# Step 5: Extract new database
echo -e "${YELLOW}Step 5: Installing new database...${NC}"
TMP_DIR=$(mktemp -d)
tar xzf "$DB_ARCHIVE" -C "$TMP_DIR"

if [ -f "$TMP_DIR/trivy.db" ]; then
    cp "$TMP_DIR/trivy.db" "$TRIVY_DB_PATH/"
    echo -e "${GREEN}✓ trivy.db installed${NC}"
else
    echo -e "${RED}ERROR: trivy.db not found in archive${NC}"
    rm -rf "$TMP_DIR"
    exit 1
fi

if [ -f "$TMP_DIR/metadata.json" ]; then
    cp "$TMP_DIR/metadata.json" "$TRIVY_DB_PATH/"
    echo -e "${GREEN}✓ metadata.json installed${NC}"
else
    echo "WARNING: metadata.json not found (non-critical)"
fi

# Cleanup
rm -rf "$TMP_DIR"

# Fix permissions
chown -R 10000:10000 "$TRIVY_DB_PATH"
echo -e "${GREEN}✓ Permissions set${NC}"
echo ""

# Step 6: Start Harbor
echo -e "${YELLOW}Step 6: Starting Harbor...${NC}"
docker-compose start
sleep 5

# Check if started
if docker-compose ps | grep -q "Up"; then
    echo -e "${GREEN}✓ Harbor started${NC}"
else
    echo -e "${RED}WARNING: Some containers may not be running${NC}"
    echo "Check: docker-compose ps"
fi
echo ""

# Step 7: Verify new database
echo -e "${YELLOW}Step 7: Verifying new database...${NC}"
if [ -f "$TRIVY_DB_PATH/metadata.json" ]; then
    NEW_VERSION=$(cat "$TRIVY_DB_PATH/metadata.json" | jq -r '.UpdatedAt // "Unknown"')
    echo "New DB updated: $NEW_VERSION"
    
    if [ "$NEW_VERSION" != "$CURRENT_VERSION" ]; then
        echo -e "${GREEN}✓ Database successfully updated${NC}"
    else
        echo -e "${YELLOW}⚠ Database version unchanged${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Cannot verify database version${NC}"
fi
echo ""

# Step 8: Test scan
echo -e "${YELLOW}Step 8: Testing scan functionality...${NC}"
echo "Waiting for Harbor to be fully ready..."
sleep 10

echo "To test scan manually:"
echo "1. Login to Harbor Web UI"
echo "2. Go to any repository"
echo "3. Click SCAN on a tag"
echo "4. Verify scan completes successfully"
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Database Update Complete!${NC}"
echo "=========================================="
echo ""
echo "Old database backed up to: $BACKUP_FILE"
echo "New database version: $NEW_VERSION"
echo ""
echo "Next steps:"
echo "1. Test scan functionality"
echo "2. Trigger rescan of all images (optional):"
echo "   ./rescan-all-images.sh"
echo "3. Monitor Harbor logs for any errors:"
echo "   docker-compose logs trivy-adapter"
echo ""
