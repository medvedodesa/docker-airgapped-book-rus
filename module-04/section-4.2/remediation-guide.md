# CIS Docker Benchmark Remediation Guide

Step-by-step fixes for common CIS Docker Benchmark failures.

---

## Section 1: Host Configuration

### 1.1.1: Create separate partition for containers

**Finding:** `/var/lib/docker` is not on a separate partition

**Risk:** Resource exhaustion can affect entire system

**Remediation:**

```bash
# 1. Stop Docker
systemctl stop docker

# 2. Backup existing data
tar czf /tmp/docker-backup.tar.gz /var/lib/docker

# 3. Create LVM volume (100GB example)
lvcreate -L 100G -n docker vg0
mkfs.xfs /dev/vg0/docker

# 4. Mount temporarily
mkdir /mnt/docker-new
mount /dev/vg0/docker /mnt/docker-new

# 5. Copy data
rsync -av /var/lib/docker/ /mnt/docker-new/

# 6. Update fstab
echo "/dev/vg0/docker /var/lib/docker xfs defaults 0 0" >> /etc/fstab

# 7. Mount permanently
umount /mnt/docker-new
rm -rf /var/lib/docker.old
mv /var/lib/docker /var/lib/docker.old
mkdir /var/lib/docker
mount /var/lib/docker

# 8. Start Docker
systemctl start docker

# 9. Verify
df -h /var/lib/docker
docker ps
```

---

### 1.1.2: Harden container host

**Finding:** Host OS not hardened per CIS Linux Benchmark

**Remediation:**

```bash
# SELinux enforcing
sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
setenforce 1

# Install security tools
yum install -y aide

# Initialize AIDE
aide --init
mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz

# Disable unnecessary services
systemctl disable postfix avahi-daemon cups

# Configure firewall
firewall-cmd --permanent --zone=public --remove-service=dhcpv6-client
firewall-cmd --permanent --zone=public --add-service=ssh
firewall-cmd --reload

# Apply kernel hardening
cp /etc/sysctl.conf /etc/sysctl.conf.backup
cat >> /etc/sysctl.conf << 'EOF'
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
kernel.randomize_va_space = 2
kernel.exec-shield = 1
kernel.kptr_restrict = 2
fs.suid_dumpable = 0
EOF

sysctl -p
```

---

### 1.2.1: Configure auditing for Docker daemon

**Finding:** Docker daemon not being audited

**Remediation:**

```bash
# Create audit rules
cat > /etc/audit/rules.d/docker.rules << 'EOF'
-w /usr/bin/dockerd -k docker
-w /usr/bin/docker -k docker
-w /var/lib/docker -k docker
-w /etc/docker -k docker
-w /lib/systemd/system/docker.service -k docker
-w /lib/systemd/system/docker.socket -k docker
-w /etc/docker/daemon.json -k docker
-w /usr/bin/containerd -k docker
-w /usr/bin/runc -k docker
-w /var/run/docker.sock -k docker
EOF

# Load rules
augenrules --load

# Restart auditd
systemctl restart auditd

# Verify
auditctl -l | grep docker

# Test
docker ps
ausearch -k docker -ts recent
```

---

## Section 2: Docker Daemon Configuration

### 2.1: Restrict inter-container communication

**Finding:** ICC not disabled

**Remediation:**

```bash
# Edit daemon.json
cat > /etc/docker/daemon.json << 'EOF'
{
  "icc": false
}
EOF

# Restart Docker
systemctl restart docker

# Verify
docker info | grep -i bridge

# Test (containers should NOT communicate by default)
docker network create test-net
docker run -d --name test1 --network test-net alpine sleep 1000
docker run -d --name test2 --network test-net alpine sleep 1000

# This should fail:
docker exec test1 ping -c 1 test2

# Cleanup
docker rm -f test1 test2
docker network rm test-net
```

---

### 2.2: Set logging level

**Finding:** Logging level not set to info

**Remediation:**

```bash
# Method 1: daemon.json
jq '. + {"log-level": "info"}' /etc/docker/daemon.json > /tmp/daemon.json
mv /tmp/daemon.json /etc/docker/daemon.json

# Method 2: systemd override
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/logging.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd --log-level=info
EOF

systemctl daemon-reload
systemctl restart docker

# Verify
ps aux | grep dockerd | grep log-level
```

---

### 2.4: Remove insecure registries

**Finding:** Insecure registries configured

**Remediation:**

```bash
# Remove insecure-registries from daemon.json
jq 'del(.["insecure-registries"])' /etc/docker/daemon.json > /tmp/daemon.json
mv /tmp/daemon.json /etc/docker/daemon.json

# Restart Docker
systemctl restart docker

# Verify
jq '.["insecure-registries"]' /etc/docker/daemon.json
# Should output: null

# Configure Harbor with proper TLS instead
# See Module 3 for Harbor TLS setup
```

---

### 2.5: Enable live restore

**Finding:** Live restore not enabled

**Remediation:**

```bash
# Add to daemon.json
jq '. + {"live-restore": true}' /etc/docker/daemon.json > /tmp/daemon.json
mv /tmp/daemon.json /etc/docker/daemon.json

# Restart Docker
systemctl restart docker

# Test
docker run -d --name test nginx
systemctl restart docker
docker ps | grep test  # Should still be running
docker rm -f test
```

---

### 2.6: Enable user namespace remapping

**Finding:** User namespaces not enabled (Level 2)

**Remediation:**

```bash
# IMPORTANT: Test in staging first!
# This can break volume permissions

# 1. Create subuid/subgid entries
echo "dockremap:100000:65536" >> /etc/subuid
echo "dockremap:100000:65536" >> /etc/subgid

# 2. Configure daemon
jq '. + {"userns-remap": "dockremap"}' /etc/docker/daemon.json > /tmp/daemon.json
mv /tmp/daemon.json /etc/docker/daemon.json

# 3. Restart Docker
systemctl restart docker

# 4. Verify
docker info | grep userns

# 5. Test
docker run --rm alpine id
# UID 0 inside, but 100000+ on host

ps aux | grep containerd-shim
# Should show high UIDs

# 6. Fix volume permissions if needed
# Volumes may need chown to 100000:100000 range
```

---

## Section 3: Docker Files Configuration

### 3.2: Fix docker.service permissions

**Finding:** docker.service file has incorrect permissions

**Remediation:**

```bash
# Set ownership
chown root:root /lib/systemd/system/docker.service

# Set permissions
chmod 644 /lib/systemd/system/docker.service

# Verify
ls -l /lib/systemd/system/docker.service
# Should be: -rw-r--r-- root root

# Reload systemd
systemctl daemon-reload
```

---

### 3.4: Fix Docker socket permissions

**Finding:** Docker socket has overly permissive permissions

**Remediation:**

```bash
# Set permissions
chmod 660 /var/run/docker.sock

# Set ownership
chown root:docker /var/run/docker.sock

# Verify
ls -l /var/run/docker.sock
# Should be: srw-rw---- root docker

# Make permanent (systemd unit override)
mkdir -p /etc/systemd/system/docker.socket.d
cat > /etc/systemd/system/docker.socket.d/socket.conf << 'EOF'
[Socket]
SocketMode=0660
SocketUser=root
SocketGroup=docker
EOF

systemctl daemon-reload
systemctl restart docker.socket
```

---

## Section 5: Container Runtime

### 5.1: Remove privileged containers

**Finding:** Privileged containers detected

**Remediation:**

```bash
# Find privileged containers
docker ps -q | xargs docker inspect --format '{{.Name}}: {{.HostConfig.Privileged}}'

# For each privileged container:
# 1. Identify why it's privileged
# 2. Grant specific capabilities instead:

docker run -d \
  --cap-drop=ALL \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_TIME \
  myimage

# Or if truly needed (rare):
# Document justification
# Get security approval
# Implement additional controls
```

---

### 5.2: Run containers as non-root user

**Finding:** Containers running as root

**Remediation:**

**Dockerfile fix:**
```dockerfile
FROM alpine:3.18

# Create user
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser

# App setup
WORKDIR /app
COPY app.py .

# Switch to non-root
USER appuser

CMD ["python3", "app.py"]
```

**Runtime fix:**
```bash
# Override at runtime
docker run -u 1000:1000 myimage

# Or in docker-compose:
services:
  app:
    user: "1000:1000"
```

---

### 5.3: Set resource limits

**Finding:** Containers without resource limits

**Remediation:**

```bash
# Set limits at runtime
docker run -d \
  --memory="512m" \
  --memory-reservation="256m" \
  --cpus="0.5" \
  --pids-limit="100" \
  myimage

# In docker-compose:
services:
  app:
    deploy:
      resources:
        limits:
          cpus: '0.50'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M

# Verify
docker stats --no-stream
```

---

### 5.4: Mount filesystem read-only

**Finding:** Containers have read-write root filesystem

**Remediation:**

```bash
# Run with read-only root
docker run -d --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \
  --tmpfs /var/run:rw,noexec,nosuid,size=10m \
  nginx

# In docker-compose:
services:
  app:
    read_only: true
    tmpfs:
      - /tmp:size=100M,mode=1777
      - /var/run:size=10M,mode=755
```

---

## Common Issues & Solutions

### Issue: Cannot start containers after user namespace remapping

**Cause:** Volume permission mismatch

**Solution:**
```bash
# Find subordinate UID range
grep dockremap /etc/subuid
# Example: dockremap:100000:65536

# Fix volume permissions
chown -R 100000:100000 /path/to/volume

# Or disable userns for specific container:
docker run --userns=host myimage
```

---

### Issue: Live restore not working

**Cause:** Conflicting with other settings

**Solution:**
```bash
# Disable Swarm mode if enabled
docker swarm leave --force

# Ensure not in daemon config conflicts
jq 'del(.["cluster-store"]) | del(.["cluster-advertise"])' /etc/docker/daemon.json > /tmp/daemon.json
mv /tmp/daemon.json /etc/docker/daemon.json

systemctl restart docker
```

---

### Issue: SELinux blocks Docker

**Cause:** SELinux policy issues

**Solution:**
```bash
# Check for denials
ausearch -m avc -ts recent

# Generate custom policy
audit2allow -M mydocker < /var/log/audit/audit.log
semodule -i mydocker.pp

# Or set container-specific context:
docker run --security-opt label=type:svirt_apache_t myimage
```

---

## Validation After Remediation

### Run comprehensive audit:

```bash
# Using Docker Bench Security
docker-bench

# Using custom audit script
./cis-audit.sh --report /var/log/cis-audit-$(date +%Y%m%d).html

# Manual verification
docker info
docker ps -q | xargs docker inspect
```

### Monitor for regressions:

```bash
# Cron job for weekly audits
0 2 * * 0 /opt/scripts/cis-audit.sh --report /var/log/weekly-audit.html
```

---

## Priority Order for Remediation

### P0 - Critical (Fix Immediately)
- Remove privileged containers (5.1)
- Remove insecure registries (2.4)
- Fix Docker socket permissions (3.4)
- Enable auditd (1.2.1)

### P1 - High (Fix within 7 days)
- Enable live restore (2.5)
- Disable ICC (2.1)
- Harden container host (1.1.2)
- Set resource limits (5.3)

### P2 - Medium (Fix within 30 days)
- Separate partition (1.1.1)
- Non-root containers (5.2)
- Read-only filesystem (5.4)

### P3 - Low/Optional (Fix within 90 days)
- User namespace remapping (2.6) - Level 2
- Additional hardening

---

## Compliance Tracking

Create tracking spreadsheet:

| Control | Status | Priority | Fixed Date | Verified By |
|---------|--------|----------|------------|-------------|
| 1.1.1   | Fixed  | P2       | 2024-01-15 | Admin       |
| 1.2.1   | Fixed  | P0       | 2024-01-10 | Security    |
| 2.1     | Fixed  | P1       | 2024-01-12 | DevOps      |
| ...     | ...    | ...      | ...        | ...         |

Schedule quarterly reviews to maintain compliance.
