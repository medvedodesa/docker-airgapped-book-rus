#!/bin/bash
# apt-download-from-manifest.sh
# Download packages from manifest for offline installation (Ubuntu/Debian)
#
# Usage: ./apt-download-from-manifest.sh [manifest-file]
# Example: ./apt-download-from-manifest.sh manifest.txt

set -euo pipefail

MANIFEST_FILE="${1:-manifest.txt}"
PACKAGES_DIR="./packages"
CACHE_DIR="/var/cache/apt/archives"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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

# Create packages directory
mkdir -p "$PACKAGES_DIR"

# Clean APT cache
echo -e "${YELLOW}Cleaning APT cache...${NC}"
apt-get clean

# Update package lists
echo -e "${YELLOW}Updating package lists...${NC}"
apt-get update

echo -e "${GREEN}Downloading packages from $MANIFEST_FILE...${NC}"
echo "---"

TOTAL_LINES=$(grep -v '^#' "$MANIFEST_FILE" | grep -v '^$' | wc -l)
CURRENT=0

# Read manifest and download each package
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^#.*$ ]] && continue
    [[ -z "$line" ]] && continue
    
    CURRENT=$((CURRENT + 1))
    
    # Extract package name (before =)
    package=$(echo "$line" | cut -d'=' -f1)
    
    echo -e "${YELLOW}[$CURRENT/$TOTAL_LINES] Downloading: $line${NC}"
    
    # Download package with exact version
    if apt-get install --download-only \
                    --install-recommends \
                    -y \
                    "$line" 2>&1 | grep -v "^Get:"; then
        echo -e "${GREEN}✓ Downloaded${NC}"
    else
        echo -e "${RED}✗ ERROR: Failed to download $line${NC}"
        exit 1
    fi
done < "$MANIFEST_FILE"

# Copy all downloaded packages
echo ""
echo -e "${YELLOW}Copying packages to $PACKAGES_DIR...${NC}"
cp "$CACHE_DIR"/*.deb "$PACKAGES_DIR/" 2>/dev/null || {
    echo -e "${RED}ERROR: No packages found in cache${NC}"
    exit 1
}

# Count packages
PKG_COUNT=$(ls -1 "$PACKAGES_DIR"/*.deb 2>/dev/null | wc -l)
TOTAL_SIZE=$(du -sh "$PACKAGES_DIR" | cut -f1)

echo -e "${GREEN}Downloaded $PKG_COUNT packages (Total size: $TOTAL_SIZE)${NC}"

# Create package list
ls -1 "$PACKAGES_DIR" > "$PACKAGES_DIR/package-list.txt"

echo ""
echo -e "${GREEN}✓ Download complete!${NC}"
echo "Packages stored in: $PACKAGES_DIR"
echo "Package list: $PACKAGES_DIR/package-list.txt"
