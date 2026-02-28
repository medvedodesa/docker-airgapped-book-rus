#!/bin/bash
# dnf-download-from-manifest.sh
# Download RPM packages from manifest (RHEL/CentOS/Rocky/AlmaLinux)
#
# Usage: ./dnf-download-from-manifest.sh [manifest-file]
# Example: ./dnf-download-from-manifest.sh manifest.txt

set -euo pipefail

MANIFEST_FILE="${1:-manifest.txt}"
PACKAGES_DIR="./packages"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    echo "Usage: sudo $0 $MANIFEST_FILE"
    exit 1
fi

# Check if manifest exists
if [ ! -f "$MANIFEST_FILE" ]; then
    echo -e "${RED}ERROR: Manifest file not found: $MANIFEST_FILE${NC}"
    exit 1
fi

# Check if dnf is available
if ! command -v dnf &> /dev/null; then
    echo -e "${RED}ERROR: dnf command not found${NC}"
    echo "This script is for RHEL/CentOS/Rocky/AlmaLinux"
    exit 1
fi

mkdir -p "$PACKAGES_DIR"

echo -e "${GREEN}Downloading packages from $MANIFEST_FILE...${NC}"
echo "---"

TOTAL_LINES=$(grep -v '^#' "$MANIFEST_FILE" | grep -v '^$' | wc -l)
CURRENT=0

while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    CURRENT=$((CURRENT + 1))
    
    echo -e "${YELLOW}[$CURRENT/$TOTAL_LINES] Downloading: $line${NC}"
    
    # Download with dependencies
    if dnf download --resolve \
                 --alldeps \
                 --destdir="$PACKAGES_DIR" \
                 "$line" 2>&1 | grep -v "^Last metadata"; then
        echo -e "${GREEN}✓ Downloaded${NC}"
    else
        echo -e "${RED}✗ ERROR: Failed to download $line${NC}"
        exit 1
    fi
done < "$MANIFEST_FILE"

PKG_COUNT=$(ls -1 "$PACKAGES_DIR"/*.rpm 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$PACKAGES_DIR" | cut -f1)

echo ""
echo -e "${GREEN}Downloaded $PKG_COUNT packages (Total size: $TOTAL_SIZE)${NC}"

# Create package list
ls -1 "$PACKAGES_DIR" > "$PACKAGES_DIR/package-list.txt"

echo ""
echo -e "${GREEN}✓ Download complete!${NC}"
echo "Packages stored in: $PACKAGES_DIR"
echo "Package list: $PACKAGES_DIR/package-list.txt"
