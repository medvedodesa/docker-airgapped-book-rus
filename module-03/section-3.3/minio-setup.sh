#!/bin/bash
# minio-setup.sh
# Setup MinIO S3-compatible storage for Harbor
#
# Usage: sudo ./minio-setup.sh

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MINIO_USER="minio"
MINIO_GROUP="minio"
MINIO_DATA_DIR="/data/minio"
MINIO_ROOT_USER="admin"
MINIO_ROOT_PASSWORD="MinioPassword123!"

echo -e "${BLUE}MinIO Setup for Harbor${NC}"
echo "======================================"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Run as root"
    exit 1
fi

# Step 1: Install MinIO binary
echo -e "${YELLOW}Step 1: Installing MinIO binary...${NC}"
if [ -f /usr/local/bin/minio ]; then
    echo "MinIO already installed"
else
    if [ -f ./minio ]; then
        cp ./minio /usr/local/bin/
        chmod +x /usr/local/bin/minio
        echo -e "${GREEN}✓ MinIO binary installed${NC}"
    else
        echo "ERROR: minio binary not found in current directory"
        echo "Download on external machine:"
        echo "  wget https://dl.min.io/server/minio/release/linux-amd64/minio"
        echo "Transfer to air-gap and re-run"
        exit 1
    fi
fi
echo ""

# Step 2: Install MinIO Client (mc)
echo -e "${YELLOW}Step 2: Installing MinIO Client...${NC}"
if [ -f /usr/local/bin/mc ]; then
    echo "MinIO Client already installed"
else
    if [ -f ./mc ]; then
        cp ./mc /usr/local/bin/
        chmod +x /usr/local/bin/mc
        echo -e "${GREEN}✓ MinIO Client installed${NC}"
    else
        echo "WARNING: mc binary not found"
        echo "Download on external machine:"
        echo "  wget https://dl.min.io/client/mc/release/linux-amd64/mc"
    fi
fi
echo ""

# Step 3: Create user and group
echo -e "${YELLOW}Step 3: Creating minio user...${NC}"
if id "$MINIO_USER" &>/dev/null; then
    echo "User $MINIO_USER already exists"
else
    groupadd -r $MINIO_GROUP
    useradd -r -g $MINIO_GROUP -s /sbin/nologin $MINIO_USER
    echo -e "${GREEN}✓ User created${NC}"
fi
echo ""

# Step 4: Create data directory
echo -e "${YELLOW}Step 4: Creating data directory...${NC}"
mkdir -p $MINIO_DATA_DIR
chown -R $MINIO_USER:$MINIO_GROUP $MINIO_DATA_DIR
chmod 750 $MINIO_DATA_DIR
echo -e "${GREEN}✓ Data directory: $MINIO_DATA_DIR${NC}"
echo ""

# Step 5: Create systemd service
echo -e "${YELLOW}Step 5: Creating systemd service...${NC}"
cat > /etc/systemd/system/minio.service <<EOF
[Unit]
Description=MinIO Object Storage
Documentation=https://docs.min.io
After=network.target

[Service]
Type=notify
User=$MINIO_USER
Group=$MINIO_GROUP
Environment="MINIO_ROOT_USER=$MINIO_ROOT_USER"
Environment="MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD"
ExecStart=/usr/local/bin/minio server $MINIO_DATA_DIR --console-address ":9001"
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo -e "${GREEN}✓ Systemd service created${NC}"
echo ""

# Step 6: Start MinIO
echo -e "${YELLOW}Step 6: Starting MinIO...${NC}"
systemctl enable minio
systemctl start minio
sleep 3

if systemctl is-active minio &>/dev/null; then
    echo -e "${GREEN}✓ MinIO started successfully${NC}"
else
    echo "ERROR: MinIO failed to start"
    echo "Check logs: journalctl -u minio -n 50"
    exit 1
fi
echo ""

# Step 7: Configure firewall
echo -e "${YELLOW}Step 7: Configuring firewall...${NC}"
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=9000/tcp
    firewall-cmd --permanent --add-port=9001/tcp
    firewall-cmd --reload
    echo -e "${GREEN}✓ Firewall configured${NC}"
elif command -v ufw &>/dev/null; then
    ufw allow 9000/tcp
    ufw allow 9001/tcp
    echo -e "${GREEN}✓ Firewall configured${NC}"
else
    echo "WARNING: No firewall detected, ensure ports 9000 and 9001 are open"
fi
echo ""

# Step 8: Create Harbor bucket
echo -e "${YELLOW}Step 8: Creating Harbor bucket...${NC}"
if [ -f /usr/local/bin/mc ]; then
    sleep 2
    mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD
    
    if mc ls local/harbor 2>/dev/null; then
        echo "Bucket 'harbor' already exists"
    else
        mc mb local/harbor
        echo -e "${GREEN}✓ Bucket 'harbor' created${NC}"
    fi
    
    # Create access key for Harbor
    echo ""
    echo -e "${YELLOW}Creating access credentials for Harbor...${NC}"
    mc admin user add local harbor-user HarborUser123!
    mc admin policy attach local readwrite --user harbor-user
    
    echo -e "${GREEN}✓ User 'harbor-user' created${NC}"
    echo ""
    echo "Access Key: harbor-user"
    echo "Secret Key: HarborUser123!"
    echo ""
    echo "IMPORTANT: Save these credentials for harbor.yml configuration"
else
    echo "WARNING: mc not available, create bucket manually"
fi
echo ""

# Summary
echo "======================================"
echo -e "${GREEN}MinIO Installation Complete!${NC}"
echo "======================================"
echo ""
echo "MinIO Server:"
echo "  API: http://$(hostname -I | awk '{print $1}'):9000"
echo "  Console: http://$(hostname -I | awk '{print $1}'):9001"
echo ""
echo "Root Credentials:"
echo "  Username: $MINIO_ROOT_USER"
echo "  Password: $MINIO_ROOT_PASSWORD"
echo ""
echo "Harbor User Credentials:"
echo "  Access Key: harbor-user"
echo "  Secret Key: HarborUser123!"
echo ""
echo "Next steps:"
echo "1. Configure harbor.yml with S3 settings:"
echo "   storage_service:"
echo "     s3:"
echo "       accesskey: harbor-user"
echo "       secretkey: HarborUser123!"
echo "       regionendpoint: http://$(hostname -I | awk '{print $1}'):9000"
echo "       bucket: harbor"
echo ""
echo "2. Restart Harbor to apply changes"
echo ""
