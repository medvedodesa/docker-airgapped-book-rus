#!/bin/bash
# sign-workflow.sh
# Helper script for signing Docker images with Notary
#
# Usage: ./sign-workflow.sh <image:tag>

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

IMAGE="${1:-}"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image:tag>"
    echo "Example: $0 harbor.company.local/myproject/app:v1.0"
    exit 1
fi

echo -e "${BLUE}Docker Image Signing Workflow${NC}"
echo "=========================================="
echo "Image: $IMAGE"
echo ""

# Check if Content Trust is enabled
if [ "${DOCKER_CONTENT_TRUST:-0}" != "1" ]; then
    echo -e "${YELLOW}WARNING: Content Trust is not enabled${NC}"
    echo "Enable with: export DOCKER_CONTENT_TRUST=1"
    echo ""
    read -p "Enable for this session? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        export DOCKER_CONTENT_TRUST=1
        echo -e "${GREEN}✓ Content Trust enabled${NC}"
    else
        echo "Continuing without Content Trust"
    fi
    echo ""
fi

# Step 1: Check if image exists locally
echo -e "${YELLOW}Step 1: Checking local image...${NC}"
if docker images "$IMAGE" | grep -v REPOSITORY | grep -q .; then
    echo -e "${GREEN}✓ Image exists locally${NC}"
    
    # Show image details
    docker images "$IMAGE" --format "table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}"
else
    echo -e "${RED}ERROR: Image not found locally${NC}"
    echo "Build or pull the image first:"
    echo "  docker build -t $IMAGE ."
    echo "  OR"
    echo "  docker pull $IMAGE (if already in registry)"
    exit 1
fi
echo ""

# Step 2: Check existing signature
echo -e "${YELLOW}Step 2: Checking existing signature...${NC}"
if docker trust inspect "$IMAGE" &>/dev/null; then
    echo -e "${GREEN}Image is already signed${NC}"
    docker trust inspect "$IMAGE" | jq -r '.[].SignedTags[] | "Tag: \(.SignedTag), Digest: \(.Digest)"'
    echo ""
    read -p "Re-sign anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping signing"
        exit 0
    fi
else
    echo "Image is not signed yet"
fi
echo ""

# Step 3: Push and sign
echo -e "${YELLOW}Step 3: Pushing and signing image...${NC}"
echo "This will:"
echo "  1. Push image layers to Harbor"
echo "  2. Generate image digest"
echo "  3. Sign digest with your key"
echo "  4. Upload signature to Notary"
echo ""

if [ "${DOCKER_CONTENT_TRUST}" == "1" ]; then
    echo "Content Trust is ENABLED - image will be signed"
else
    echo -e "${YELLOW}WARNING: Content Trust is DISABLED - image will NOT be signed${NC}"
fi
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

if docker push "$IMAGE"; then
    echo ""
    echo -e "${GREEN}✓ Image pushed and signed successfully${NC}"
else
    echo ""
    echo -e "${RED}✗ Push failed${NC}"
    exit 1
fi
echo ""

# Step 4: Verify signature
echo -e "${YELLOW}Step 4: Verifying signature...${NC}"
if docker trust inspect "$IMAGE" &>/dev/null; then
    echo -e "${GREEN}✓ Signature verified${NC}"
    echo ""
    docker trust inspect "$IMAGE" --pretty
else
    echo -e "${RED}✗ No signature found${NC}"
    exit 1
fi
echo ""

# Step 5: Show signers
echo -e "${YELLOW}Step 5: Signature details...${NC}"
SIGNERS=$(docker trust inspect "$IMAGE" | jq -r '.[].Signers[].Name' 2>/dev/null || echo "None")
echo "Signed by: $SIGNERS"

DIGEST=$(docker trust inspect "$IMAGE" | jq -r '.[].SignedTags[0].Digest' 2>/dev/null || echo "Unknown")
echo "Digest: $DIGEST"
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Signing Complete${NC}"
echo "=========================================="
echo ""
echo "Image: $IMAGE"
echo "Signed by: $SIGNERS"
echo "Digest: $DIGEST"
echo ""
echo "Users can now pull this signed image:"
echo "  export DOCKER_CONTENT_TRUST=1"
echo "  docker pull $IMAGE"
echo ""
echo "Signature will be verified automatically on pull"
echo ""
