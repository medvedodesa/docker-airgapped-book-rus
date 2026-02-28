# Module 02, Section 2.3: Docker Configuration Files

This directory contains Docker daemon.json configurations and validation tools for air-gapped environments.

## Configuration Files

### daemon.json.minimal
Basic configuration suitable for development and testing.

**Features:**
- systemd cgroup driver
- Basic log rotation (100m max, 3 files)
- overlay2 storage driver
- Internal DNS configuration

**Use case:** Development, staging, initial setup

### daemon.json.production
Production-ready configuration with optimizations.

**Features:**
- local log driver (optimized)
- Compressed logs (50m max, 5 files)
- overlay2 with kernel check override
- Live restore enabled
- Inter-container communication disabled
- Optimized concurrent downloads/uploads

**Use case:** Production environments

### daemon.json.high-security
Maximum security configuration.

**Features:**
- User namespaces enabled
- TLS with mutual authentication
- Strict ulimits
- All production features
- Authorization plugins support

**Use case:** High-security environments (finance, healthcare, defense)

**⚠️ WARNING:** User namespaces is a breaking change - existing volumes may become inaccessible!

## Scripts

### validate-daemon-json.sh
Comprehensive validation of daemon.json before applying.

**Checks performed:**
1. JSON syntax validation
2. Critical parameters (cgroup driver, storage driver, log driver)
3. Common mistakes (trailing commas)
4. File permissions
5. Docker daemon validation (`dockerd --validate`)

**Usage:**
```bash
# Validate existing configuration
./validate-daemon-json.sh /etc/docker/daemon.json

# Validate new configuration before applying
./validate-daemon-json.sh daemon.json.production
```

### apply-daemon-config.sh
Safely apply daemon.json configuration with automatic backup and rollback.

**Features:**
- Validates new configuration
- Creates timestamped backup
- Shows configuration diff
- Requires confirmation
- Automatic rollback on failure
- Verifies Docker starts successfully

**Usage:**
```bash
# Apply production configuration
sudo ./apply-daemon-config.sh daemon.json.production

# Apply high-security configuration
sudo ./apply-daemon-config.sh daemon.json.high-security
```

## Quick Start

### 1. Validate Current Configuration

```bash
# Check if current daemon.json is valid
./validate-daemon-json.sh /etc/docker/daemon.json
```

### 2. Choose Configuration

**For most users:**
```bash
sudo ./apply-daemon-config.sh daemon.json.production
```

**For high-security requirements:**
```bash
sudo ./apply-daemon-config.sh daemon.json.high-security
```

**For development:**
```bash
sudo ./apply-daemon-config.sh daemon.json.minimal
```

### 3. Verify Applied Configuration

```bash
# Check Docker info
docker info

# Verify specific settings
docker info | grep -E "Cgroup Driver|Storage Driver|Logging Driver"

# Check logs for errors
sudo journalctl -u docker -n 50
```

## Manual Configuration

If you prefer to manually configure daemon.json:

### 1. Backup Existing Configuration

```bash
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup
```

### 2. Edit Configuration

```bash
sudo vim /etc/docker/daemon.json
```

### 3. Validate JSON

```bash
# Using jq
cat /etc/docker/daemon.json | jq .

# Or using python
python3 -m json.tool /etc/docker/daemon.json
```

### 4. Apply Changes

```bash
sudo systemctl daemon-reload
sudo systemctl restart docker
sudo systemctl status docker
```

## Configuration Parameters Explained

### Critical Parameters

**exec-opts (cgroup driver):**
```json
"exec-opts": ["native.cgroupdriver=systemd"]
```
- Required for Kubernetes compatibility
- systemd recommended for modern systems

**storage-driver:**
```json
"storage-driver": "overlay2"
```
- overlay2 is the most performant
- Requires kernel >= 4.0 and ext4/xfs filesystem

**log-driver:**
```json
"log-driver": "local"
```
- local: Best performance, compression support
- json-file: Default, good for most cases
- journald: Integration with systemd

### Security Parameters

**icc (Inter-Container Communication):**
```json
"icc": false
```
- false: Containers cannot communicate without explicit network
- Recommended for security

**userns-remap:**
```json
"userns-remap": "default"
```
- Maps container root to unprivileged user on host
- **Breaking change** - only enable on new installations

**TLS:**
```json
"tls": true,
"tlsverify": true,
"tlscacert": "/etc/docker/ca.pem",
"tlscert": "/etc/docker/server-cert.pem",
"tlskey": "/etc/docker/server-key.pem"
```
- Enables TLS for Docker daemon API
- Required for remote access

### Performance Parameters

**live-restore:**
```json
"live-restore": true
```
- Containers continue running during daemon restarts
- Critical for production

**userland-proxy:**
```json
"userland-proxy": false
```
- Uses iptables directly instead of proxy
- Better performance

**max-concurrent-downloads/uploads:**
```json
"max-concurrent-downloads": 3,
"max-concurrent-uploads": 5
```
- Limits parallel operations
- Tune based on network bandwidth

## Air-Gap Specific Configuration

### DNS Settings

**Always specify internal DNS:**
```json
"dns": ["10.20.30.10", "10.20.30.11"],
"dns-search": ["company.local"]
```

**Do NOT use:**
- 8.8.8.8 (Google DNS - not accessible)
- 1.1.1.1 (Cloudflare DNS - not accessible)

### Registry Configuration

**Never use insecure registries in production:**
```json
"insecure-registries": []
```

**Always use HTTPS:**
- Configure Harbor with valid TLS certificate
- Use internal CA
- Distribute CA certificate to all Docker hosts

### Data Root

**Consider separate partition:**
```json
"data-root": "/mnt/docker-data"
```

**Migration steps:**
1. Stop Docker
2. Copy /var/lib/docker to new location
3. Update daemon.json
4. Restart Docker

## Troubleshooting

### Docker Won't Start After Configuration Change

**Check logs:**
```bash
sudo journalctl -u docker -n 100
```

**Common issues:**
- Invalid JSON syntax (trailing commas, missing quotes)
- Invalid parameter values
- Missing required files (TLS certificates)

**Fix:**
```bash
# Restore backup
sudo cp /etc/docker/daemon.json.backup /etc/docker/daemon.json
sudo systemctl daemon-reload
sudo systemctl restart docker
```

### Cgroup Driver Mismatch

**Symptom:** Docker starts but containers fail

**Check:**
```bash
docker info | grep "Cgroup Driver"
```

**Fix:**
Ensure daemon.json has:
```json
"exec-opts": ["native.cgroupdriver=systemd"]
```

### Storage Driver Issues

**Symptom:** Images won't pull or build

**Check:**
```bash
docker info | grep "Storage Driver"
df -h /var/lib/docker
```

**Common causes:**
- Wrong filesystem (overlay2 needs ext4/xfs)
- Disk full
- Permissions issues

### Log Files Filling Disk

**Symptom:** /var partition full

**Check:**
```bash
du -sh /var/lib/docker/containers/*/
```

**Fix:** Enable log rotation:
```json
"log-opts": {
  "max-size": "50m",
  "max-file": "3"
}
```

## Best Practices

1. **Always validate before applying** - Use validate-daemon-json.sh
2. **Create backups** - Timestamp all backups
3. **Test in staging first** - Never test in production
4. **Monitor after changes** - Watch logs for 24 hours
5. **Document changes** - Keep change log
6. **Use version control** - Track daemon.json in Git

## Support

- **Book**: Module 2, Section 2.3
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Issues**: Report bugs via GitHub Issues

## License

MIT License - See repository root for details
