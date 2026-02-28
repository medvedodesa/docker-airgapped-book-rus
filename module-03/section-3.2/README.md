# Module 03, Section 3.2: Offline Installation

Configuration files and scripts for Harbor offline installation in air-gapped environments.

## Files

### harbor.yml.example
Complete Harbor configuration for single-node deployment:
- Basic configuration parameters
- Air-gap specific settings
- TLS/HTTPS setup
- Trivy offline configuration
- Optional LDAP/OIDC integration
- Commented examples for all features

### harbor-ha.yml.example
Harbor configuration for High Availability deployment:
- Multiple Harbor nodes
- External PostgreSQL cluster
- External Redis Sentinel
- Shared S3 storage
- Load balancer integration

### post-install-verify.sh
Comprehensive verification script (10 checks):
1. DNS resolution
2. HTTPS access
3. API health
4. Docker containers status
5. Docker login test
6. Image push/pull test
7. PostgreSQL connectivity
8. Redis connectivity
9. Storage check
10. Log error check

## Quick Start

### Single-Node Installation

```bash
# 1. Extract Harbor offline installer
tar xzf harbor-offline-installer-v2.10.0.tgz
cd harbor

# 2. Copy example configuration
cp ../harbor.yml.example harbor.yml

# 3. Edit configuration
vim harbor.yml
# Update:
#  - hostname: harbor.company.local
#  - certificate paths
#  - passwords

# 4. Install Harbor
sudo ./install.sh --with-notary --with-trivy

# 5. Verify installation
cd ..
chmod +x post-install-verify.sh
./post-install-verify.sh harbor.company.local
```

### HA Installation

```bash
# Prerequisites:
# - PostgreSQL HA cluster running
# - Redis Sentinel running
# - S3-compatible storage (MinIO)
# - Load balancer configured

# On each Harbor node (node1, node2, node3):

# 1. Extract installer
tar xzf harbor-offline-installer-v2.10.0.tgz
cd harbor

# 2. Copy HA configuration
cp ../harbor-ha.yml.example harbor.yml

# 3. Edit configuration (SAME on all nodes)
vim harbor.yml
# Update:
#  - hostname: harbor.company.local (virtual)
#  - external_database settings
#  - external_redis settings
#  - storage_service.s3 settings

# 4. Install on each node
sudo ./install.sh --with-notary --with-trivy

# 5. Verify HA setup
# - Test LB: curl https://harbor.company.local
# - Test failover: stop node1, verify still accessible
# - Test database: verify all nodes use same PostgreSQL
# - Test storage: push via node1, pull via node2
```

## Configuration Tips

### Minimum Configuration (Air-Gap)

```yaml
hostname: harbor.company.local
https:
  certificate: /data/cert/harbor.cert.pem
  private_key: /data/cert/harbor.key.pem
harbor_admin_password: <strong-password>
data_volume: /data/harbor
trivy:
  skip_update: true
  offline_scan: true
```

### Production Configuration Checklist

- [ ] Strong admin password (20+ characters)
- [ ] Valid TLS certificates from internal CA
- [ ] Trivy skip_update: true (air-gap)
- [ ] Trivy offline_scan: true
- [ ] Sufficient disk space (200GB+)
- [ ] Log rotation configured
- [ ] (HA only) External database configured
- [ ] (HA only) External Redis configured
- [ ] (HA only) Shared storage configured

### Security Hardening

```yaml
# In harbor.yml:

# 1. Disable HTTP (HTTPS only)
# Comment out http section after testing

# 2. Strong database password
database:
  password: <min-20-chars-with-symbols>

# 3. Configure audit logging
log:
  level: info  # or debug for troubleshooting

# 4. Enable metrics for monitoring
metric:
  enabled: true
```

## Troubleshooting

### Issue: Cannot access Web UI

```bash
# Check nginx container
docker logs nginx

# Check DNS
nslookup harbor.company.local

# Check certificate
openssl s_client -connect harbor.company.local:443

# Check firewall
sudo firewall-cmd --list-ports | grep 443
```

### Issue: Docker login fails

```bash
# Check certificate trust
sudo cp ca-chain.cert.pem /etc/docker/certs.d/harbor.company.local/ca.crt
sudo systemctl restart docker

# Try login with verbose
docker login harbor.company.local -u admin
```

### Issue: Containers keep restarting

```bash
# Check all containers
docker ps -a

# Check logs
docker-compose -f /data/harbor/docker-compose.yml logs

# Common causes:
# - Database connection failed
# - Insufficient disk space
# - Invalid configuration
# - Port conflicts
```

### Issue: Push/Pull fails

```bash
# Check disk space
df -h /data/harbor

# Check registry logs
docker logs registry

# Check RBAC permissions in Web UI
```

## Post-Installation Tasks

### 1. Change Admin Password

```bash
# Login to Web UI
https://harbor.company.local

# Go to: Admin → Users → admin → Edit
# Set new strong password
```

### 2. Create Projects

```bash
# Web UI: Projects → New Project
# Name: myproject
# Access Level: Private
# Storage Quota: 10 GB
```

### 3. Add Users

```bash
# Web UI: Admin → Users → New User
# Or configure LDAP/OIDC
```

### 4. Test Image Operations

```bash
# Create robot account
# Web UI: Project → Robot Accounts → New

# Test push
docker login harbor.company.local
docker pull alpine:3.18
docker tag alpine:3.18 harbor.company.local/myproject/alpine:3.18
docker push harbor.company.local/myproject/alpine:3.18

# Test scan
# Web UI: Project → Repository → Tag → SCAN
```

## Backup Recommendations

### What to Backup

```bash
# 1. Database (daily)
docker exec harbor-db pg_dump -U postgres harbor > harbor-db-backup.sql

# 2. Configuration (after changes)
tar czf harbor-config-backup.tar.gz /data/harbor/harbor.yml

# 3. Registry data (weekly)
# For single-node:
tar czf registry-backup.tar.gz /data/harbor/registry/

# For HA (S3):
# Use S3 backup tools (aws s3 sync, rclone, etc.)
```

### Restore Procedure

```bash
# 1. Stop Harbor
cd /data/harbor
docker-compose down

# 2. Restore database
cat harbor-db-backup.sql | docker exec -i harbor-db psql -U postgres harbor

# 3. Restore registry data
tar xzf registry-backup.tar.gz -C /data/harbor/

# 4. Start Harbor
docker-compose up -d
```

## Performance Tuning

### Database Connections

```yaml
# In harbor.yml for high load:
database:
  max_idle_conns: 100
  max_open_conns: 900

# Or for external PostgreSQL:
external_database:
  harbor:
    max_idle_conns: 200
    max_open_conns: 2000
```

### Job Workers

```yaml
# Increase for concurrent operations:
jobservice:
  max_job_workers: 20  # default: 10
```

### Redis Configuration

```bash
# For external Redis, configure in redis.conf:
maxmemory 2gb
maxmemory-policy allkeys-lru
```

## Monitoring

### Health Checks

```bash
# API health endpoint
curl -k https://harbor.company.local/api/v2.0/health

# Metrics (Prometheus format)
curl -k https://harbor.company.local:9090/metrics
```

### Key Metrics to Monitor

- Storage usage: `/data/harbor/registry` size
- Database connections: PostgreSQL pg_stat_activity
- Container health: `docker ps` status
- API response time: `/api/v2.0/health` latency
- Push/pull operations: Harbor audit logs

## Next Steps

After successful installation:
1. Read Section 3.3: Core Configuration
2. Setup vulnerability scanning (Section 3.4)
3. Configure RBAC (Section 3.6)
4. Setup replication if multi-site (Section 3.7)

## Support

- **Book**: Module 3, Section 3.2
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Harbor Docs**: https://goharbor.io/docs/latest/install-config/
- **Harbor GitHub**: https://github.com/goharbor/harbor

## License

MIT License - See repository root for details
