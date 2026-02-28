# Module 04, Section 4.3: Container Isolation

Deep dive into Linux kernel isolation mechanisms for Docker containers.

## Files

### namespace-test.sh
Comprehensive namespace isolation testing:
- PID namespace verification
- Network namespace isolation
- Mount namespace checks
- UTS (hostname) isolation
- IPC isolation
- USER namespace remapping
- Negative tests (host network, privileged)

### cgroups-limits.sh
Resource limits demonstration:
- Memory limits enforcement
- CPU quota testing
- PID limits verification
- Real-time monitoring
- Cgroup filesystem inspection

### capabilities-audit.sh
Capability security audit:
- Detect dangerous capabilities
- Check for ALL dropped
- Runtime capability inspection
- Security recommendations

### seccomp-minimal.json
Minimal seccomp profile template:
- Only essential syscalls allowed
- Blocks 250+ dangerous syscalls
- Production-ready baseline

### apparmor-profile.template
AppArmor profile template:
- File access restrictions
- Network permissions
- Capability controls
- Dangerous path denials

## Quick Start

### Test Namespace Isolation

```bash
chmod +x namespace-test.sh
sudo ./namespace-test.sh

# Tests:
#  ✓ PID namespace isolates processes
#  ✓ NET namespace isolates network
#  ✓ MNT namespace isolates mounts
#  ✓ UTS namespace isolates hostname
#  ✓ IPC namespace isolates IPC
#  ✓ USER namespace remaps UIDs (if enabled)
```

### Test Resource Limits

```bash
chmod +x cgroups-limits.sh
sudo ./cgroups-limits.sh

# Creates container with:
#  - 512MB memory limit
#  - 0.5 CPU cores
#  - 100 PID limit
# Tests enforcement
```

### Audit Capabilities

```bash
chmod +x capabilities-audit.sh
sudo ./capabilities-audit.sh

# Scans all running containers
# Flags dangerous capabilities
```

### Use Seccomp Profile

```bash
# Apply minimal seccomp profile
docker run \
  --security-opt seccomp=seccomp-minimal.json \
  alpine sh

# Test blocked syscall
docker exec container reboot
# Operation not permitted ✓
```

### Use AppArmor Profile

```bash
# Load profile (Ubuntu/Debian)
sudo cp apparmor-profile.template /etc/apparmor.d/docker-custom
sudo apparmor_parser -r /etc/apparmor.d/docker-custom

# Use profile
docker run --security-opt apparmor=docker-custom alpine
```

## Namespace Types

### PID Namespace

**Isolation:** Process IDs

**Benefits:**
- Container sees only its own processes
- PID 1 inside container
- Cannot kill host processes

**Example:**
```bash
docker run alpine ps aux
# PID 1: current process (not host init)
```

### NET Namespace

**Isolation:** Network stack

**Benefits:**
- Own interfaces (lo, eth0)
- Own IP address
- Own routing table
- Own firewall rules

**Example:**
```bash
docker run alpine ip addr
# Shows container-specific network
```

### MNT Namespace

**Isolation:** Filesystem mounts

**Benefits:**
- Cannot see host mounts
- Own root filesystem
- Volume mounts controlled

**Danger:**
```bash
# NEVER mount root filesystem
docker run -v /:/host alpine
# Full host access ❌
```

### USER Namespace

**Isolation:** UID/GID mapping

**Benefits:**
- Container root = unprivileged host user
- Reduces escape impact

**Setup:**
```bash
# daemon.json
{
  "userns-remap": "dockremap"
}

# /etc/subuid and /etc/subgid
dockremap:100000:65536
```

## Resource Limits (cgroups)

### Memory Limits

**Always required:**
```bash
docker run --memory=512m myapp
```

**With soft limit:**
```bash
docker run \
  --memory=512m \
  --memory-reservation=256m \
  myapp
```

**Why critical:**
- Prevents DoS via memory exhaustion
- Protects host from OOM

### CPU Limits

**Simple percentage:**
```bash
docker run --cpus=0.5 myapp
# 50% of one core
```

**Relative shares:**
```bash
docker run --cpu-shares=512 myapp
# Half the default weight
```

### PID Limits

**Prevent fork bombs:**
```bash
docker run --pids-limit=100 myapp
```

## Linux Capabilities

### Drop ALL, Add Needed

**Best practice:**
```bash
docker run \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  nginx
```

### Dangerous Capabilities

**NEVER grant:**
- `SYS_ADMIN` - System administration
- `SYS_MODULE` - Load kernel modules  
- `SYS_RAWIO` - Raw I/O access
- `SYS_PTRACE` - Process tracing

### Common Safe Capabilities

- `NET_BIND_SERVICE` - Bind ports < 1024
- `CHOWN` - Change file ownership
- `SETUID/SETGID` - Change UIDs/GIDs
- `DAC_OVERRIDE` - Bypass file permissions

## Seccomp Profiles

### Default Profile

Docker blocks ~50 dangerous syscalls by default.

**Check current:**
```bash
docker run alpine grep Seccomp /proc/self/status
# Seccomp: 2 (filtered)
```

### Custom Minimal Profile

Use `seccomp-minimal.json`:
- Allows only essential syscalls
- Blocks mount, reboot, kexec, etc.
- Suitable for most applications

### Generate Custom Profile

```bash
# Method 1: Trace syscalls
strace -c docker run myapp

# Method 2: Use tools
# github.com/jessfraz/bane
```

## AppArmor / SELinux

### AppArmor (Ubuntu/Debian)

**Check status:**
```bash
aa-status
```

**Load custom profile:**
```bash
sudo apparmor_parser -r /etc/apparmor.d/docker-custom
docker run --security-opt apparmor=docker-custom myapp
```

### SELinux (RHEL/CentOS)

**Check status:**
```bash
getenforce
# Enforcing
```

**Use custom context:**
```bash
docker run --security-opt label=type:svirt_apache_t nginx
```

## Best Practices

### Namespace Isolation

✅ **Do:**
- Use default namespace isolation
- Create custom networks
- Isolate production environments

❌ **Don't:**
- Use `--net=host` in production
- Use `--pid=host`
- Mount Docker socket

### Resource Limits

✅ **Do:**
- Set memory limits always
- Set CPU limits for critical apps
- Set PID limits (50-200 typical)
- Monitor actual usage

❌ **Don't:**
- Leave limits unlimited
- Set arbitrary limits without testing
- Disable OOM killer

### Capabilities

✅ **Do:**
- Drop ALL capabilities
- Add only required
- Document why each is needed
- Regular audits

❌ **Don't:**
- Grant SYS_ADMIN
- Use privileged mode
- Grant capabilities "just in case"

### Security Profiles

✅ **Do:**
- Use seccomp (default or custom)
- Use AppArmor/SELinux
- Test profiles in staging
- Version control profiles

❌ **Don't:**
- Disable seccomp
- Use unconfined mode
- Skip testing

## Troubleshooting

### "Operation not permitted"

**Cause:** Seccomp or capabilities blocking

**Fix:**
```bash
# Identify required syscall
strace docker run myapp 2>&1 | grep EPERM

# Or check capabilities
docker run --cap-add=CHOWN myapp
```

### Volume permission errors with userns

**Cause:** UID remapping

**Fix:**
```bash
# Find remapped range
grep dockremap /etc/subuid

# Chown volumes
sudo chown -R 100000:100000 /path/to/volume
```

### Container cannot bind to port 80

**Cause:** Missing NET_BIND_SERVICE capability

**Fix:**
```bash
docker run --cap-add=NET_BIND_SERVICE -p 80:80 nginx
```

## Testing Isolation

### Verify PID isolation
```bash
docker run alpine ps aux
# Should see only container processes
```

### Verify network isolation
```bash
# Create two containers on different networks
docker network create net1
docker network create net2

docker run -d --name c1 --net net1 alpine sleep 1000
docker run -d --name c2 --net net2 alpine sleep 1000

# Should fail
docker exec c1 ping c2
```

### Verify resource limits
```bash
# Memory limit test
docker run --memory=100m alpine sh -c 'cat /dev/zero | head -c 200M > /tmp/file'
# Should be killed
```

## Next Steps

After mastering isolation:
1. Review Section 4.4: Runtime Security
2. Implement kernel hardening (Section 4.5)
3. Regular isolation audits
4. User namespace enablement (if not done)
5. Custom seccomp/AppArmor profiles

## Support

- **Book**: Module 4, Section 4.3
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Namespaces**: man 7 namespaces
- **Cgroups**: man 7 cgroups
- **Capabilities**: man 7 capabilities

## License

MIT License - See repository root for details
