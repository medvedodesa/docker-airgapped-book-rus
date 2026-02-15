#!/bin/bash
# verify-download.sh
# Verify all packages from manifest were downloaded
#
# Usage: ./verify-download.sh [manifest-file]
# Example: ./verify-download.sh manifest.txt

set -euo pipefail

MANIFEST_FILE="${1:-manifest.txt}"
PACKAGES_DIR="./packages"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -f "$MANIFEST_FILE" ]; then
    echo -e "${RED}ERROR: Manifest file not found: $MANIFEST_FILE${NC}"
    exit 1
fi

if [ ! -d "$PACKAGES_DIR" ]; then
    echo -e "${RED}ERROR: Packages directory not found: $PACKAGES_DIR${NC}"
    exit 1
fi

echo -e "${YELLOW}Verifying downloaded packages...${NC}"
echo "---"

MISSING=0
FOUND=0

while IFS= read -r line; do
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    # Extract package name (first word before =)
    pkg_name=$(echo "$line" | cut -d'=' -f1 | tr -d ' ')
    
    # Check if any .deb/.rpm file starts with this package name
    if ls "$PACKAGES_DIR/${pkg_name}"*.deb 2>/dev/null | grep -q . || \
       ls "$PACKAGES_DIR/${pkg_name}"*.rpm 2>/dev/null | grep -q .; then
        echo -e "${GREEN}✓ Found: $pkg_name${NC}"
        FOUND=$((FOUND + 1))
    else
        echo -e "${RED}✗ MISSING: $pkg_name${NC}"
        MISSING=$((MISSING + 1))
    fi
done < "$MANIFEST_FILE"

echo "---"
echo "Summary:"
echo -e "  Found: ${GREEN}$FOUND${NC}"
echo -e "  Missing: ${RED}$MISSING${NC}"

if [ $MISSING -eq 0 ]; then
    echo ""
    echo -e "${GREEN}✓ All packages downloaded successfully${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}✗ $MISSING packages missing!${NC}"
    echo "Please re-download missing packages"
    exit 1
fi
