# Module 04, Section 4.4: Runtime Security Hardening

Production-ready runtime security configurations and hardening best practices.

## Files

### secure-compose.yml
Complete production Docker Compose template:
- All security controls enabled
- Web + Database + Cache example
- Extensive inline documentation
- Security checklist included
- Ready to customize and deploy

### runtime-audit.sh
Automated runtime security scanner:
- Checks 10+ security controls
- Scans all running containers
- Security scoring
- Actionable recommendations
- Exit codes for CI/CD integration

### readonly-test.sh
Read-only filesystem compatibility tester:
- Test any image for read-only support
- Identify required writable paths
- Application-specific tests
- Configuration recommendations

### health-check-examples.sh
Comprehensive health check reference:
- 12 categories of health checks
- HTTP, TCP, database, process checks
- Multi-step examples
- Application code samples
- Monitoring scripts

## Quick Start

### Use Production Template

```bash
# Copy and customize
cp secure-compose.yml docker-compose.yml

# Edit image names, volumes, environment
vim docker-compose.yml

# Deploy
docker-compose up -d

# Verify security
docker-compose ps
./runtime-audit.sh
```

### Audit Running Containers

```bash
chmod +x runtime-audit.sh
sudo ./runtime-audit.sh

# Sample output:
# [PASS] Running as non-root (1000:1000)
# [PASS] Read-only root filesystem
# [FAIL] Container is privileged (CRITICAL)
# [WARN] No memory limit
#
# Security Score: 75%
```

### Test Read-Only Compatibility

```bash
chmod +x readonly-test.sh
./readonly-test.sh nginx:alpine

# Tests:
#  ✓ Container starts with read-only
#  ✓ Works with /tmp tmpfs
#  ✓ Web server functional
# 
# Recommended configuration provided
```

### View Health Check Examples

```bash
./health-check-examples.sh | less

# See examples for:
# - HTTP health checks
# - Database checks
# - Process monitoring
# - Security-focused checks
```

## Runtime Security Controls

### 1. Read-Only Root Filesystem

**Why critical:**
- Prevents malware persistence
- Blocks unauthorized modifications
- Immutable infrastructure

**Implementation:**
```yaml
services:
  app:
    read_only: true
    tmpfs:
      - /tmp:size=100M,noexec,nosuid
```

**Common tmpfs requirements:**
- Web servers: `/var/cache`, `/var/run`
- Databases: `/tmp`, `/run` (data on volume)
- Most apps: `/tmp`

### 2. Non-Root User

**Why critical:**
- Limits escape impact
- Defense in depth
- Least privilege

**Dockerfile:**
```dockerfile
RUN adduser -D -u 1000 appuser
USER appuser
```

**Runtime:**
```yaml
services:
  app:
    user: "1000:1000"
```

### 3. No New Privileges

**Prevents:**
- Privilege escalation via setuid binaries

**Implementation:**
```yaml
security_opt:
  - no-new-privileges:true
```

### 4. Drop All Capabilities

**Best practice:**
```yaml
cap_drop:
  - ALL
cap_add:
  - NET_BIND_SERVICE  # Only if needed
```

### 5. Resource Limits

**Prevent DoS:**
```yaml
deploy:
  resources:
    limits:
      cpus: '0.50'
      memory: 512M
pids_limit: 100
```

### 6. Health Checks

**Early detection:**
```yaml
healthcheck:
  test: ["CMD", "curl", "-f", "http://localhost:8080/health"]
  interval: 30s
  timeout: 3s
  retries: 3
```

## Security Checklist

### Before Deployment

- [ ] Image from trusted registry
- [ ] Specific version tag (not 'latest')
- [ ] Runs as non-root user
- [ ] Read-only root filesystem
- [ ] All capabilities dropped
- [ ] Resource limits set
- [ ] Health check implemented
- [ ] No secrets in environment
- [ ] Logs configured
- [ ] Network segmentation
- [ ] Security scanning completed

### Runtime Monitoring

- [ ] Regular security audits (weekly)
- [ ] Health status monitoring
- [ ] Resource usage tracking
- [ ] Log analysis
- [ ] Vulnerability rescanning

## Application-Specific Examples

### Nginx

```yaml
services:
  nginx:
    image: nginx:alpine
    user: "101:101"
    read_only: true
    tmpfs:
      - /var/cache/nginx:size=50M
      - /var/run:size=10M
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - CHOWN
      - SETUID
      - SETGID
    deploy:
      resources:
        limits:
          memory: 256M
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:80"]
      interval: 30s
```

### PostgreSQL

```yaml
services:
  postgres:
    image: postgres:15
    user: "999:999"
    read_only: true
    tmpfs:
      - /tmp
      - /run
      - /run/postgresql
    volumes:
      - pgdata:/var/lib/postgresql/data
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - FOWNER
      - SETGID
      - SETUID
    deploy:
      resources:
        limits:
          memory: 1G
    healthcheck:
      test: ["CMD-SHELL", "pg_isready"]
      interval: 30s
```

### Python Application

```yaml
services:
  app:
    image: myapp:1.0.0
    user: "1000:1000"
    read_only: true
    tmpfs:
      - /tmp:size=100M,noexec
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
    healthcheck:
      test: ["CMD", "python", "-c", "import requests; requests.get('http://localhost:8080/health')"]
      interval: 30s
```

## Troubleshooting

### Read-Only Filesystem Errors

**Error:** `Read-only file system`

**Solution:**
```bash
# Identify write location
strace -e trace=open,openat docker run --read-only myapp

# Add tmpfs for that location
--tmpfs /path/to/writable:size=50M
```

### Permission Denied (Non-Root)

**Error:** `Permission denied`

**Solution:**
```dockerfile
# Ensure files owned by app user
COPY --chown=appuser:appuser . /app
RUN chown -R appuser:appuser /app
```

### Cannot Bind to Port 80

**Error:** `Permission denied` on port 80

**Solution:**
```bash
# Add capability
cap_add:
  - NET_BIND_SERVICE

# Or use port >= 1024
```

### Health Check Failing

**Error:** Container marked unhealthy

**Diagnosis:**
```bash
# Check health logs
docker inspect mycontainer --format='{{json .State.Health}}' | jq

# Manual test
docker exec mycontainer curl -f http://localhost:8080/health
```

## Best Practices

### Do's

✅ Always set resource limits  
✅ Run as non-root  
✅ Use read-only filesystem  
✅ Implement health checks  
✅ Drop all capabilities  
✅ Enable no-new-privileges  
✅ Use specific image tags  
✅ Monitor health status  
✅ Regular security audits  

### Don'ts

❌ Run as root in production  
❌ Use writable root filesystem unnecessarily  
❌ Grant excessive capabilities  
❌ Skip resource limits  
❌ Use 'latest' tag  
❌ Disable security features  
❌ Ignore health check failures  
❌ Put secrets in environment  

## Monitoring

### Check Health Status

```bash
# All containers
docker ps --format "table {{.Names}}\t{{.Status}}"

# Only unhealthy
docker ps --filter "health=unhealthy"

# Detailed health
docker inspect mycontainer --format='{{json .State.Health}}' | jq
```

### Resource Usage

```bash
# Real-time
docker stats

# Specific container
docker stats mycontainer --no-stream

# CSV format
docker stats --format "table {{.Name}},{{.CPUPerc}},{{.MemPerc}},{{.MemUsage}}"
```

### Automated Monitoring

```bash
# Cron job (every 5 minutes)
*/5 * * * * /opt/scripts/runtime-audit.sh >> /var/log/runtime-audit.log

# Alert on failures
*/5 * * * * /opt/scripts/check-health.sh || /opt/scripts/alert.sh
```

## Next Steps

After runtime hardening:
1. Review Section 4.5: Kernel & System Security
2. Implement behavioral monitoring (Falco)
3. Setup centralized logging
4. Regular compliance audits
5. Incident response procedures

## Support

- **Book**: Module 4, Section 4.4
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Docker Security**: https://docs.docker.com/engine/security/

## License

MIT License - See repository root for details
