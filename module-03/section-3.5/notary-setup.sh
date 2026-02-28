#!/bin/bash
# notary-setup.sh
# Setup Docker Content Trust with Harbor Notary
#
# Usage: ./notary-setup.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

HARBOR_URL="${HARBOR_URL:-harbor.company.local}"

echo -e "${BLUE}Harbor Notary Setup${NC}"
echo "=========================================="
echo ""

# Step 1: Verify Harbor has Notary
echo -e "${YELLOW}Step 1: Verifying Notary is enabled...${NC}"
if docker ps | grep -q notary-server; then
    echo -e "${GREEN}✓ Notary server is running${NC}"
else
    echo -e "${RED}ERROR: Notary server not found${NC}"
    echo "Harbor must be installed with --with-notary flag"
    exit 1
fi

if docker ps | grep -q notary-signer; then
    echo -e "${GREEN}✓ Notary signer is running${NC}"
else
    echo -e "${RED}ERROR: Notary signer not found${NC}"
    exit 1
fi
echo ""

# Step 2: Configure Docker client
echo -e "${YELLOW}Step 2: Configuring Docker client...${NC}"

# Add to shell profile
SHELL_RC="$HOME/.bashrc"
if [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
fi

if grep -q "DOCKER_CONTENT_TRUST" "$SHELL_RC"; then
    echo "Content Trust already configured in $SHELL_RC"
else
    echo "" >> "$SHELL_RC"
    echo "# Docker Content Trust (Harbor Notary)" >> "$SHELL_RC"
    echo "export DOCKER_CONTENT_TRUST=1" >> "$SHELL_RC"
    echo "export DOCKER_CONTENT_TRUST_SERVER=https://$HARBOR_URL:4443" >> "$SHELL_RC"
    echo -e "${GREEN}✓ Added Content Trust configuration to $SHELL_RC${NC}"
fi

# Set for current session
export DOCKER_CONTENT_TRUST=1
export DOCKER_CONTENT_TRUST_SERVER=https://$HARBOR_URL:4443

echo "Environment variables set:"
echo "  DOCKER_CONTENT_TRUST=1"
echo "  DOCKER_CONTENT_TRUST_SERVER=https://$HARBOR_URL:4443"
echo ""

# Step 3: Test connection to Notary
echo -e "${YELLOW}Step 3: Testing Notary connection...${NC}"
if curl -k -s "https://$HARBOR_URL:4443/_notary_server/health" | grep -q "OK"; then
    echo -e "${GREEN}✓ Notary server is accessible${NC}"
else
    echo -e "${YELLOW}WARNING: Cannot connect to Notary server${NC}"
    echo "Check firewall and TLS certificates"
fi
echo ""

# Step 4: Create test repository
echo -e "${YELLOW}Step 4: Testing signed image push...${NC}"
echo "This will initialize Content Trust keys if not present"
echo ""

read -p "Test repository (e.g., library/test-signing): " REPO
if [ -z "$REPO" ]; then
    REPO="library/test-signing"
fi

IMAGE="$HARBOR_URL/$REPO:v1.0"

echo "Test image: $IMAGE"
echo ""

# Check if alpine exists locally
if docker images alpine:3.18 | grep -q alpine; then
    echo -e "${GREEN}✓ Using local alpine:3.18${NC}"
    docker tag alpine:3.18 "$IMAGE"
else
    echo "No local alpine image found"
    echo "Pull alpine manually or use existing image"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

echo ""
echo "Attempting signed push..."
echo "You will be prompted for passphrases:"
echo "  1. Root key passphrase (CRITICAL - backup this!)"
echo "  2. Repository key passphrase"
echo ""

if docker push "$IMAGE"; then
    echo ""
    echo -e "${GREEN}✓ Successfully pushed signed image${NC}"
    
    # Verify
    echo ""
    echo "Verifying signature..."
    docker trust inspect "$IMAGE" | head -20
else
    echo ""
    echo -e "${YELLOW}Push may have failed. Common reasons:${NC}"
    echo "- Harbor credentials not configured"
    echo "- Network connectivity"
    echo "- Image doesn't exist locally"
fi
echo ""

# Step 5: Backup keys
echo -e "${YELLOW}Step 5: Backing up Content Trust keys...${NC}"
BACKUP_DIR="$HOME/docker-trust-backup-$(date +%Y%m%d-%H%M%S)"

if [ -d "$HOME/.docker/trust/private" ]; then
    mkdir -p "$BACKUP_DIR"
    cp -r "$HOME/.docker/trust/private" "$BACKUP_DIR/"
    
    echo -e "${GREEN}✓ Keys backed up to: $BACKUP_DIR${NC}"
    echo ""
    echo -e "${RED}CRITICAL: Secure this backup!${NC}"
    echo "  - Copy to encrypted USB drive"
    echo "  - Store in physical safe"
    echo "  - Root key compromise = entire system compromise"
    
    # List backed up keys
    echo ""
    echo "Backed up keys:"
    find "$BACKUP_DIR" -name "*.key" -exec basename {} \;
else
    echo "No trust keys found"
    echo "Keys will be created on first signed push"
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Notary Setup Complete${NC}"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Harbor URL: $HARBOR_URL"
echo "  Notary endpoint: https://$HARBOR_URL:4443"
echo "  Keys location: ~/.docker/trust/"
echo "  Backup: $BACKUP_DIR"
echo ""
echo "Next steps:"
echo "1. BACKUP ROOT KEY to secure location"
echo "2. Configure CI/CD signing (see gitlab-ci-signing.yml)"
echo "3. Enable Content Trust in Harbor projects"
echo "4. Distribute public keys to team"
echo ""
echo "Usage examples:"
echo "  # Push signed image:"
echo "  export DOCKER_CONTENT_TRUST=1"
echo "  docker push $HARBOR_URL/myproject/app:v1.0"
echo ""
echo "  # Verify signature:"
echo "  docker trust inspect $HARBOR_URL/myproject/app:v1.0"
echo ""
echo "  # Pull only signed images:"
echo "  export DOCKER_CONTENT_TRUST=1"
echo "  docker pull $HARBOR_URL/myproject/app:v1.0"
echo ""
