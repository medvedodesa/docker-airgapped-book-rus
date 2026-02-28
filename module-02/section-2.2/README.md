# Module 02, Section 2.2: OS-specific Installation Scripts

This directory contains automated installation scripts for Docker on different Linux distributions in air-gapped environments.

## Quick Start

### For RHEL/CentOS/Rocky/AlmaLinux

```bash
# 1. Extract bundle
tar xzf docker-offline-v1.0.tar.gz
cd docker-offline-v1.0

# 2. Run installation
sudo ../rhel-install.sh

# 3. Verify
../post-install-verify.sh
```

### For Ubuntu/Debian

```bash
# 1. Extract bundle
tar xzf docker-offline-v1.0.tar.gz
cd docker-offline-v1.0

# 2. Run installation
sudo ../ubuntu-install.sh

# 3. Verify
../post-install-verify.sh
```

### For SUSE Linux Enterprise Server

```bash
# 1. Extract bundle
tar xzf docker-offline-v1.0.tar.gz
cd docker-offline-v1.0

# 2. Run installation
sudo ../sles-install.sh

# 3. Verify
../post-install-verify.sh
```

## Scripts Overview

| Script | Purpose | OS |
|--------|---------|-----|
| `rhel-install.sh` | Automated Docker installation | RHEL/CentOS/Rocky/AlmaLinux 9+ |
| `ubuntu-install.sh` | Automated Docker installation | Ubuntu 22.04+ / Debian 11+ |
| `sles-install.sh` | Automated Docker installation | SLES 15 SP4+ / openSUSE Leap 15.4+ |
| `post-install-verify.sh` | Comprehensive verification | All distributions |

## What the Installation Scripts Do

All installation scripts follow the same workflow:

1. **System Check**
   - Verify OS type and version
   - Check disk space (minimum 20GB free)
   - Display system information

2. **Remove Old Docker**
   - Stop existing Docker services
   - Remove old Docker packages
   - Clean up old data directories

3. **Create Local Repository**
   - Copy packages to local directory
   - Create repository metadata (createrepo/dpkg-scanpackages)
   - Configure package manager

4. **Install Docker**
   - Install docker-ce, docker-ce-cli, containerd.io
   - Install docker-buildx-plugin, docker-compose-plugin
   - Install all dependencies

5. **Start Services**
   - Enable Docker and Containerd for autostart
   - Start both services
   - Verify services are running

6. **Configure User**
   - Add current user to docker group
   - Display next steps

## Post-Installation Verification

The `post-install-verify.sh` script performs 12 comprehensive checks:

1. **Docker version** - Verify docker command works
2. **Docker Compose version** - Verify compose plugin
3. **Docker service status** - Check if docker.service is active
4. **Containerd service status** - Check if containerd.service is active
5. **Storage Driver** - Verify overlay2 is used
6. **Cgroup Driver** - Verify systemd is used (critical for K8s)
7. **Docker networks** - Verify bridge, host, none exist
8. **Permissions** - Check non-root docker access
9. **Disk space** - Verify >10GB free on /var/lib/docker
10. **Daemon logs** - Check for errors in journalctl
11. **Kernel version** - Verify kernel >= 3.10
12. **Test container** - Run hello-world or alpine test

### Verification Results

- **PASS**: All checks passed, Docker ready for production
- **WARN**: Installation complete with warnings (review and fix)
- **FAIL**: Critical issues, must fix before production use

## Manual Installation Steps

If you prefer manual installation or the automated scripts fail, follow these steps:

### RHEL/CentOS/Rocky

```bash
# Create local repo
sudo mkdir -p /var/local-yum-repo/docker
sudo cp packages/*.rpm /var/local-yum-repo/docker/
sudo createrepo /var/local-yum-repo/docker

# Configure DNF
sudo tee /etc/yum.repos.d/docker-local.repo > /dev/null <<EOF
[docker-local]
name=Docker Local Repository
baseurl=file:///var/local-yum-repo/docker
enabled=1
gpgcheck=0
EOF

sudo dnf clean all

# Install
sudo dnf install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Start
sudo systemctl enable --now docker containerd
sudo usermod -aG docker $USER
```

### Ubuntu/Debian

```bash
# Create local repo
sudo mkdir -p /var/local-apt-repo/docker
sudo cp packages/*.deb /var/local-apt-repo/docker/
cd /var/local-apt-repo/docker
sudo dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# Configure APT
sudo tee /etc/apt/sources.list.d/docker-local.list > /dev/null <<EOF
deb [trusted=yes] file:///var/local-apt-repo/docker ./
EOF

sudo apt-get update

# Install
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Start
sudo systemctl enable --now docker containerd
sudo usermod -aG docker $USER
```

### SLES

```bash
# Create local repo
sudo mkdir -p /var/local-zypp-repo/docker
sudo cp packages/*.rpm /var/local-zypp-repo/docker/
cd /var/local-zypp-repo/docker
sudo createrepo_c .

# Configure zypper
sudo zypper addrepo --no-check \
    file:///var/local-zypp-repo/docker \
    docker-local
sudo zypper refresh

# Install
sudo zypper install -y docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin

# Start
sudo systemctl enable --now docker containerd
sudo usermod -aG docker $USER
```

## Troubleshooting

### Common Issues

**Issue: "createrepo command not found" (RHEL)**
```bash
# Solution: Install createrepo from bundle
sudo dnf install createrepo
```

**Issue: "Package docker-ce has no installation candidate" (Ubuntu)**
```bash
# Solution: Verify Packages.gz exists
ls -lh /var/local-apt-repo/docker/Packages.gz

# Recreate if missing
cd /var/local-apt-repo/docker
sudo dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
sudo apt-get update
```

**Issue: "Failed to start docker.service"**
```bash
# Check containerd first
sudo systemctl status containerd
sudo systemctl start containerd
sudo systemctl restart docker

# Check logs
sudo journalctl -u docker -n 50
```

**Issue: "docker: permission denied"**
```bash
# Add user to docker group
sudo usermod -aG docker $USER

# Apply immediately (or logout/login)
newgrp docker

# Verify
groups | grep docker
```

**Issue: Cgroup driver is cgroupfs instead of systemd**
```bash
# Create daemon.json (see Section 2.3)
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"]
}
EOF

sudo systemctl restart docker
```

## Requirements

### All Distributions

- Kernel >= 3.10 (recommended >= 5.x)
- 64-bit architecture (x86_64)
- 2GB RAM minimum
- 20GB free disk space on /var
- systemd init system

### RHEL-specific

- RHEL/CentOS/Rocky/AlmaLinux 9.x
- createrepo package (usually pre-installed)
- SELinux enabled (do NOT disable)

### Ubuntu-specific

- Ubuntu 22.04 LTS (Jammy) or 20.04 LTS (Focal)
- dpkg-dev package (for dpkg-scanpackages)
- AppArmor enabled

### SLES-specific

- SLES 15 SP4+ or openSUSE Leap 15.4+
- createrepo_c package

## Next Steps After Installation

1. **Logout and login** (to apply docker group membership)
2. **Test Docker**: `docker run --rm alpine:3.18 echo "Works!"`
3. **Configure Docker** for air-gap (Section 2.3):
   - daemon.json settings
   - Storage driver tuning
   - Logging configuration
   - Security defaults
4. **Deploy base infrastructure** (Section 2.4):
   - DNS server
   - NTP server
   - Internal CA
   - Package repositories

## Support

- **Book**: Module 2, Section 2.2
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Issues**: Report bugs via GitHub Issues

## License

MIT License - See repository root for details
