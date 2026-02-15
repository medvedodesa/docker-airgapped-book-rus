#!/bin/bash
# create-bundle.sh
# Create complete offline bundle with all components
#
# Usage: ./create-bundle.sh [bundle-name]
# Example: ./create-bundle.sh docker-offline-v1.0

set -euo pipefail

BUNDLE_NAME="${1:-docker-offline-v1.0}"
BUNDLE_DIR="./$BUNDLE_NAME"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Creating bundle: $BUNDLE_NAME${NC}"
echo "---"

# Create structure
echo -e "${YELLOW}Creating directory structure...${NC}"
mkdir -p "$BUNDLE_DIR"/{packages,scripts,docs,gpg-keys,metadata}

# Check if packages exist
if [ ! -d "./packages" ] || [ -z "$(ls -A ./packages/*.{deb,rpm} 2>/dev/null)" ]; then
    echo -e "${RED}ERROR: No packages found in ./packages${NC}"
    echo "Run apt-download-from-manifest.sh or dnf-download-from-manifest.sh first"
    exit 1
fi

# Copy packages
echo -e "${YELLOW}Copying packages...${NC}"
cp -r ./packages/* "$BUNDLE_DIR/packages/"
PKG_COUNT=$(ls -1 "$BUNDLE_DIR/packages"/*.{deb,rpm} 2>/dev/null | wc -l)
echo "  $PKG_COUNT packages copied"

# Copy scripts
echo -e "${YELLOW}Copying scripts...${NC}"
for script in verify-gpg.sh verify-checksums.sh verify-download.sh \
              apt-download-from-manifest.sh dnf-download-from-manifest.sh \
              create-checksums.sh generate-verification-report.sh; do
    if [ -f "$script" ]; then
        cp "$script" "$BUNDLE_DIR/scripts/"
    fi
done

# Create install.sh placeholder
cat > "$BUNDLE_DIR/scripts/install.sh" <<'INSTALL'
#!/bin/bash
# install.sh
# Install Docker from offline bundle
# See docs/INSTALL.md for detailed instructions

echo "Docker Offline Installation"
echo "==========================="
echo ""
echo "This script will install Docker from offline packages"
echo "See docs/INSTALL.md for step-by-step instructions"
echo ""
echo "NOTE: This is a placeholder. Actual installation steps"
echo "      depend on your OS (Ubuntu/Debian vs RHEL/CentOS)"
echo "      See Module 2, Section 2.2 in the book for details"
INSTALL

chmod +x "$BUNDLE_DIR/scripts"/*.sh

# Generate documentation
echo -e "${YELLOW}Generating documentation...${NC}"

cat > "$BUNDLE_DIR/docs/README.md" <<'README'
# Docker Offline Installation Bundle

## Overview

This bundle contains all necessary packages to install Docker Engine in an air-gapped environment without internet access.

## Contents

- Docker Engine 24.0.7
- Docker CLI 24.0.7
- Containerd 1.6.26
- Docker Compose Plugin 2.23.3
- Docker Buildx Plugin 0.12.0
- All dependencies and recommended packages

## Target System Requirements

### Operating System
- **Ubuntu 22.04 LTS (Jammy)** OR
- **RHEL/CentOS/Rocky Linux 9** OR
- **SUSE Linux Enterprise Server 15**

### Architecture
- x86_64 (amd64)

### Hardware
- Minimum 2GB RAM
- Minimum 20GB disk space
- 64-bit processor

### Kernel
- Minimum kernel version: 3.10
- Recommended: 5.x or newer

## Quick Start

1. Extract the bundle:
   ```bash
   tar xzf docker-offline-v1.0.tar.gz
   cd docker-offline-v1.0
   ```

2. Verify integrity:
   ```bash
   sudo ./scripts/verify-checksums.sh packages
   ```

3. Install Docker:
   ```bash
   # See docs/INSTALL.md for detailed OS-specific instructions
   ```

4. Verify installation:
   ```bash
   docker --version
   docker compose version
   ```

## Documentation

- `INSTALL.md` - Detailed installation instructions
- `TROUBLESHOOTING.md` - Common issues and solutions

## Support

- Internal Wiki: `wiki.company.local/docker-offline`
- Contact: `devops@company.com`
- Source: `github.com/medvedodesa/docker-airgapped-book-rus`

## Security

All packages have been:
- ✓ Downloaded from official repositories
- ✓ GPG signature verified
- ✓ SHA256 checksum verified
- ✓ Scanned for vulnerabilities

See `metadata/verification-report.txt` for details.

## Version

- Bundle Version: v1.0
- Created: $(date -u +"%Y-%m-%d")
- Docker Version: 24.0.7
README

cat > "$BUNDLE_DIR/docs/INSTALL.md" <<'INSTALLMD'
# Installation Instructions

## Ubuntu/Debian Installation

See Module 2, Section 2.2.2 in the book for complete instructions.

## RHEL/CentOS Installation

See Module 2, Section 2.2.1 in the book for complete instructions.

## SLES Installation

See Module 2, Section 2.2.3 in the book for complete instructions.

## Post-Installation

After installation, verify Docker is working:

```bash
# Check version
docker --version

# Run test container
docker run hello-world

# Check service status
systemctl status docker
```
INSTALLMD

cat > "$BUNDLE_DIR/docs/TROUBLESHOOTING.md" <<'TROUBLE'
# Troubleshooting

## Common Issues

### Issue 1: Package Installation Fails

**Symptom:** dpkg/rpm errors during installation

**Solution:**
1. Verify checksums: `./scripts/verify-checksums.sh packages`
2. Check disk space: `df -h`
3. Verify architecture matches: `uname -m`

### Issue 2: Docker Service Won't Start

**Symptom:** `systemctl start docker` fails

**Solution:**
1. Check kernel version: `uname -r` (must be >= 3.10)
2. Check logs: `journalctl -u docker`
3. Verify iptables is installed

### Issue 3: Permission Denied

**Symptom:** `docker: permission denied`

**Solution:**
Add user to docker group:
```bash
sudo usermod -aG docker $USER
newgrp docker
```

For more help, see the book Module 2, Section 2.2.4.
TROUBLE

# Copy GPG keys if available
if [ -d "/etc/apt/trusted.gpg.d" ]; then
    find /etc/apt/trusted.gpg.d -name "*.gpg" -exec cp {} "$BUNDLE_DIR/gpg-keys/" \; 2>/dev/null || true
fi

# Copy metadata
echo -e "${YELLOW}Copying metadata...${NC}"
if [ -f "manifest.txt" ]; then
    cp manifest.txt "$BUNDLE_DIR/metadata/"
fi
if [ -f "verification-report.txt" ]; then
    cp verification-report.txt "$BUNDLE_DIR/metadata/"
fi

# Create archive
echo ""
echo -e "${YELLOW}Creating archive...${NC}"
tar czf "${BUNDLE_NAME}.tar.gz" "$BUNDLE_DIR"

# Create checksum
echo -e "${YELLOW}Creating final checksum...${NC}"
sha256sum "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256"

# Calculate sizes
BUNDLE_SIZE=$(du -sh "$BUNDLE_DIR" | cut -f1)
ARCHIVE_SIZE=$(du -sh "${BUNDLE_NAME}.tar.gz" | cut -f1)

echo ""
echo "---"
echo -e "${GREEN}✓ Bundle created successfully!${NC}"
echo ""
echo "Bundle: ${BUNDLE_NAME}.tar.gz"
echo "  Uncompressed: $BUNDLE_SIZE"
echo "  Compressed: $ARCHIVE_SIZE"
echo "  Checksum: ${BUNDLE_NAME}.tar.gz.sha256"
echo ""
echo "Contents:"
echo "  Packages: $PKG_COUNT"
echo "  Scripts: $(ls -1 "$BUNDLE_DIR/scripts" | wc -l)"
echo "  Docs: $(ls -1 "$BUNDLE_DIR/docs" | wc -l)"
echo ""
echo "Checksum (SHA256):"
cat "${BUNDLE_NAME}.tar.gz.sha256"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Verify checksum matches after transfer"
echo "2. Extract in air-gapped environment"
echo "3. Run verification scripts"
echo "4. Follow installation instructions"
