# Module 04, Section 4.1: Docker Security Fundamentals

Security fundamentals and threat modeling for Docker in air-gapped environments.

## Files

### threat-model-template.md
Comprehensive threat modeling template:
- Asset inventory
- Threat actor profiles
- Attack vectors analysis
- Attack trees
- Threat scenarios
- Risk register
- Security controls mapping
- Mitigation priorities

### attack-surface-audit.sh
Automated attack surface scanner:
- Docker socket exposure check
- Privileged container detection
- Dangerous capabilities audit
- Volume mount analysis
- Root user detection
- Resource limits check
- Network configuration review
- Automated reporting

### risk-assessment.csv
Risk assessment spreadsheet:
- 15 pre-populated threats
- Likelihood and impact scoring
- Risk prioritization
- Mitigation tracking
- Status monitoring
- Quarterly review schedule

### security-checklist.md
Comprehensive security checklist:
- Critical must-haves
- High priority items
- Medium priority items
- Operational tasks (daily/weekly/monthly)
- Pre-deployment checklist
- Configuration templates
- Incident response guide

## Quick Start

### Run Attack Surface Audit

```bash
chmod +x attack-surface-audit.sh

# Run audit
sudo ./attack-surface-audit.sh

# Output saved to /tmp/docker-attack-surface-TIMESTAMP.txt
```

### Create Threat Model

```bash
# Copy template
cp threat-model-template.md my-threat-model.md

# Fill in your environment details
vim my-threat-model.md

# Sections to complete:
# 1. System Overview
# 2. Asset Inventory
# 3. Threat Actors (customize)
# 4. Attack Vectors
# 5. Attack Trees
# 6. Threat Scenarios
# 7. Risk Register
# 8. Security Controls
# 9. Mitigation Priorities
```

### Use Risk Assessment

```bash
# Import into spreadsheet
# Excel: Data → From Text/CSV → risk-assessment.csv
# Google Sheets: File → Import → Upload → risk-assessment.csv

# Customize threats for your environment
# Update likelihood/impact scores
# Track mitigation progress
# Review quarterly
```

### Apply Security Checklist

```bash
# Review critical items first
grep "🔴 CRITICAL" security-checklist.md -A 20

# Use as audit tool
# Check off completed items
# Track progress over time
```

## Threat Model Process

### Step 1: Asset Identification

Identify critical assets:
- Docker images
- Application data
- Secrets (keys, passwords)
- Infrastructure
- Audit logs

### Step 2: Threat Actor Analysis

Primary threats in air-gap:
- **Malicious insider** (HIGH)
- **Compromised account** (MEDIUM)
- **Negligent user** (HIGH)
- **Physical access** (LOW-MEDIUM)

### Step 3: Attack Vector Mapping

Key vectors:
- USB/removable media
- Insider access abuse
- Physical access
- Social engineering
- Misconfiguration

### Step 4: Risk Scoring

```
Risk = Likelihood × Impact

Likelihood: 1=Low, 2=Medium, 3=High
Impact: 1=Low, 2=Medium, 3=High, 4=Critical

Risk Levels:
- 1-2: Low (Accept)
- 3-4: Medium (Monitor)
- 6-8: High (Mitigate within 90 days)
- 9-12: Critical (Immediate action)
```

### Step 5: Mitigation Planning

Prioritize by risk score:
- **P0 (Critical):** Score 9-12
- **P1 (High):** Score 6-8
- **P2 (Medium):** Score 3-4
- **P3 (Low):** Score 1-2

## Attack Surface Analysis

### Critical Attack Surfaces

**1. Docker Socket**
```bash
# Check socket permissions
ls -l /var/run/docker.sock

# Should be: srw-rw---- docker docker

# Check for mounted sockets
docker ps --format '{{.Names}}' | xargs -I {} docker inspect {} | grep docker.sock
```

**2. Privileged Containers**
```bash
# List privileged containers
docker ps -q | xargs docker inspect --format '{{.Name}}: {{.HostConfig.Privileged}}'
```

**3. Dangerous Capabilities**
```bash
# Check capabilities
docker ps -q | xargs docker inspect --format '{{.Name}}: {{.HostConfig.CapAdd}}'
```

**4. Volume Mounts**
```bash
# List all mounts
docker ps -q | xargs docker inspect --format '{{.Name}}: {{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}'
```

## Security Principles

### 1. Least Privilege

**Container Level:**
```bash
# Drop all capabilities, add only needed
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE nginx
```

**User Level:**
```dockerfile
USER 1000:1000
```

### 2. Defense in Depth

Multiple security layers:
1. Application security
2. Container security
3. Runtime security
4. Docker daemon security
5. Host security
6. Network security
7. Physical security

### 3. Fail Securely

Failures default to secure state:
- Auth failure → Deny
- Cert error → Reject
- Scan failure → Block deployment

### 4. Zero Trust

Never trust, always verify:
- Mutual TLS for all communication
- Continuous authentication
- Image signature verification

### 5. Audit Everything

Log all security events:
- Container lifecycle
- Docker API calls
- System changes
- Access attempts

## Risk Assessment

### Common Air-Gap Threats

| Threat | Likelihood | Impact | Risk | Priority |
|--------|-----------|--------|------|----------|
| Malicious image via USB | High (3) | Critical (4) | 12 | P0 |
| Insider with root | Medium (2) | Critical (4) | 8 | P1 |
| Container escape | Low (1) | Critical (4) | 4 | P2 |
| Resource exhaustion | Medium (2) | High (3) | 6 | P1 |
| Config drift | High (3) | Medium (2) | 6 | P1 |

### Mitigation Examples

**Malicious Image (Risk: 12)**
- Implement Trivy scanning
- Enforce Notary signing
- USB port control
- Approved base images only
- **Residual Risk:** 4

**Container Escape (Risk: 4)**
- Kernel hardening
- Seccomp profiles
- Runtime monitoring (Falco)
- Regular patching
- **Residual Risk:** 2

## Best Practices

### Image Security

1. **Scan all images**
   ```bash
   trivy image --severity CRITICAL,HIGH myimage:tag
   ```

2. **Sign images**
   ```bash
   docker trust sign myimage:tag
   ```

3. **Use minimal bases**
   - Alpine (5 MB)
   - Distroless (20 MB)
   - Avoid full OS (300+ MB)

### Runtime Security

1. **Non-root user**
   ```dockerfile
   USER appuser
   ```

2. **Read-only filesystem**
   ```bash
   docker run --read-only --tmpfs /tmp myimage
   ```

3. **Resource limits**
   ```bash
   docker run --memory=512m --cpus=0.5 myimage
   ```

### Access Control

1. **RBAC everywhere**
   - Harbor projects
   - Docker daemon (authz plugin)
   - Host access

2. **MFA required**
   - SSH
   - Harbor login
   - Sudo/su

3. **Regular audits**
   - Weekly access review
   - Quarterly full audit
   - Annual penetration test

## Automation

### Daily Security Scan

```bash
#!/bin/bash
# /etc/cron.daily/docker-security-scan

# Run attack surface audit
/opt/scripts/attack-surface-audit.sh

# Scan all running images
docker images -q | xargs -I {} trivy image --severity HIGH,CRITICAL {}

# Check for privileged containers
PRIV_COUNT=$(docker ps -q | xargs docker inspect --format '{{.HostConfig.Privileged}}' | grep -c true)

if [ "$PRIV_COUNT" -gt 0 ]; then
    echo "WARNING: $PRIV_COUNT privileged containers found" | mail -s "Docker Security Alert" security@company.com
fi
```

### Weekly Risk Review

```bash
# Update risk assessment
# Review new vulnerabilities
# Check mitigation progress
# Update threat model if needed
```

## Incident Response

### If Container Compromised

1. **Isolate**
   ```bash
   docker network disconnect <network> <container>
   ```

2. **Capture Evidence**
   ```bash
   docker logs <container> > evidence-logs.txt
   docker inspect <container> > evidence-inspect.json
   ```

3. **Investigate**
   - Review audit logs
   - Check for unauthorized access
   - Identify compromised secrets

4. **Eradicate**
   ```bash
   docker rm -f <container>
   docker rmi <image>
   ```

5. **Recover**
   - Deploy clean image
   - Rotate secrets
   - Update firewall rules

6. **Document**
   - Post-mortem report
   - Lessons learned
   - Prevention measures

## Compliance

### Audit Evidence

Maintain evidence for compliance:
- Threat model (annual review)
- Risk assessment (quarterly update)
- Security audit logs (90+ days retention)
- Vulnerability scan reports
- Access reviews
- Incident response records

### Regulatory Requirements

**PCI DSS:**
- Section 6.2: Security patches
- Section 8.2: MFA
- Section 10: Audit logging

**SOC 2:**
- CC6.1: Logical access controls
- CC6.6: Vulnerability management
- CC7.2: System monitoring

**NIST 800-190:**
- Container image security
- Registry security
- Runtime protection
- Host OS security

## Next Steps

After completing section 4.1:
1. Create your threat model
2. Run attack surface audit
3. Populate risk assessment
4. Complete security checklist
5. Plan mitigations for critical risks
6. Review Section 4.2: CIS Docker Benchmark

## Support

- **Book**: Module 4, Section 4.1
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **NIST 800-190**: https://csrc.nist.gov/publications/detail/sp/800-190/final

## License

MIT License - See repository root for details
