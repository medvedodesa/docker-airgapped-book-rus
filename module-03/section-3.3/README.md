# Module 03, Section 3.3: Core Configuration

Configuration files and scripts for Harbor production optimization.

## Files

### harbor-production.yml
Production-optimized Harbor configuration:
- External PostgreSQL and Redis
- S3 storage backend (MinIO)
- Air-gap specific settings
- Performance tuning
- Security hardening

### minio-setup.sh
Automated MinIO installation and configuration:
- Install MinIO binary
- Create systemd service
- Setup Harbor bucket
- Create access credentials
- Firewall configuration

### postgresql-tuning.conf
PostgreSQL optimization for Harbor:
- Connection pooling
- Memory settings
- Checkpoint tuning
- Logging configuration
- Replication settings (for HA)

### cert-renewal.sh
Automated TLS certificate renewal:
- Check certificate expiry
- Backup old certificate
- Install new certificate
- Restart Harbor
- Verify new certificate

## Quick Start

### 1. Production Configuration

```bash
# Copy production template
cp harbor-production.yml /path/to/harbor/harbor.yml

# Edit configuration
vim /path/to/harbor/harbor.yml

# Update these values:
# - hostname
# - passwords (admin, database, redis)
# - S3 credentials
# - certificate paths
```

### 2. Setup MinIO Storage

```bash
# Prerequisites: Download minio and mc binaries
# On external machine:
# wget https://dl.min.io/server/minio/release/linux-amd64/minio
# wget https://dl.min.io/client/mc/release/linux-amd64/mc

# Transfer to air-gap, then:
chmod +x minio-setup.sh
sudo ./minio-setup.sh

# Note the credentials displayed
# Update harbor.yml with S3 settings
```

### 3. Tune PostgreSQL

```bash
# On PostgreSQL server
sudo cp postgresql-tuning.conf /etc/postgresql/14/main/postgresql.conf

# Adjust parameters based on your RAM:
# - 8GB RAM:  shared_buffers=1GB, effective_cache_size=3GB
# - 16GB RAM: shared_buffers=2GB, effective_cache_size=6GB
# - 32GB RAM: shared_buffers=4GB, effective_cache_size=12GB

# Restart PostgreSQL
sudo systemctl restart postgresql
```

### 4. Certificate Renewal

```bash
# Check certificate expiry
openssl x509 -in /data/cert/harbor.cert.pem -noout -enddate

# Renew (30 days before expiry)
# First, generate new certificate from CA
# Then run renewal script:
chmod +x cert-renewal.sh
sudo ./cert-renewal.sh
```

## Configuration Tips

### Storage Backend Selection

**Filesystem (Single-Node):**
```yaml
# In harbor.yml - comment out storage_service section
# Images stored in /data/harbor/registry
```

**S3 (HA/Production):**
```yaml
storage_service:
  s3:
    accesskey: harbor-user
    secretkey: <password>
    regionendpoint: http://minio.company.local:9000
    bucket: harbor
```

### Database Connection Tuning

For high-load environments:
```yaml
external_database:
  harbor:
    max_idle_conns: 200
    max_open_conns: 2000
```

Calculate based on:
```
max_open_conns = (concurrent_operations × 3) × 1.2
```

### JobService Workers

Adjust based on deployment size:
```yaml
# Small (< 50 hosts)
jobservice:
  max_job_workers: 5

# Medium (50-200 hosts)
jobservice:
  max_job_workers: 10

# Large (> 200 hosts)
jobservice:
  max_job_workers: 20
```

## MinIO Administration

### Create Additional Buckets

```bash
mc alias set local http://minio.company.local:9000 admin <password>
mc mb local/backup
mc mb local/logs
```

### Monitor Storage Usage

```bash
mc admin info local
mc du local/harbor
```

### Backup MinIO Data

```bash
# Backup to external location
mc mirror local/harbor /backup/minio/harbor/
```

## PostgreSQL Monitoring

### Check Connections

```sql
SELECT count(*) FROM pg_stat_activity;
SELECT max_connections FROM pg_settings;
```

### Check Database Size

```sql
SELECT pg_database.datname, 
       pg_size_pretty(pg_database_size(pg_database.datname)) AS size
FROM pg_database
WHERE pg_database.datname = 'harbor';
```

### Check Slow Queries

```sql
SELECT query, mean_exec_time, calls
FROM pg_stat_statements
ORDER BY mean_exec_time DESC
LIMIT 10;
```

### Vacuum Status

```sql
SELECT schemaname, tablename, last_vacuum, last_autovacuum
FROM pg_stat_user_tables;
```

## Performance Optimization

### Database Optimization

```bash
# Analyze all tables
psql -U harbor -d harbor -c "ANALYZE;"

# Vacuum full (during maintenance window)
psql -U harbor -d harbor -c "VACUUM FULL;"

# Reindex (if needed)
psql -U harbor -d harbor -c "REINDEX DATABASE harbor;"
```

### Storage Optimization

```bash
# Check registry disk usage
du -sh /data/harbor/registry

# For S3: Monitor MinIO
mc admin prometheus metrics local

# Cleanup dangling layers (see Section 3.8.3)
```

### Network Optimization

```bash
# For S3: Use internal network
# regionendpoint: http://internal-minio.company.local:9000

# Enable compression in Nginx (already enabled by default)
```

## Security Hardening

### Change Default Passwords

```yaml
# In harbor.yml:
harbor_admin_password: <20+ chars>
database:
  password: <20+ chars>
external_redis:
  password: <20+ chars>
storage_service:
  s3:
    secretkey: <20+ chars>
```

### Restrict Network Access

```bash
# Firewall rules
sudo firewall-cmd --permanent --add-rich-rule='
  rule family="ipv4"
  source address="10.20.30.0/24"
  port port="443" protocol="tcp" accept'

sudo firewall-cmd --reload
```

### Enable Audit Logging

```yaml
# In harbor.yml:
log:
  level: info
  
# Monitor audit logs
tail -f /var/log/harbor/core.log | grep audit
```

## Troubleshooting

### MinIO Connection Issues

```bash
# Test MinIO connectivity
curl http://minio.company.local:9000/minio/health/live

# Check MinIO logs
journalctl -u minio -n 50

# Verify credentials
mc admin info local
```

### Database Connection Issues

```bash
# Test PostgreSQL connection
psql -h postgres.company.local -U harbor -d harbor

# Check connection count
psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# Check max_connections
psql -U postgres -c "SHOW max_connections;"
```

### Certificate Issues

```bash
# Verify certificate
openssl x509 -in /data/cert/harbor.cert.pem -noout -text

# Check certificate matches key
openssl x509 -noout -modulus -in cert.pem | openssl md5
openssl rsa -noout -modulus -in key.pem | openssl md5

# Test HTTPS
curl -v https://harbor.company.local
```

## Monitoring Checklist

Daily:
- [ ] Check Harbor Web UI accessibility
- [ ] Monitor disk usage (/data/harbor)
- [ ] Check error logs
- [ ] Verify backup completion

Weekly:
- [ ] Review audit logs
- [ ] Check PostgreSQL performance
- [ ] Monitor MinIO storage usage
- [ ] Review certificate expiry dates

Monthly:
- [ ] Database maintenance (VACUUM, ANALYZE)
- [ ] Review and archive old logs
- [ ] Update Trivy database (Section 3.4)
- [ ] Test disaster recovery procedures

## Next Steps

After core configuration:
1. Setup vulnerability scanning (Section 3.4)
2. Configure image signing (Section 3.5)
3. Setup RBAC and projects (Section 3.6)
4. Configure replication (Section 3.7)

## Support

- **Book**: Module 3, Section 3.3
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **MinIO Docs**: https://min.io/docs/
- **PostgreSQL Docs**: https://www.postgresql.org/docs/

## License

MIT License - See repository root for details
