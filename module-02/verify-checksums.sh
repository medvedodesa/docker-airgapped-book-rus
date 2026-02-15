#!/bin/bash
# verify-checksums.sh
# Verify SHA256 checksums
#
# Usage: ./verify-checksums.sh [packages-dir]
# Example: ./verify-checksums.sh ./packages

set -euo pipefail

PACKAGES_DIR="${1:-./packages}"

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

if [ ! -f SHA256SUMS ]; then
    echo -e "${RED}ERROR: SHA256SUMS not found${NC}"
    echo "Run create-checksums.sh first"
    exit 1
fi

echo -e "${YELLOW}Verifying SHA256 checksums...${NC}"
echo "---"

# Verify checksums
if sha256sum -c SHA256SUMS 2>&1 | tee /tmp/checksum-results.txt | grep -v ": OK$"; then
    : # Show only failed checksums
fi

# Check results
if grep -q "FAILED" /tmp/checksum-results.txt; then
    FAILED_COUNT=$(grep -c "FAILED" /tmp/checksum-results.txt)
    echo "---"
    echo -e "${RED}✗ Checksum verification FAILED${NC}"
    echo -e "${RED}  $FAILED_COUNT file(s) with incorrect checksums${NC}"
    echo ""
    echo "Failed files:"
    grep "FAILED" /tmp/checksum-results.txt
    rm -f /tmp/checksum-results.txt
    exit 1
else
    TOTAL=$(wc -l < SHA256SUMS)
    echo "---"
    echo -e "${GREEN}✓ All $TOTAL checksums valid${NC}"
    rm -f /tmp/checksum-results.txt
    exit 0
fi
