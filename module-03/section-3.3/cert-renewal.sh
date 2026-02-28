#!/bin/bash
# cert-renewal.sh
# Renew Harbor TLS certificate
#
# Usage: sudo ./cert-renewal.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

HARBOR_HOST="harbor.company.local"
CERT_PATH="/data/cert"
HARBOR_DIR="/data/harbor"

echo -e "${YELLOW}Harbor Certificate Renewal${NC}"
echo "=========================================="
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}ERROR: Run as root${NC}"
    exit 1
fi

# Step 1: Check current certificate expiry
echo -e "${YELLOW}Step 1: Checking current certificate...${NC}"
if [ ! -f "$CERT_PATH/$HARBOR_HOST.cert.pem" ]; then
    echo -e "${RED}ERROR: Certificate not found${NC}"
    exit 1
fi

EXPIRY_DATE=$(openssl x509 -in "$CERT_PATH/$HARBOR_HOST.cert.pem" -noout -enddate | cut -d= -f2)
EXPIRY_EPOCH=$(date -d "$EXPIRY_DATE" +%s)
CURRENT_EPOCH=$(date +%s)
DAYS_LEFT=$(( ($EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))

echo "Current certificate expires: $EXPIRY_DATE"
echo "Days until expiry: $DAYS_LEFT"
echo ""

if [ $DAYS_LEFT -gt 30 ]; then
    echo -e "${YELLOW}Certificate still valid for $DAYS_LEFT days${NC}"
    read -p "Continue with renewal anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Step 2: Backup old certificate
echo -e "${YELLOW}Step 2: Backing up old certificate...${NC}"
BACKUP_DIR="$CERT_PATH/backups"
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/${HARBOR_HOST}-$(date +%Y%m%d-%H%M%S)"
cp "$CERT_PATH/$HARBOR_HOST.cert.pem" "$BACKUP_FILE.cert.pem"
cp "$CERT_PATH/$HARBOR_HOST.key.pem" "$BACKUP_FILE.key.pem"

echo -e "${GREEN}✓ Backup created: $BACKUP_FILE${NC}"
echo ""

# Step 3: Generate new certificate
echo -e "${YELLOW}Step 3: Generating new certificate...${NC}"
echo "This requires access to your Internal CA"
echo ""
read -p "Path to new certificate file: " NEW_CERT
read -p "Path to new private key file: " NEW_KEY

if [ ! -f "$NEW_CERT" ] || [ ! -f "$NEW_KEY" ]; then
    echo -e "${RED}ERROR: Certificate or key file not found${NC}"
    exit 1
fi

# Verify certificate
echo "Verifying new certificate..."
CERT_CN=$(openssl x509 -in "$NEW_CERT" -noout -subject | grep -oP 'CN\s*=\s*\K[^,]+')
if [ "$CERT_CN" != "$HARBOR_HOST" ]; then
    echo -e "${RED}ERROR: Certificate CN ($CERT_CN) does not match hostname ($HARBOR_HOST)${NC}"
    exit 1
fi

# Verify key matches certificate
CERT_MODULUS=$(openssl x509 -noout -modulus -in "$NEW_CERT" | openssl md5)
KEY_MODULUS=$(openssl rsa -noout -modulus -in "$NEW_KEY" | openssl md5)

if [ "$CERT_MODULUS" != "$KEY_MODULUS" ]; then
    echo -e "${RED}ERROR: Certificate and private key do not match${NC}"
    exit 1
fi

echo -e "${GREEN}✓ New certificate verified${NC}"
echo ""

# Step 4: Install new certificate
echo -e "${YELLOW}Step 4: Installing new certificate...${NC}"
cp "$NEW_CERT" "$CERT_PATH/$HARBOR_HOST.cert.pem"
cp "$NEW_KEY" "$CERT_PATH/$HARBOR_HOST.key.pem"

chmod 644 "$CERT_PATH/$HARBOR_HOST.cert.pem"
chmod 600 "$CERT_PATH/$HARBOR_HOST.key.pem"

echo -e "${GREEN}✓ New certificate installed${NC}"
echo ""

# Step 5: Restart Harbor
echo -e "${YELLOW}Step 5: Restarting Harbor...${NC}"
cd "$HARBOR_DIR"

if [ -f docker-compose.yml ]; then
    docker-compose restart
    echo -e "${GREEN}✓ Harbor restarted${NC}"
else
    echo -e "${RED}ERROR: docker-compose.yml not found in $HARBOR_DIR${NC}"
    echo "Please restart Harbor manually"
fi
echo ""

# Step 6: Verify new certificate
echo -e "${YELLOW}Step 6: Verifying new certificate...${NC}"
sleep 5

NEW_EXPIRY_DATE=$(openssl s_client -connect $HARBOR_HOST:443 </dev/null 2>/dev/null | \
    openssl x509 -noout -enddate | cut -d= -f2)

if [ -z "$NEW_EXPIRY_DATE" ]; then
    echo -e "${RED}WARNING: Could not verify new certificate${NC}"
    echo "Check manually: openssl s_client -connect $HARBOR_HOST:443"
else
    echo "New certificate expires: $NEW_EXPIRY_DATE"
    NEW_EXPIRY_EPOCH=$(date -d "$NEW_EXPIRY_DATE" +%s)
    NEW_DAYS_LEFT=$(( ($NEW_EXPIRY_EPOCH - $CURRENT_EPOCH) / 86400 ))
    echo -e "${GREEN}Valid for $NEW_DAYS_LEFT days${NC}"
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Certificate Renewal Complete!${NC}"
echo "=========================================="
echo ""
echo "Old certificate backup: $BACKUP_FILE"
echo "New certificate expiry: $NEW_EXPIRY_DATE"
echo ""
echo "Next steps:"
echo "1. Verify Harbor is accessible: https://$HARBOR_HOST"
echo "2. Test Docker login: docker login $HARBOR_HOST"
echo "3. Schedule next renewal in ~60 days"
echo ""
