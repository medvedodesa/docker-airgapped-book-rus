#!/bin/bash
# create-root-ca.sh
# Create Root Certificate Authority (CA)
# WARNING: Run this on a SECURE, OFFLINE machine!
#
# Usage: ./create-root-ca.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CA_DIR="/root/ca"

echo -e "${GREEN}Root CA Creation Tool${NC}"
echo "======================================"
echo ""
echo -e "${RED}WARNING: This creates your Root CA private key!${NC}"
echo -e "${RED}Store it securely OFFLINE after creation!${NC}"
echo ""

read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: This script must be run as root${NC}"
    exit 1
fi

# Step 1: Create directory structure
echo -e "${YELLOW}Step 1: Creating directory structure...${NC}"
mkdir -p "$CA_DIR"/{certs,crl,newcerts,private}
chmod 700 "$CA_DIR/private"
touch "$CA_DIR/index.txt"
echo 1000 > "$CA_DIR/serial"
echo -e "${GREEN}✓ Directory structure created${NC}"
echo ""

# Step 2: Copy OpenSSL configuration
echo -e "${YELLOW}Step 2: Setting up OpenSSL configuration...${NC}"
if [ ! -f openssl-ca.cnf ]; then
    echo -e "${RED}ERROR: openssl-ca.cnf not found${NC}"
    echo "Please ensure openssl-ca.cnf is in current directory"
    exit 1
fi

cp openssl-ca.cnf "$CA_DIR/openssl.cnf"
echo -e "${GREEN}✓ OpenSSL configuration copied${NC}"
echo ""

# Step 3: Generate Root CA private key
echo -e "${YELLOW}Step 3: Generating Root CA private key (4096 bit)...${NC}"
echo "You will be asked to enter a passphrase."
echo -e "${RED}CRITICAL: Remember this passphrase!${NC}"
echo ""

cd "$CA_DIR"
openssl genrsa -aes256 -out private/ca.key.pem 4096
chmod 400 private/ca.key.pem

echo ""
echo -e "${GREEN}✓ Root CA private key created${NC}"
echo ""

# Step 4: Create Root CA certificate
echo -e "${YELLOW}Step 4: Creating Root CA certificate...${NC}"
echo "Enter certificate details:"
echo ""

openssl req -config openssl.cnf \
    -key private/ca.key.pem \
    -new -x509 -days 3650 -sha256 \
    -extensions v3_ca \
    -out certs/ca.cert.pem

chmod 444 certs/ca.cert.pem

echo ""
echo -e "${GREEN}✓ Root CA certificate created${NC}"
echo ""

# Step 5: Verify certificate
echo -e "${YELLOW}Step 5: Verifying certificate...${NC}"
openssl x509 -noout -text -in certs/ca.cert.pem | head -20

echo ""
echo -e "${GREEN}✓ Certificate verified${NC}"
echo ""

# Step 6: Create backup
echo -e "${YELLOW}Step 6: Creating backup...${NC}"
BACKUP_FILE="root-ca-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

tar czf "/tmp/$BACKUP_FILE" \
    -C "$CA_DIR" \
    private/ca.key.pem \
    certs/ca.cert.pem \
    openssl.cnf

echo -e "${GREEN}✓ Backup created: /tmp/$BACKUP_FILE${NC}"
echo ""

# Summary
echo "======================================"
echo -e "${GREEN}Root CA Created Successfully!${NC}"
echo "======================================"
echo ""
echo "Root CA files:"
echo "  Private key: $CA_DIR/private/ca.key.pem"
echo "  Certificate: $CA_DIR/certs/ca.cert.pem"
echo "  Backup:      /tmp/$BACKUP_FILE"
echo ""
echo -e "${YELLOW}CRITICAL NEXT STEPS:${NC}"
echo "1. Copy backup to encrypted USB drive"
echo "2. Store USB drive in physical safe"
echo "3. Create offsite backup"
echo "4. After creating Intermediate CA:"
echo "   - REMOVE Root CA from this machine"
echo "   - Store ONLY offline"
echo ""
echo "Root CA Certificate:"
cat certs/ca.cert.pem
