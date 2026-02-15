#!/bin/bash
# verify-gpg.sh
# Verify GPG signatures of all packages
#
# Usage: ./verify-gpg.sh [packages-dir]
# Example: ./verify-gpg.sh ./packages

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

VALID=0
INVALID=0
SKIPPED=0

echo -e "${YELLOW}Verifying GPG signatures...${NC}"
echo "---"

# For .deb packages (Debian/Ubuntu)
for deb in "$PACKAGES_DIR"/*.deb 2>/dev/null; do
    [ -f "$deb" ] || continue
    
    pkg_name=$(basename "$deb")
    
    # Check if dpkg-sig is available
    if ! command -v dpkg-sig &> /dev/null; then
        echo -e "${YELLOW}⊘ SKIPPED: $pkg_name (dpkg-sig not installed)${NC}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    
    if dpkg-sig --verify "$deb" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ VALID: $pkg_name${NC}"
        VALID=$((VALID + 1))
    else
        echo -e "${RED}✗ INVALID: $pkg_name${NC}"
        INVALID=$((INVALID + 1))
    fi
done

# For .rpm packages (RHEL/CentOS)
for rpm in "$PACKAGES_DIR"/*.rpm 2>/dev/null; do
    [ -f "$rpm" ] || continue
    
    pkg_name=$(basename "$rpm")
    
    if rpm --checksig "$rpm" 2>&1 | grep -q "pgp.*OK"; then
        echo -e "${GREEN}✓ VALID: $pkg_name${NC}"
        VALID=$((VALID + 1))
    elif rpm --checksig "$rpm" 2>&1 | grep -q "NOT OK"; then
        echo -e "${RED}✗ INVALID: $pkg_name${NC}"
        INVALID=$((INVALID + 1))
    else
        # No signature or other issue
        echo -e "${YELLOW}⊘ NO SIGNATURE: $pkg_name${NC}"
        SKIPPED=$((SKIPPED + 1))
    fi
done

echo "---"
echo "Summary:"
echo -e "  Valid signatures: ${GREEN}$VALID${NC}"
echo -e "  Invalid signatures: ${RED}$INVALID${NC}"
echo -e "  Skipped/No signature: ${YELLOW}$SKIPPED${NC}"

if [ $INVALID -gt 0 ]; then
    echo ""
    echo -e "${RED}✗ GPG verification FAILED${NC}"
    echo "DO NOT use these packages in production!"
    exit 1
else
    echo ""
    if [ $VALID -gt 0 ]; then
        echo -e "${GREEN}✓ All GPG signatures valid${NC}"
    else
        echo -e "${YELLOW}⚠ No signatures verified (skipped: $SKIPPED)${NC}"
    fi
    exit 0
fi
