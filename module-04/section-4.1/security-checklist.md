# Docker Security Checklist
# Air-Gapped Environment

Comprehensive security checklist for Docker deployments in air-gapped environments.

---

## 🔴 CRITICAL (Must Have)

### Docker Daemon Security

- [ ] Docker daemon NOT exposed on network (no `-H tcp://0.0.0.0:2375`)
- [ ] Docker socket permissions set to 660 or 600
- [ ] Docker daemon runs as non-root user (rootless Docker) OR
- [ ] User namespace remapping enabled (`userns-remap`)
- [ ] TLS authentication configured if remote access needed
- [ ] Authorization plugin configured (OPA/custom)

### Container Configuration

- [ ] NO privileged containers in production
- [ ] NO containers with Docker socket mounted (`/var/run/docker.sock`)
- [ ] NO containers mounting root filesystem (`-v /:/host`)
- [ ] All containers run as non-root user (USER directive in Dockerfile)
- [ ] Resource limits configured (CPU, memory, PID)
- [ ] Security options configured (seccomp, AppArmor, or SELinux)

### Image Security

- [ ] All images scanned for vulnerabilities (Trivy/Clair)
- [ ] Critical/High vulnerabilities blocked from deployment
- [ ] Image signing enforced (Notary/Cosign)
- [ ] Only approved base images allowed
- [ ] Image provenance tracked (who built, when, where)
- [ ] No secrets in images (checked with automated tools)

### Access Control

- [ ] Multi-factor authentication (MFA) for all admin accounts
- [ ] Role-Based Access Control (RBAC) implemented
- [ ] Principle of least privilege applied
- [ ] Regular access reviews (quarterly minimum)
- [ ] Service accounts have minimal permissions
- [ ] Audit logging enabled for all privileged operations

---

## 🟠 HIGH PRIORITY (Should Have)

### Network Security

- [ ] Custom Docker networks (not default bridge)
- [ ] Network segmentation between environments
- [ ] Inter-container communication restricted
- [ ] No host network mode (`--net=host`) unless documented
- [ ] Firewall rules configured (iptables/firewalld)
- [ ] Network policies enforced (if using orchestrator)

### Runtime Security

- [ ] Read-only root filesystem where possible (`--read-only`)
- [ ] Temporary filesystems for writable dirs (`--tmpfs`)
- [ ] No new privileges flag set (`--security-opt=no-new-privileges`)
- [ ] Drop all capabilities, add only needed (`--cap-drop=ALL --cap-add=...`)
- [ ] Seccomp profile configured (default or custom)
- [ ] AppArmor/SELinux profiles applied

### Secrets Management

- [ ] Secrets NOT in environment variables
- [ ] Secrets NOT in images
- [ ] Secrets management solution (Vault/Docker Secrets)
- [ ] Secrets rotated regularly (90 days max)
- [ ] Secrets encrypted at rest
- [ ] Access to secrets logged and monitored

### Monitoring & Logging

- [ ] Container lifecycle events logged
- [ ] Runtime security monitoring (Falco/Sysdig)
- [ ] Centralized log aggregation
- [ ] Log retention policy (minimum 90 days)
- [ ] Logs encrypted at rest
- [ ] Anomaly detection configured
- [ ] Alerting for security events

### Host Security

- [ ] Host OS hardened (CIS benchmark)
- [ ] Kernel hardened (sysctl parameters)
- [ ] auditd configured for container events
- [ ] Unnecessary services disabled
- [ ] File integrity monitoring (AIDE/Tripwire)
- [ ] Anti-malware configured
- [ ] Regular security updates applied

---

## 🟡 MEDIUM PRIORITY (Nice to Have)

### Image Optimization

- [ ] Minimal base images (Alpine/Distroless)
- [ ] Multi-stage builds to reduce size
- [ ] Unused packages removed
- [ ] Image layers optimized
- [ ] Health checks configured
- [ ] Labels for metadata (version, maintainer, etc.)

### Compliance & Governance

- [ ] Configuration as code (Dockerfile, compose files in Git)
- [ ] Code review required for changes
- [ ] Automated compliance checking (Docker Bench Security)
- [ ] Policy as code (OPA for admission control)
- [ ] Compliance reports generated regularly
- [ ] Documentation maintained

### Backup & Recovery

- [ ] Regular backups of volumes
- [ ] Backup of container configurations
- [ ] Backup testing performed
- [ ] Disaster recovery plan documented
- [ ] Recovery time objective (RTO) defined
- [ ] Recovery point objective (RPO) defined

### Performance & Reliability

- [ ] Resource quotas configured
- [ ] Quality of Service (QoS) policies
- [ ] Health probes configured
- [ ] Restart policies appropriate
- [ ] Logging verbosity optimized
- [ ] Metrics collection (Prometheus)

---

## 🔵 OPERATIONAL (Day-to-Day)

### Regular Tasks

#### Daily
- [ ] Review security alerts
- [ ] Monitor resource usage
- [ ] Check for failed deployments
- [ ] Review access logs

#### Weekly
- [ ] Vulnerability scan all running images
- [ ] Review and address scan findings
- [ ] Check for configuration drift
- [ ] Review recent audit logs

#### Monthly
- [ ] Full security audit (run checklist)
- [ ] Access review (remove stale accounts)
- [ ] Update risk assessment
- [ ] Review and test backups
- [ ] Check certificate expiration dates

#### Quarterly
- [ ] Security training for team
- [ ] Disaster recovery drill
- [ ] Update security policies
- [ ] Third-party security assessment
- [ ] Penetration testing

#### Annually
- [ ] Complete threat model review
- [ ] Security architecture review
- [ ] Compliance audit (PCI DSS, SOC2, etc.)
- [ ] Budget review for security tools
- [ ] Update incident response plan

---

## 📋 Pre-Deployment Checklist

Use this before deploying any new container to production:

- [ ] Image scanned and no critical vulnerabilities
- [ ] Image signed by authorized party
- [ ] Dockerfile reviewed and approved
- [ ] Non-root user configured
- [ ] Resource limits defined
- [ ] Security context configured (seccomp, AppArmor, etc.)
- [ ] No privileged mode
- [ ] No Docker socket mount
- [ ] No dangerous capabilities
- [ ] Secrets externalized (not in image/env vars)
- [ ] Network policy defined
- [ ] Logging configured
- [ ] Health checks defined
- [ ] Backup strategy documented
- [ ] Rollback plan prepared
- [ ] Security review completed
- [ ] Change request approved

---

## 🔧 Configuration Templates

### Secure docker-compose.yml Template

```yaml
version: '3.8'

services:
  app:
    image: your-registry.local/app:1.0.0  # Specific tag, not 'latest'
    container_name: app
    
    # Security options
    security_opt:
      - no-new-privileges:true
      - apparmor=docker-default  # or custom profile
      - seccomp=/path/to/seccomp-profile.json
    
    # Run as non-root
    user: "1000:1000"
    
    # Read-only root filesystem
    read_only: true
    
    # Writable temporary filesystem
    tmpfs:
      - /tmp:size=100M,mode=1777
      - /var/run:size=10M,mode=755
    
    # Resource limits
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
    
    # Drop all capabilities, add only needed
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE  # Only if needed
    
    # Network
    networks:
      - app_network
    
    # Volumes (specific paths, not root)
    volumes:
      - app_data:/app/data:ro  # Read-only where possible
    
    # Environment (no secrets here!)
    environment:
      - APP_ENV=production
      - LOG_LEVEL=info
    
    # Secrets from external source
    secrets:
      - db_password
    
    # Health check
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    
    # Restart policy
    restart: unless-stopped
    
    # Logging
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  app_network:
    driver: bridge
    internal: true  # No external access

volumes:
  app_data:
    driver: local

secrets:
  db_password:
    external: true  # From Vault or Docker secrets
```

### Secure Dockerfile Template

```dockerfile
# Use specific version, not 'latest'
FROM alpine:3.18

# Metadata
LABEL maintainer="security@company.com"
LABEL version="1.0.0"
LABEL security.scan="trivy"

# Install only required packages
RUN apk add --no-cache \
    python3 \
    && rm -rf /var/cache/apk/*

# Create non-root user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser

# Set working directory
WORKDIR /app

# Copy application (as root initially for proper ownership)
COPY --chown=appuser:appuser app.py requirements.txt ./

# Install Python dependencies
RUN pip3 install --no-cache-dir -r requirements.txt

# Switch to non-root user
USER appuser

# No secrets in image!
# Secrets should come from environment or secrets manager

# Expose port (documentation only)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python3 -c "import requests; requests.get('http://localhost:8080/health')"

# Run application
CMD ["python3", "app.py"]
```

---

## 🎯 Severity Scoring Guide

When conducting audits, score findings:

### CRITICAL (Fix Immediately)
- Privileged containers in production
- Docker socket exposed
- Root filesystem mounted
- Docker daemon on network without auth
- Unpatched critical vulnerabilities (CVSS 9.0+)

### HIGH (Fix within 7 days)
- Containers running as root
- Dangerous capabilities granted
- Host network/PID namespace
- High severity vulnerabilities (CVSS 7.0-8.9)
- No resource limits

### MEDIUM (Fix within 30 days)
- Read-write root filesystem
- Using 'latest' tag
- No health checks
- Medium vulnerabilities (CVSS 4.0-6.9)
- Missing audit logging

### LOW (Fix within 90 days)
- Non-optimized images
- Missing labels
- Low vulnerabilities (CVSS 0.1-3.9)
- Documentation gaps

---

## 📊 Metrics to Track

### Security Metrics

- Number of containers running
- Number of privileged containers (goal: 0)
- Percentage of containers as non-root (goal: 100%)
- Number of critical vulnerabilities (goal: 0)
- Mean time to patch (MTTP) - goal: < 7 days
- Percentage of images signed (goal: 100%)
- Security scan coverage (goal: 100%)

### Operational Metrics

- Container uptime
- Resource utilization
- Failed deployments
- Incident response time
- Compliance score (goal: 100%)

---

## 🆘 Incident Response Quick Reference

If security incident detected:

1. **Contain**: Isolate affected container(s)
   ```bash
   docker network disconnect <network> <container>
   # or
   docker stop <container>
   ```

2. **Preserve Evidence**: Capture logs and state
   ```bash
   docker logs <container> > incident-logs.txt
   docker inspect <container> > incident-inspect.json
   docker cp <container>:/path/to/suspicious/file evidence/
   ```

3. **Investigate**: Analyze what happened
   - Review audit logs
   - Check for unauthorized access
   - Identify compromised secrets
   - Determine blast radius

4. **Eradicate**: Remove threat
   ```bash
   docker rm -f <container>
   docker rmi <compromised-image>
   ```

5. **Recover**: Restore from known-good state
   - Deploy clean image
   - Rotate compromised secrets
   - Update firewall rules

6. **Document**: Write post-mortem
   - Timeline of events
   - Root cause analysis
   - Lessons learned
   - Action items

---

## 📚 References

- CIS Docker Benchmark
- NIST 800-190: Application Container Security Guide
- Docker Security Best Practices
- OWASP Docker Security Cheat Sheet
- Module 4.2: CIS Docker Benchmark (this book)
- Module 4.3: Container Isolation (this book)

---

**Last Updated:** 2026-02-28  
**Next Review:** 2026-05-28  
**Owner:** Security Team
