# Module 02, Section 2.1: Offline Bundle Preparation Scripts

This directory contains production-ready scripts for creating Docker offline installation bundles.

## Quick Start

### For Ubuntu/Debian

1. Create manifest file (or use provided `manifest-ubuntu.txt`)
2. Download packages:
   ```bash
   sudo ./apt-download-from-manifest.sh manifest-ubuntu.txt
   ```
3. Verify download:
   ```bash
   ./verify-download.sh manifest-ubuntu.txt
   ```
4. Create checksums:
   ```bash
   ./create-checksums.sh ./packages
   ```
5. Verify checksums:
   ```bash
   ./verify-checksums.sh ./packages
   ```
6. Verify GPG signatures (optional):
   ```bash
   ./verify-gpg.sh ./packages
   ```
7. Generate report:
   ```bash
   ./generate-verification-report.sh ./packages
   ```
8. Create bundle:
   ```bash
   ./create-bundle.sh docker-offline-v1.0
   ```

### For RHEL/CentOS/Rocky

Same steps as above, but use:
- `dnf-download-from-manifest.sh` instead of `apt-download-from-manifest.sh`
- `manifest-rhel.txt` instead of `manifest-ubuntu.txt`

## Scripts Overview

| Script | Purpose | Usage |
|--------|---------|-------|
| `apt-download-from-manifest.sh` | Download .deb packages from manifest | `sudo ./apt-download-from-manifest.sh manifest.txt` |
| `dnf-download-from-manifest.sh` | Download .rpm packages from manifest | `sudo ./dnf-download-from-manifest.sh manifest.txt` |
| `verify-download.sh` | Verify all packages downloaded | `./verify-download.sh manifest.txt` |
| `verify-gpg.sh` | Verify GPG signatures | `./verify-gpg.sh ./packages` |
| `create-checksums.sh` | Create SHA256 checksums | `./create-checksums.sh ./packages` |
| `verify-checksums.sh` | Verify SHA256 checksums | `./verify-checksums.sh ./packages` |
| `generate-verification-report.sh` | Generate verification report | `./generate-verification-report.sh ./packages` |
| `create-bundle.sh` | Create final bundle archive | `./create-bundle.sh bundle-name` |

## Manifest Files

### manifest-ubuntu.txt
Example manifest for Ubuntu 22.04 LTS with Docker Engine 24.0.7

### manifest-rhel.txt
Example manifest for RHEL 9 / Rocky Linux 9 with Docker Engine 24.0.7

## Bundle Structure

After running `create-bundle.sh`, you'll get:

```
docker-offline-v1.0/
├── packages/
│   ├── *.deb or *.rpm files
│   ├── SHA256SUMS
│   └── SHA256SUMS.asc (if GPG signed)
├── scripts/
│   ├── All verification scripts
│   └── install.sh (placeholder)
├── docs/
│   ├── README.md
│   ├── INSTALL.md
│   └── TROUBLESHOOTING.md
├── gpg-keys/
│   └── *.gpg keys (if available)
└── metadata/
    ├── manifest.txt
    └── verification-report.txt
```

## Requirements

### On External Machine (with internet)

**Ubuntu/Debian:**
- `apt-get` (installed by default)
- `dpkg-sig` (optional, for GPG verification)
- `gpg` (optional, for signing)

**RHEL/CentOS/Rocky:**
- `dnf` or `yum`
- `rpm` (installed by default)
- `gpg` (optional, for signing)

### Common Tools
- `sha256sum` (installed by default)
- `tar` and `gzip`
- `bash` 4.0+

## Size Estimates

| Bundle Type | Compressed | Uncompressed |
|-------------|-----------|--------------|
| Docker packages only | ~350 MB | ~455 MB |
| + 10-15 base images | ~2.2 GB | ~2.5 GB |
| + 50 images (large) | ~15 GB | ~20 GB |

## Transfer Methods

| Size | Recommended Method |
|------|-------------------|
| < 5 GB | Encrypted USB drive |
| 5-50 GB | External HDD |
| > 50 GB | Multiple HDDs or NAS |

## Security Best Practices

1. **Always verify checksums** before and after transfer
2. **Sign bundles with GPG** when possible
3. **Use encrypted storage** for transfer (especially USB)
4. **Mount read-only** in air-gapped environment
5. **Keep verification reports** for audit trail

## Common Pitfalls

See [Module 2, Section 2.1](../../module_02_section_2.1.md) in the book for detailed troubleshooting:

- Architecture mismatch (amd64 vs arm64)
- OS version mismatch (Ubuntu 22.04 vs 20.04)
- Missing Recommends packages
- Corrupt downloads
- Missing GPG keys
- Insufficient disk space
- Kernel version too old

## Testing

Before transferring to production air-gapped environment:

1. Create a test VM without internet
2. Transfer bundle to test VM
3. Verify checksums
4. Extract and install
5. Run `docker run hello-world`

If step 5 succeeds, bundle is ready for production.

## Support

- **Book**: "Docker в закрытых контурах: Полный учебный курс"
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Issues**: Report bugs or suggestions via GitHub Issues

## License

MIT License - See repository root for details

## Author

From the book "Docker in Air-Gapped Environments: Complete Learning Path"  
Module 2: Offline Docker Installation  
Section 2.1: Offline Bundle Preparation
