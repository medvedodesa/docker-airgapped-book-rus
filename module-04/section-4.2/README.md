# Module 04, Section 4.2: CIS Docker Benchmark

Implementation guide for CIS Docker Benchmark v1.6.0 in air-gapped environments.

## Files

### docker-bench-setup.sh
Offline installer for Docker Bench Security:
- Install from local archive/directory
- Create wrapper command
- Setup automated weekly scans
- Configure systemd timer
- Initial scan execution

### cis-audit.sh
Automated compliance checker:
- Check 30+ CIS controls
- Generate PASS/FAIL/WARN results
- Calculate compliance score
- HTML report generation
- Optional auto-fix mode
- Exit code for CI/CD integration

### daemon-hardened.json
Production-ready daemon configuration:
- CIS-compliant settings
- Network security (ICC disabled)
- Logging configuration
- Resource management
- Security options
- Extensive inline documentation

### remediation-guide.md
Step-by-step fix instructions:
- All major CIS controls
- Copy-paste remediation commands
- Common issues and solutions
- Priority-based ordering
- Validation procedures
- Compliance tracking template

## Quick Start

### Install Docker Bench Security

```bash
# On external machine with internet:
git clone https://github.com/docker/docker-bench-security.git
cd docker-bench-security
tar czf ../docker-bench-security.tar.gz .

# Transfer to air-gap

# On air-gap system:
chmod +x docker-bench-setup.sh
sudo ./docker-bench-setup.sh

# Run scan
sudo docker-bench
```

### Run Compliance Audit

```bash
chmod +x cis-audit.sh

# Basic audit
sudo ./cis-audit.sh

# With HTML report
sudo ./cis-audit.sh --report compliance-report.html

# With auto-fix (use carefully!)
sudo ./cis-audit.sh --fix
```

### Apply Hardened Configuration

```bash
# Backup current config
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.backup

# Install hardened config
sudo cp daemon-hardened.json /etc/docker/daemon.json

# Validate JSON syntax
jq . /etc/docker/daemon.json

# Restart Docker
sudo systemctl restart docker

# Verify
docker info
docker ps  # Check containers still running
```

## CIS Benchmark Structure

### Section 1: Host Configuration (19 controls)
- Separate partition for Docker
- OS hardening
- Auditd configuration

### Section 2: Docker Daemon (18 controls)
- Network security
- Logging configuration
- TLS settings
- User namespaces

### Section 3: Docker Files (7 controls)
- File permissions
- Ownership settings
- Configuration security

### Section 4: Container Images (9 controls)
- Trusted base images
- Vulnerability scanning
- Content trust
- Minimal packages

### Section 5: Container Runtime (30+ controls)
- Non-root users
- Capabilities
- Resource limits
- AppArmor/SELinux
- Read-only filesystem

### Section 6: Security Operations (11 controls)
- Regular audits
- Monitoring
- Backups

## Critical Controls (Must Implement)

### Level 1 - Required for All

**Host:**
- 1.1.2: Harden container host
- 1.2.1: Audit Docker daemon

**Daemon:**
- 2.1: Restrict inter-container communication
- 2.2: Set logging level to info
- 2.4: No insecure registries
- 2.5: Enable live restore

**Files:**
- 3.2: docker.service permissions (644)
- 3.4: Docker socket permissions (660)

**Images:**
- 4.1: Non-root user in images
- 4.2: Use trusted base images
- 4.4: Scan for vulnerabilities

**Runtime:**
- 5.1: No privileged containers
- 5.3: Set resource limits
- 5.2: Run as non-root

### Level 2 - Enhanced Security

**Daemon:**
- 2.6: User namespace remapping

**Runtime:**
- 5.4: Read-only root filesystem
- 5.2: AppArmor/SELinux profiles

## Implementation Guide

### Step 1: Baseline Audit

```bash
# Run initial audit
sudo docker-bench > baseline-audit.log

# Or use custom script
sudo ./cis-audit.sh --report baseline.html

# Identify failures
grep FAIL baseline-audit.log
```

### Step 2: Prioritize Remediation

**P0 (Critical):**
- Remove privileged containers
- Fix socket permissions
- Remove insecure registries
- Enable auditd

**P1 (High):**
- Disable ICC
- Enable live restore
- Set resource limits
- Harden host OS

**P2 (Medium):**
- Separate partition
- Non-root containers
- Read-only filesystems

### Step 3: Apply Fixes

Use `remediation-guide.md` for step-by-step instructions:

```bash
# Example: Fix Docker socket permissions
sudo chmod 660 /var/run/docker.sock
sudo chown root:docker /var/run/docker.sock

# Example: Enable ICC restriction
sudo jq '. + {"icc": false}' /etc/docker/daemon.json > /tmp/daemon.json
sudo mv /tmp/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

### Step 4: Validate

```bash
# Re-run audit
sudo ./cis-audit.sh --report after-remediation.html

# Compare results
diff baseline-audit.log after-audit.log

# Track compliance score
grep "Compliance Score" after-audit.html
```

### Step 5: Continuous Monitoring

```bash
# Setup weekly automated scans
sudo systemctl enable docker-bench.timer
sudo systemctl start docker-bench.timer

# Or cron job
echo "0 2 * * 0 /usr/local/bin/docker-bench > /var/log/docker-bench-\$(date +\%Y\%m\%d).log" | sudo crontab -
```

## Common Configurations

### Minimal Hardening (Quick Start)

```json
{
  "icc": false,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "log-level": "info",
  "live-restore": true
}
```

### Production Hardening (Recommended)

```json
{
  "icc": false,
  "iptables": true,
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "log-level": "info",
  "live-restore": true,
  "storage-driver": "overlay2",
  "selinux-enabled": true,
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 64000,
      "Soft": 64000
    }
  }
}
```

### Maximum Security (Level 2)

Add to production config:

```json
{
  "userns-remap": "dockremap"
}
```

**Warning:** Test user namespace remapping thoroughly before production!

## Auditd Configuration

```bash
# Install auditd
sudo yum install -y audit

# Create Docker audit rules
sudo tee /etc/audit/rules.d/docker.rules << 'EOF'
-w /usr/bin/dockerd -k docker
-w /usr/bin/docker -k docker
-w /var/lib/docker -k docker
-w /etc/docker -k docker
-w /lib/systemd/system/docker.service -k docker
-w /var/run/docker.sock -k docker
EOF

# Load rules
sudo augenrules --load
sudo systemctl restart auditd

# Verify
sudo auditctl -l | grep docker

# View audit events
sudo ausearch -k docker -ts recent
```

## Container Security Examples

### Dockerfile Best Practices

```dockerfile
# Use specific version
FROM alpine:3.18

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser

# Install minimal packages
RUN apk add --no-cache python3 && \
    rm -rf /var/cache/apk/*

WORKDIR /app
COPY --chown=appuser:appuser app.py .

# Switch to non-root
USER appuser

# Health check
HEALTHCHECK --interval=30s CMD python3 -c "import requests; requests.get('http://localhost:8080/health')"

CMD ["python3", "app.py"]
```

### Secure docker-compose.yml

```yaml
version: '3.8'

services:
  app:
    image: myapp:1.0.0
    user: "1000:1000"
    read_only: true
    security_opt:
      - no-new-privileges:true
      - apparmor=docker-default
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    tmpfs:
      - /tmp:size=100M,mode=1777
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
    restart: unless-stopped
```

## Troubleshooting

### Audit Script Failures

```bash
# Permission denied
sudo ./cis-audit.sh

# Docker not accessible
sudo usermod -aG docker $USER
# Log out and back in

# JSON parsing errors
jq --version  # Ensure jq installed
```

### Daemon Configuration Issues

```bash
# Invalid JSON
jq . /etc/docker/daemon.json
# Fix syntax errors

# Docker won't start
journalctl -u docker -n 50
# Check for conflicting options

# Test configuration
dockerd --config-file /etc/docker/daemon.json --validate
```

### User Namespace Issues

```bash
# Volume permission errors after enabling userns-remap
sudo chown -R 100000:100000 /path/to/volume

# Container won't start
docker run --userns=host myimage  # Bypass userns for specific container
```

## Compliance Tracking

### Monthly Checklist

```bash
# Run audit
./cis-audit.sh --report monthly-$(date +%Y%m).html

# Review failures
grep FAIL monthly-audit.log

# Update tracking spreadsheet
# Track remediation progress
# Schedule fixes for failures
```

### Quarterly Review

- Full threat model update
- CIS Benchmark version check
- Policy review
- Team training
- Penetration testing

### Annual Audit

- Complete security assessment
- Third-party audit
- Compliance certification
- Update procedures

## Best Practices

### Do's

✅ Run audits weekly  
✅ Track remediation progress  
✅ Test in staging first  
✅ Document exceptions  
✅ Automate compliance checking  
✅ Review audit logs regularly  
✅ Keep Docker updated  

### Don'ts

❌ Skip Level 1 controls  
❌ Ignore FAIL findings  
❌ Apply fixes without testing  
❌ Run privileged containers  
❌ Disable security features  
❌ Use insecure registries  
❌ Expose Docker socket  

## Next Steps

After CIS compliance:
1. Review Section 4.3: Container Isolation
2. Implement runtime security (Section 4.4)
3. Apply kernel hardening (Section 4.5)
4. Regular compliance monitoring
5. Continuous improvement

## Support

- **Book**: Module 4, Section 4.2
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **CIS Benchmark**: https://www.cisecurity.org/benchmark/docker
- **Docker Bench**: https://github.com/docker/docker-bench-security

## License

MIT License - See repository root for details
