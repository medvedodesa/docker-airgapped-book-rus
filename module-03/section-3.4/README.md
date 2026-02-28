# Module 03, Section 3.4: Vulnerability Scanning

Scripts and configurations for Harbor vulnerability scanning in air-gapped environments.

## Files

### trivy-db-update.sh
Automated Trivy database update script:
- Verify database archive
- Backup current database
- Install new database
- Restart Harbor
- Verify update

### rescan-all-images.sh
Rescan all images after database update:
- Iterate through all projects
- Scan all repositories and artifacts
- Display progress and statistics
- Rate limiting to avoid overload

### gitlab-ci-scan.yml
GitLab CI/CD pipeline with vulnerability scanning:
- Build and push image to Harbor
- Wait for scan completion
- Check vulnerability thresholds
- Block deployment if vulnerabilities found
- Manual approval for production

### scan-policy-enforcer.sh
Enforce scan policies across all projects:
- Auto-scan on push
- Prevent vulnerable images
- Severity thresholds
- Dry-run mode for testing
- Bulk update all projects

## Quick Start

### 1. Update Trivy Database

**On external machine (with internet):**
```bash
# Install Trivy
wget https://github.com/aquasecurity/trivy/releases/download/v0.48.0/trivy_0.48.0_Linux-64bit.tar.gz
tar xzf trivy_0.48.0_Linux-64bit.tar.gz
sudo mv trivy /usr/local/bin/

# Download database
trivy image --download-db-only

# Create archive
cd ~/.cache/trivy/db
tar czf trivy-db-$(date +%Y%m%d).tar.gz trivy.db metadata.json
```

**In air-gap:**
```bash
# Transfer archive to air-gap
# Then update Harbor:
chmod +x trivy-db-update.sh
sudo ./trivy-db-update.sh trivy-db-20260215.tar.gz
```

### 2. Rescan All Images

After database update:
```bash
chmod +x rescan-all-images.sh

# Set credentials
export HARBOR_URL="https://harbor.company.local"
export HARBOR_USER="admin"
export HARBOR_PASS="your-password"

# Run rescan
./rescan-all-images.sh
```

### 3. Enforce Scan Policies

Apply policies to all projects:
```bash
chmod +x scan-policy-enforcer.sh

# Test first (dry-run)
./scan-policy-enforcer.sh --dry-run

# Apply changes
./scan-policy-enforcer.sh
```

### 4. CI/CD Integration

**For GitLab CI:**
```bash
# Copy template to your repository
cp gitlab-ci-scan.yml /path/to/your/repo/.gitlab-ci.yml

# Set CI/CD variables in GitLab:
# Settings → CI/CD → Variables
# HARBOR_USER: admin (or robot account)
# HARBOR_PASSWORD: ****** (protected, masked)
```

## Database Update Schedule

Recommended update frequency:

**Critical Infrastructure:**
- Weekly database updates
- Immediate rescan after update

**Normal Infrastructure:**
- Bi-weekly or monthly updates
- Scheduled rescan

**Development:**
- Monthly updates
- Rescan on-demand

## Automated Update Process

### Weekly Update (External Machine)

```bash
# Create script: /opt/scripts/trivy-db-export.sh
#!/bin/bash
DATE=$(date +%Y%m%d)
OUTPUT_DIR="/backup/trivy-db"

trivy image --download-db-only

mkdir -p $OUTPUT_DIR
cd ~/.cache/trivy/db
tar czf $OUTPUT_DIR/trivy-db-$DATE.tar.gz trivy.db metadata.json
sha256sum $OUTPUT_DIR/trivy-db-$DATE.tar.gz > $OUTPUT_DIR/trivy-db-$DATE.tar.gz.sha256

# Add to crontab:
# 0 2 * * 0 /opt/scripts/trivy-db-export.sh
```

### Transfer Process

```bash
# 1. Copy from external machine to USB
# 2. Verify checksum
sha256sum -c trivy-db-20260215.tar.gz.sha256

# 3. Update Harbor
sudo ./trivy-db-update.sh trivy-db-20260215.tar.gz

# 4. Rescan images
./rescan-all-images.sh
```

## Scan Policy Configuration

### Policy Levels

**Strict (Production):**
```bash
Auto scan: true
Prevent vulnerable: true
Severity: critical,high
```

**Moderate (Staging):**
```bash
Auto scan: true
Prevent vulnerable: true
Severity: critical
```

**Permissive (Development):**
```bash
Auto scan: true
Prevent vulnerable: false
Severity: (ignored)
```

### Applying Policies

**Via Web UI:**
```
Projects → [Project] → Configuration
- ☑ Automatically scan images on push
- ☑ Prevent vulnerable images from running
- Severity: critical,high
```

**Via Script:**
```bash
./scan-policy-enforcer.sh
```

## Troubleshooting

### Database Update Failed

```bash
# Check current database
cat /data/harbor/trivy-adapter/trivy/db/metadata.json

# Check permissions
ls -la /data/harbor/trivy-adapter/trivy/db/

# Fix permissions
sudo chown -R 10000:10000 /data/harbor/trivy-adapter/trivy/db/

# Check Trivy logs
docker logs trivy-adapter
```

### Scan Not Starting

```bash
# Check if auto-scan is enabled
# Web UI: Configuration → Interrogation Services

# Trigger manual scan
curl -X POST -u admin:password \
  "https://harbor.company.local/api/v2.0/projects/myproject/repositories/myrepo/artifacts/latest/scan"

# Check scan status
curl -u admin:password \
  "https://harbor.company.local/api/v2.0/projects/myproject/repositories/myrepo/artifacts/latest"
```

### Scan Stuck

```bash
# Restart trivy-adapter
cd /data/harbor
docker-compose restart trivy-adapter

# Clear stuck scans (if needed)
# This requires database access - contact Harbor support
```

### High Memory Usage

```bash
# Reduce concurrent scans
# Edit harbor.yml:
jobservice:
  max_job_workers: 5  # Reduce from 10

# Restart Harbor
docker-compose restart
```

## CI/CD Integration Examples

### Jenkins

```groovy
stage('Vulnerability Scan') {
    steps {
        script {
            sh '''
                # Wait for scan
                for i in {1..30}; do
                    STATUS=$(curl -s -u $HARBOR_CREDS \
                        "$HARBOR_URL/api/v2.0/projects/myproject/repositories/myapp/artifacts/$TAG" | \
                        jq -r '.scan_overview[].scan_status')
                    
                    if [ "$STATUS" == "Success" ]; then
                        break
                    fi
                    sleep 10
                done
                
                # Check results
                CRITICAL=$(curl -s -u $HARBOR_CREDS \
                    "$HARBOR_URL/api/v2.0/projects/myproject/repositories/myapp/artifacts/$TAG" | \
                    jq -r '.scan_overview[].summary.critical')
                
                if [ "$CRITICAL" -gt 0 ]; then
                    error "Critical vulnerabilities found"
                fi
            '''
        }
    }
}
```

### GitHub Actions

```yaml
- name: Scan Image
  run: |
    # Wait for scan
    for i in {1..30}; do
      STATUS=$(curl -s -u admin:${{ secrets.HARBOR_PASS }} \
        "$HARBOR_URL/api/v2.0/projects/myproject/repositories/myapp/artifacts/$TAG" | \
        jq -r '.scan_overview[].scan_status')
      
      if [ "$STATUS" == "Success" ]; then
        break
      fi
      sleep 10
    done
    
    # Check critical CVE
    CRITICAL=$(curl -s -u admin:${{ secrets.HARBOR_PASS }} \
      "$HARBOR_URL/api/v2.0/projects/myproject/repositories/myapp/artifacts/$TAG" | \
      jq -r '.scan_overview[].summary.critical')
    
    if [ "$CRITICAL" -gt 0 ]; then
      echo "::error::Critical vulnerabilities found"
      exit 1
    fi
```

## Best Practices

### Database Updates

1. **Test in staging first**
   - Update staging Harbor
   - Rescan staging images
   - Verify no issues
   - Then update production

2. **Backup before update**
   - Automatic backup in update script
   - Keep last 4 backups
   - Test restore procedure

3. **Schedule during maintenance window**
   - Low-traffic period
   - Avoid during deployments
   - Notify teams in advance

### Scan Policies

1. **Start permissive, tighten gradually**
   - Begin with warnings only
   - Monitor for false positives
   - Gradually enforce blocking

2. **Different policies per environment**
   - Production: strict
   - Staging: moderate
   - Development: permissive

3. **Use CVE allowlist carefully**
   - Document each exception
   - Set expiration dates
   - Review regularly

### CI/CD Integration

1. **Use robot accounts**
   - Not personal credentials
   - Limited permissions
   - Regular rotation

2. **Cache scan results**
   - Don't rescan unchanged images
   - Use image digest for cache key

3. **Fail fast**
   - Block early in pipeline
   - Clear error messages
   - Link to Harbor UI for details

## Monitoring

### Key Metrics

```bash
# Scan success rate
# Check in Web UI: Administration → Job Service Dashboard

# Database age
cat /data/harbor/trivy-adapter/trivy/db/metadata.json | jq -r '.UpdatedAt'

# Scan queue depth
# Check in Web UI: Administration → Interrogation Services
```

### Alerts

Set up monitoring for:
- Database older than 30 days
- Scan failures > 10%
- Scan queue depth > 100
- Trivy container restarts

## Support

- **Book**: Module 3, Section 3.4
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Trivy Docs**: https://aquasecurity.github.io/trivy/
- **Harbor Scanning**: https://goharbor.io/docs/latest/administration/vulnerability-scanning/

## License

MIT License - See repository root for details
