# Module 04, Section 4.5: Kernel & System Security

Kernel hardening and system-level security for Docker hosts.

## Files

### sysctl-hardening.conf
Production kernel parameters:
- Network security (rp_filter, SYN cookies, ICMP protection)
- Memory protection (ASLR, kptr_restrict, ptrace_scope)
- Process security (PID limits)
- Docker-specific settings
- Extensive inline documentation

### docker-audit.rules
Comprehensive auditd configuration:
- Docker daemon monitoring
- Container operations tracking
- File and directory auditing
- Socket access logging
- Configuration change detection

### kernel-security-check.sh
Automated security validation:
- sysctl parameter verification
- Auditd status checking
- Firewall configuration
- SSH hardening validation
- Service audit
- Security scoring

### module-blacklist.conf
Kernel module blacklist:
- Wireless modules (not needed in datacenter)
- Bluetooth (server environment)
- Uncommon filesystems
- Firewire/Thunderbolt (DMA attacks)
- Uncommon network protocols

## Quick Start

### Apply Kernel Hardening

```bash
# Copy sysctl configuration
sudo cp sysctl-hardening.conf /etc/sysctl.d/99-docker-hardening.conf

# Apply immediately
sudo sysctl -p /etc/sysctl.d/99-docker-hardening.conf

# Verify
sudo sysctl net.ipv4.ip_forward
sudo sysctl kernel.randomize_va_space
sudo sysctl kernel.kptr_restrict
```

### Setup Auditd

```bash
# Install auditd
sudo yum install -y audit  # RHEL/CentOS
# or
sudo apt-get install -y auditd  # Ubuntu/Debian

# Copy audit rules
sudo cp docker-audit.rules /etc/audit/rules.d/docker.rules

# Load rules
sudo augenrules --load
sudo systemctl restart auditd

# Verify
sudo auditctl -l | grep docker
```

### Run Security Check

```bash
chmod +x kernel-security-check.sh
sudo ./kernel-security-check.sh

# Sample output:
# [PASS] net.ipv4.ip_forward = 1
# [PASS] kernel.randomize_va_space = 2
# [PASS] auditd service is running
# [PASS] Docker audit rules loaded (25 rules)
# 
# Security Score: 85%
```

### Blacklist Kernel Modules

```bash
# Copy blacklist
sudo cp module-blacklist.conf /etc/modprobe.d/blacklist-security.conf

# Rebuild initramfs
# RHEL/CentOS:
sudo dracut -f

# Ubuntu/Debian:
sudo update-initramfs -u

# Reboot required
sudo reboot

# After reboot, verify
lsmod | grep -E "iwl|bluetooth|firewire"
# Should return nothing
```

## Kernel Hardening (sysctl)

### Critical Parameters

**Network Security:**
- `net.ipv4.ip_forward = 1` (required for Docker)
- `net.ipv4.conf.all.rp_filter = 1` (anti-spoofing)
- `net.ipv4.tcp_syncookies = 1` (SYN flood protection)
- `net.ipv4.conf.all.accept_redirects = 0` (prevent MITM)

**Memory Protection:**
- `kernel.randomize_va_space = 2` (ASLR enabled)
- `kernel.kptr_restrict = 2` (hide kernel pointers)
- `kernel.dmesg_restrict = 1` (restrict kernel logs)
- `kernel.yama.ptrace_scope = 1` (restrict debugging)

**Process Security:**
- `fs.suid_dumpable = 0` (disable SUID core dumps)
- `kernel.pid_max = 65536` (increase PID limit)

### Apply and Verify

```bash
# Apply all settings
sudo sysctl --system

# Check specific parameter
sysctl net.ipv4.tcp_syncookies

# View all kernel parameters
sysctl -a | less

# Settings persist across reboots
# (files in /etc/sysctl.d/)
```

## Auditd Configuration

### What Gets Audited

**Docker Binaries:**
- dockerd, docker, containerd, runc
- All executions logged with parameters

**Docker Data:**
- /var/lib/docker (all changes)
- Container, image, volume operations
- Network configurations

**Docker Configuration:**
- /etc/docker/daemon.json changes
- Systemd unit modifications
- Certificate updates

**Docker Socket:**
- /var/run/docker.sock access (CRITICAL)
- Who accessed, when, from where

### View Audit Logs

**Recent Docker activity:**
```bash
sudo ausearch -k docker_daemon -ts recent
sudo ausearch -k docker_client -ts today
```

**Socket access (detect compromise):**
```bash
sudo ausearch -k docker_socket -ts recent
```

**Failed operations:**
```bash
sudo ausearch -k docker_daemon --failed
```

**Generate reports:**
```bash
# Summary by key
sudo aureport -k docker_daemon --summary

# File access report
sudo aureport -f | grep docker

# User activity
sudo aureport -u
```

**Real-time monitoring:**
```bash
sudo ausearch -k docker_socket -i --start today | tail -f
```

### Audit Log Management

**Configure retention:**
```bash
# /etc/audit/auditd.conf
max_log_file = 100        # MB per file
num_logs = 10             # Keep 10 files
disk_full_action = ROTATE
```

**Daily reports (cron):**
```bash
# /etc/cron.daily/docker-audit-report
#!/bin/bash
ausearch -k docker_daemon -ts yesterday > /var/log/docker-audit-$(date +%Y%m%d).txt
```

## Kernel Module Control

### Why Blacklist Modules

**Security benefits:**
- Reduces attack surface
- Prevents driver vulnerabilities
- Blocks DMA attacks (Firewire, Thunderbolt)
- Prevents USB-based attacks (optional)

### Safe to Blacklist

**Always safe in datacenter:**
- Wireless (iwlwifi, cfg80211)
- Bluetooth (bluetooth, btusb)
- Firewire (firewire-core) - DMA attack vector
- Thunderbolt - DMA attack vector
- Sound (snd, soundcore)
- Uncommon filesystems (cramfs, jffs2, hfs)

**Consider blacklisting:**
- USB storage (prevents USB drives)
- Uncommon protocols (dccp, sctp, rds)

### Verify Blacklist

```bash
# Check module is blacklisted
modprobe -n -v iwlwifi
# Should show: "blacklist" or error

# Verify not loaded
lsmod | grep iwl
# Should return nothing

# List all blacklisted
grep -r "^blacklist" /etc/modprobe.d/
```

## System Service Hardening

### Disable Unnecessary Services

```bash
# Audit running services
systemctl list-units --type=service --state=running

# Safe to disable on servers
sudo systemctl disable bluetooth
sudo systemctl disable avahi-daemon
sudo systemctl disable cups
sudo systemctl disable postfix  # If not mail server
```

### Firewall Configuration

**firewalld (RHEL/CentOS):**
```bash
sudo systemctl enable firewalld
sudo systemctl start firewalld

# Default deny
sudo firewall-cmd --set-default-zone=drop

# Allow SSH
sudo firewall-cmd --permanent --add-service=ssh

# Allow Docker
sudo firewall-cmd --permanent --add-port=2376/tcp

# Reload
sudo firewall-cmd --reload
```

**ufw (Ubuntu/Debian):**
```bash
sudo ufw enable
sudo ufw default deny incoming
sudo ufw allow ssh
sudo ufw allow 8080/tcp
```

### SSH Hardening

```bash
# /etc/ssh/sshd_config
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3

# Restart SSH
sudo systemctl restart sshd
```

## Automated Validation

### Daily Security Check

```bash
# Run security check
./kernel-security-check.sh

# With auto-fix (use carefully)
sudo ./kernel-security-check.sh --fix

# Schedule daily (cron)
0 6 * * * /opt/scripts/kernel-security-check.sh > /var/log/security-check.log
```

### What Gets Checked

- ✓ 15+ sysctl parameters
- ✓ Auditd status and rules
- ✓ Firewall configuration
- ✓ SSH hardening
- ✓ Unnecessary services
- ✓ Kernel modules
- ✓ Time synchronization
- ✓ Security updates
- ✓ SELinux/AppArmor

### Exit Codes

- 0 = All checks pass
- 1 = Critical failures
- 2 = Warnings only

## Troubleshooting

### sysctl Changes Not Persistent

**Problem:** Settings revert after reboot

**Solution:**
```bash
# Settings must be in /etc/sysctl.d/
sudo cp sysctl-hardening.conf /etc/sysctl.d/99-docker-hardening.conf

# Not in /etc/sysctl.conf (deprecated)
```

### Audit Rules Not Loading

**Problem:** `auditctl -l` shows no rules

**Solution:**
```bash
# Check file location
ls -l /etc/audit/rules.d/docker.rules

# Load manually
sudo augenrules --load
sudo systemctl restart auditd

# Check for errors
sudo journalctl -u auditd -n 50
```

### Module Still Loading After Blacklist

**Problem:** Module loads despite blacklist

**Solution:**
```bash
# Rebuild initramfs
sudo dracut -f  # RHEL/CentOS
sudo update-initramfs -u  # Ubuntu/Debian

# Reboot required
sudo reboot

# Force unload (temporary)
sudo rmmod modulename
```

### IP Forwarding Disabled Breaks Docker

**Problem:** Containers can't communicate

**Solution:**
```bash
# Docker REQUIRES ip_forward=1
sudo sysctl -w net.ipv4.ip_forward=1

# Verify Docker networking works
docker run --rm alpine ping -c 2 8.8.8.8
```

## Best Practices

### Do's

✅ Apply sysctl hardening on all Docker hosts  
✅ Enable auditd with Docker rules  
✅ Regular security validation (weekly)  
✅ Blacklist unnecessary kernel modules  
✅ Configure firewall (even in air-gap)  
✅ Harden SSH configuration  
✅ Monitor audit logs  
✅ Keep security updates current  

### Don'ts

❌ Disable ip_forward (Docker needs it)  
❌ Skip auditd (critical for forensics)  
❌ Ignore audit logs  
❌ Blacklist modules Docker needs (overlay, br_netfilter)  
❌ Disable firewall  
❌ Allow root SSH login  
❌ Forget to rebuild initramfs after module blacklist  

## Security Impact

### Attack Surface Reduction

**Before hardening:**
- 300+ kernel modules available
- All syscalls accessible
- Weak network protections
- No audit trail
- Kernel pointers exposed

**After hardening:**
- 50+ unnecessary modules blocked
- Kernel pointers hidden
- ASLR enabled
- Network attacks mitigated
- Comprehensive audit trail

### Compliance

Satisfies:
- **CIS Docker Benchmark** 1.1.2, 1.2.1, 1.2.2
- **NIST 800-190** Host OS recommendations
- **PCI DSS** Requirement 2.2 (Harden systems)
- **SOC 2** CC6.1 (Logical access controls)

## Next Steps

After kernel hardening:
1. Review Section 4.6: Physical & Access Security
2. Setup centralized audit log collection
3. Regular vulnerability scanning
4. Incident response procedures
5. Compliance audits

## Support

- **Book**: Module 4, Section 4.5
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **sysctl man page**: man 8 sysctl
- **auditd documentation**: man 8 auditd

## License

MIT License - See repository root for details
