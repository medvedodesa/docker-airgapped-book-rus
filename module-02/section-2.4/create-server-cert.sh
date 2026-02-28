#!/bin/bash
# create-server-cert.sh
# Create server certificate signed by Intermediate CA
#
# Usage: ./create-server-cert.sh <hostname>
# Example: ./create-server-cert.sh harbor.company.local

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

HOSTNAME="${1:-}"
INTERMEDIATE_DIR="/etc/pki/intermediate"

if [ -z "$HOSTNAME" ]; then
    echo -e "${RED}ERROR: Hostname required${NC}"
    echo "Usage: $0 <hostname>"
    echo "Example: $0 harbor.company.local"
    exit 1
fi

echo -e "${GREEN}Server Certificate Creation${NC}"
echo "======================================"
echo "Hostname: $HOSTNAME"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Check if Intermediate CA exists
if [ ! -f "$INTERMEDIATE_DIR/certs/intermediate.cert.pem" ]; then
    echo -e "${RED}ERROR: Intermediate CA not found${NC}"
    echo "Please create Intermediate CA first"
    exit 1
fi

OUTPUT_DIR="./certs/$HOSTNAME"
mkdir -p "$OUTPUT_DIR"

# Step 1: Generate private key
echo -e "${YELLOW}Step 1: Generating private key for $HOSTNAME...${NC}"
openssl genrsa -out "$OUTPUT_DIR/$HOSTNAME.key.pem" 2048
chmod 400 "$OUTPUT_DIR/$HOSTNAME.key.pem"
echo -e "${GREEN}✓ Private key created${NC}"
echo ""

# Step 2: Create CSR (Certificate Signing Request)
echo -e "${YELLOW}Step 2: Creating Certificate Signing Request...${NC}"
echo "Enter certificate details:"
echo ""

openssl req -new -sha256 \
    -key "$OUTPUT_DIR/$HOSTNAME.key.pem" \
    -out "$OUTPUT_DIR/$HOSTNAME.csr.pem" \
    -subj "/C=RU/ST=Moscow/O=Company Name/CN=$HOSTNAME"

echo -e "${GREEN}✓ CSR created${NC}"
echo ""

# Step 3: Sign certificate with Intermediate CA
echo -e "${YELLOW}Step 3: Signing certificate with Intermediate CA...${NC}"
echo "You will need Intermediate CA passphrase"
echo ""

cd "$INTERMEDIATE_DIR"
openssl ca -config openssl.cnf \
    -extensions server_cert \
    -days 90 \
    -notext \
    -md sha256 \
    -in "$OUTPUT_DIR/$HOSTNAME.csr.pem" \
    -out "$OUTPUT_DIR/$HOSTNAME.cert.pem"

chmod 444 "$OUTPUT_DIR/$HOSTNAME.cert.pem"

echo ""
echo -e "${GREEN}✓ Certificate signed${NC}"
echo ""

# Step 4: Create certificate chain
echo -e "${YELLOW}Step 4: Creating certificate chain...${NC}"
cat "$OUTPUT_DIR/$HOSTNAME.cert.pem" \
    certs/intermediate.cert.pem \
    > "$OUTPUT_DIR/$HOSTNAME-chain.cert.pem"

echo -e "${GREEN}✓ Certificate chain created${NC}"
echo ""

# Step 5: Verify certificate
echo -e "${YELLOW}Step 5: Verifying certificate...${NC}"
openssl verify -CAfile certs/ca-chain.cert.pem \
    "$OUTPUT_DIR/$HOSTNAME.cert.pem"

echo ""
echo -e "${GREEN}✓ Certificate verified${NC}"
echo ""

# Summary
echo "======================================"
echo -e "${GREEN}Server Certificate Created!${NC}"
echo "======================================"
echo ""
echo "Certificate files in: $OUTPUT_DIR/"
echo ""
echo "Files to deploy to $HOSTNAME:"
echo "  1. $HOSTNAME.cert.pem      (server certificate)"
echo "  2. $HOSTNAME.key.pem       (private key)"
echo "  3. $HOSTNAME-chain.cert.pem (certificate chain)"
echo ""
echo "Or copy ca-chain.cert.pem from Intermediate CA:"
echo "  cp $INTERMEDIATE_DIR/certs/ca-chain.cert.pem $OUTPUT_DIR/"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Transfer files to $HOSTNAME server"
echo "2. Configure service to use these certificates"
echo "3. Restart service"
echo "4. Test HTTPS connection"
echo ""
echo "Certificate expires: 90 days from now"
echo "Renewal reminder: 30 days before expiry"
