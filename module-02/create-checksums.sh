#!/bin/bash
# create-checksums.sh
# Create SHA256 checksums for all packages
#
# Usage: ./create-checksums.sh [packages-dir]
# Example: ./create-checksums.sh ./packages

set -euo pipefail

PACKAGES_DIR="${1:-./packages}"
CHECKSUMS_FILE="$PACKAGES_DIR/SHA256SUMS"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ ! -d "$PACKAGES_DIR" ]; then
    echo -e "${RED}ERROR: Packages directory not found: $PACKAGES_DIR${NC}"
    exit 1
fi

cd "$PACKAGES_DIR"

echo -e "${YELLOW}Creating SHA256 checksums...${NC}"

# Create checksums for all .deb and .rpm files
{
    find . -maxdepth 1 -name "*.deb" -o -name "*.rpm"
} | while read -r file; do
    sha256sum "$file"
done > SHA256SUMS 2>/dev/null || {
    echo -e "${RED}ERROR: No packages found${NC}"
    exit 1
}

# Count checksums
COUNT=$(wc -l < SHA256SUMS)
echo -e "${GREEN}Created $COUNT checksums${NC}"

# Sign checksums file with GPG if available
if command -v gpg >/dev/null 2>&1; then
    echo -e "${YELLOW}Signing checksums with GPG...${NC}"
    if gpg --clearsign SHA256SUMS 2>/dev/null; then
        echo -e "${GREEN}✓ Checksums signed: SHA256SUMS.asc${NC}"
    else
        echo -e "${YELLOW}⚠ GPG signing failed (no private key?)${NC}"
        echo -e "${YELLOW}  Continuing without signature${NC}"
    fi
else
    echo -e "${YELLOW}⚠ GPG not available, checksums not signed${NC}"
fi

echo ""
echo -e "${GREEN}✓ Checksums created: SHA256SUMS${NC}"
echo ""
echo "First 5 checksums:"
head -5 SHA256SUMS
