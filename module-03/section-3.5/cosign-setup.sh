#!/bin/bash
# cosign-setup.sh
# Setup Cosign for image signing (alternative to Notary)
#
# Usage: ./cosign-setup.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}Cosign Setup for Harbor${NC}"
echo "=========================================="
echo ""

# Step 1: Check if Cosign is installed
echo -e "${YELLOW}Step 1: Checking Cosign installation...${NC}"
if command -v cosign &>/dev/null; then
    VERSION=$(cosign version | head -1)
    echo -e "${GREEN}✓ Cosign is installed: $VERSION${NC}"
else
    echo "Cosign not found"
    echo ""
    echo "Installation required:"
    echo "  1. On external machine with internet:"
    echo "     wget https://github.com/sigstore/cosign/releases/download/v2.2.2/cosign-linux-amd64"
    echo "     chmod +x cosign-linux-amd64"
    echo ""
    echo "  2. Transfer to air-gap"
    echo ""
    echo "  3. Install:"
    echo "     sudo mv cosign-linux-amd64 /usr/local/bin/cosign"
    echo ""
    
    if [ -f ./cosign ]; then
        echo "Found cosign binary in current directory"
        read -p "Install it now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo cp ./cosign /usr/local/bin/
            sudo chmod +x /usr/local/bin/cosign
            echo -e "${GREEN}✓ Cosign installed${NC}"
        else
            exit 1
        fi
    else
        exit 1
    fi
fi
echo ""

# Step 2: Generate key pair
echo -e "${YELLOW}Step 2: Generating signing key pair...${NC}"

KEY_DIR="$HOME/.cosign"
mkdir -p "$KEY_DIR"

if [ -f "$KEY_DIR/cosign.key" ]; then
    echo "Key pair already exists in $KEY_DIR"
    read -p "Generate new key pair? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Using existing keys"
        echo ""
    else
        echo "Generating new key pair..."
        cosign generate-key-pair --output-key-prefix "$KEY_DIR/cosign"
        echo -e "${GREEN}✓ New key pair generated${NC}"
    fi
else
    echo "Generating key pair..."
    echo "You will be asked to create a password for the private key"
    echo ""
    cosign generate-key-pair --output-key-prefix "$KEY_DIR/cosign"
    echo ""
    echo -e "${GREEN}✓ Key pair generated${NC}"
fi

echo ""
echo "Keys location:"
echo "  Private key: $KEY_DIR/cosign.key (KEEP SECURE)"
echo "  Public key:  $KEY_DIR/cosign.pub (distribute to users)"
echo ""

# Step 3: Backup keys
echo -e "${YELLOW}Step 3: Backing up keys...${NC}"
BACKUP_DIR="$HOME/cosign-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp "$KEY_DIR/cosign.key" "$BACKUP_DIR/"
cp "$KEY_DIR/cosign.pub" "$BACKUP_DIR/"

echo -e "${GREEN}✓ Keys backed up to: $BACKUP_DIR${NC}"
echo ""
echo -e "${RED}CRITICAL: Store backup in secure location!${NC}"
echo "  - Encrypted USB drive"
echo "  - Physical safe"
echo "  - Private key compromise = signature compromise"
echo ""

# Step 4: Test signing
echo -e "${YELLOW}Step 4: Testing image signing...${NC}"

read -p "Test image (e.g., harbor.company.local/library/alpine:3.18): " TEST_IMAGE
if [ -z "$TEST_IMAGE" ]; then
    echo "Skipping test"
else
    # Check if image exists in registry
    echo "Checking if image exists..."
    if docker pull "$TEST_IMAGE" &>/dev/null; then
        echo -e "${GREEN}✓ Image exists${NC}"
        
        echo ""
        echo "Signing image with Cosign..."
        echo "Enter private key password when prompted"
        echo ""
        
        if cosign sign --key "$KEY_DIR/cosign.key" "$TEST_IMAGE"; then
            echo ""
            echo -e "${GREEN}✓ Image signed successfully${NC}"
            
            # Verify
            echo ""
            echo "Verifying signature..."
            if cosign verify --key "$KEY_DIR/cosign.pub" "$TEST_IMAGE"; then
                echo ""
                echo -e "${GREEN}✓ Signature verified${NC}"
            else
                echo ""
                echo -e "${RED}✗ Verification failed${NC}"
            fi
        else
            echo ""
            echo -e "${RED}✗ Signing failed${NC}"
        fi
    else
        echo "Image not found or not accessible"
        echo "Push an image to Harbor first, then run this test"
    fi
fi
echo ""

# Step 5: Distribute public key
echo -e "${YELLOW}Step 5: Public key distribution...${NC}"
echo "Share this public key with all users who need to verify signatures:"
echo ""
cat "$KEY_DIR/cosign.pub"
echo ""

echo "Users can verify signatures with:"
echo "  cosign verify --key cosign.pub $TEST_IMAGE"
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Cosign Setup Complete${NC}"
echo "=========================================="
echo ""
echo "Keys:"
echo "  Private: $KEY_DIR/cosign.key"
echo "  Public:  $KEY_DIR/cosign.pub"
echo "  Backup:  $BACKUP_DIR"
echo ""
echo "Usage:"
echo "  # Sign an image:"
echo "  cosign sign --key $KEY_DIR/cosign.key harbor.company.local/app:v1.0"
echo ""
echo "  # Verify signature:"
echo "  cosign verify --key $KEY_DIR/cosign.pub harbor.company.local/app:v1.0"
echo ""
echo "CI/CD Integration:"
echo "  See gitlab-ci-signing.yml for examples"
echo ""
echo "Next steps:"
echo "  1. Backup private key to secure location"
echo "  2. Distribute public key to team"
echo "  3. Configure CI/CD for automated signing"
echo "  4. Test signature verification in deployment pipeline"
echo ""
