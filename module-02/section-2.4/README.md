# Module 02, Section 2.4: Base Infrastructure

Configuration files and scripts for deploying base infrastructure services in air-gapped Docker environments.

## Files Overview

### DNS (Dnsmasq)
- **dnsmasq.conf** - Main DNS server configuration
- **hosts.conf** - DNS records for all infrastructure hosts

### NTP (Chrony)
- **chrony.conf.server** - NTP server configuration (Stratum 1)
- **chrony.conf.client** - NTP client configuration (Stratum 2)

### PKI (Certificate Authority)
- **openssl-ca.cnf** - OpenSSL configuration for Root CA
- **create-root-ca.sh** - Automated Root CA creation script
- **create-server-cert.sh** - Server certificate generation script

## Quick Start

### 1. Deploy DNS Server

```bash
# Install dnsmasq
sudo apt-get install dnsmasq  # Ubuntu/Debian
sudo dnf install dnsmasq      # RHEL/CentOS

# Copy configuration
sudo cp dnsmasq.conf /etc/dnsmasq.conf
sudo cp hosts.conf /etc/dnsmasq.d/hosts.conf

# Edit hosts.conf with your IP addresses
sudo vim /etc/dnsmasq.d/hosts.conf

# Start dnsmasq
sudo systemctl enable dnsmasq
sudo systemctl start dnsmasq

# Test
nslookup harbor.company.local localhost
```

### 2. Deploy NTP Server

```bash
# Install chrony
sudo apt-get install chrony  # Ubuntu/Debian
sudo dnf install chrony      # RHEL/CentOS

# For NTP Server (Stratum 1)
sudo cp chrony.conf.server /etc/chrony/chrony.conf

# Start chrony
sudo systemctl enable chronyd
sudo systemctl start chronyd

# Verify
chronyc sources
chronyc tracking
```

### 3. Configure NTP Clients

```bash
# On all Docker hosts and infrastructure servers
sudo cp chrony.conf.client /etc/chrony/chrony.conf

# Edit to match your NTP servers
sudo vim /etc/chrony/chrony.conf

# Restart
sudo systemctl restart chronyd

# Verify synchronization
chronyc sources
```

### 4. Create Root CA

```bash
# IMPORTANT: Run on OFFLINE, SECURE machine!
chmod +x create-root-ca.sh
sudo ./create-root-ca.sh

# Follow prompts
# CRITICAL: Store backup securely!
```

### 5. Create Server Certificates

```bash
# For each service (harbor, vault, gitlab, etc.)
chmod +x create-server-cert.sh
sudo ./create-server-cert.sh harbor.company.local

# Transfer files to target server
scp certs/harbor.company.local/* harbor-server:/etc/ssl/harbor/
```

## DNS Configuration

### Customizing DNS Records

Edit `hosts.conf` to match your infrastructure:

```bash
# Your infrastructure services
10.YOUR.IP.40  harbor    harbor.company.local
10.YOUR.IP.41  vault     vault.company.local

# Your Docker hosts
10.YOUR.IP.101 docker-mgr-01 docker-mgr-01.company.local
```

### HA DNS Setup

Deploy dnsmasq on 2+ servers with identical configurations:

```bash
# Primary DNS: 10.20.30.10
# Secondary DNS: 10.20.30.11

# On both servers:
sudo cp dnsmasq.conf /etc/dnsmasq.conf
sudo cp hosts.conf /etc/dnsmasq.d/hosts.conf

# Update Docker daemon.json on all hosts:
{
  "dns": ["10.20.30.10", "10.20.30.11"]
}
```

## NTP Configuration

### With GPS Receiver

If you have a GPS receiver for high accuracy:

```conf
# In chrony.conf.server
refclock SHM 0 refid GPS precision 1e-1
```

### Without GPS (Local Reference)

For air-gap without GPS (less accurate):

```conf
# In chrony.conf.server
local stratum 8
```

### Monitoring NTP Drift

```bash
# Check current offset
chronyc tracking

# Should show:
# System time: 0.000xxx seconds fast/slow of NTP time
```

Create monitoring script (run via cron):

```bash
#!/bin/bash
OFFSET=$(chronyc tracking | grep "System time" | awk '{print $4}')
# Alert if offset > 100ms
```

## PKI Configuration

### Root CA Setup

**CRITICAL SECURITY NOTES:**
1. Create Root CA on OFFLINE machine
2. Store private key in encrypted location
3. Never put Root CA online
4. Create backups on encrypted USB drives
5. Store in physical safe

### Certificate Lifecycle

```
Create Root CA (once, offline)
    ↓
Create Intermediate CA (once, signs server certs)
    ↓
Create Server Certificates (90-day validity)
    ↓
Renew before 30 days expiry
```

### Renewing Certificates

```bash
# 30 days before expiry, renew certificate
./create-server-cert.sh harbor.company.local

# Deploy new certificate
# Restart service
sudo systemctl restart harbor
```

## Package Repositories

### APT Mirror (Ubuntu/Debian)

```bash
# On external machine with internet
sudo apt-get install apt-mirror

# Edit /etc/apt/mirror.list
# Run sync
sudo apt-mirror

# Package for transfer
tar czf ubuntu-mirror.tar.gz /var/spool/apt-mirror/

# In air-gap, extract and serve via nginx
sudo nginx -c nginx-apt-mirror.conf
```

### YUM Mirror (RHEL/CentOS)

```bash
# On external machine
sudo dnf install yum-utils createrepo

# Sync repositories
sudo reposync --repo=baseos --download-metadata --newest-only -p /var/www/html/centos-mirror

# Create metadata
sudo createrepo /var/www/html/centos-mirror/baseos

# Serve via nginx in air-gap
```

## Troubleshooting

### DNS Not Resolving

```bash
# Check dnsmasq status
sudo systemctl status dnsmasq

# Check logs
sudo tail -f /var/log/dnsmasq.log

# Test resolution
dig @localhost harbor.company.local
nslookup harbor.company.local localhost

# Verify hosts.conf syntax
cat /etc/dnsmasq.d/hosts.conf
```

### NTP Not Synchronizing

```bash
# Check chrony status
sudo systemctl status chronyd

# Check sources
chronyc sources
# Look for ^* (selected source) or ^+ (candidate)

# Manual sync (for testing)
sudo chronyc makestep

# Check firewall
sudo firewall-cmd --list-ports
# NTP uses UDP port 123
```

### Certificate Issues

```bash
# Verify certificate
openssl x509 -in certificate.pem -text -noout

# Check expiry
openssl x509 -in certificate.pem -noout -dates

# Verify chain
openssl verify -CAfile ca-chain.cert.pem certificate.pem

# Test TLS connection
openssl s_client -connect harbor.company.local:443 -CAfile ca-chain.cert.pem
```

## Security Best Practices

### DNS
- Use firewall to restrict DNS queries to internal network only
- Enable query logging for security audits
- Regular backups of hosts.conf

### NTP
- Restrict NTP client access with `allow` directive
- Monitor for large time jumps (potential attack)
- Use multiple NTP servers (minimum 3)

### PKI
- **Root CA private key MUST be offline**
- Use strong passphrases (20+ characters)
- Encrypt all backups
- Regular audit of issued certificates
- Implement CRL (Certificate Revocation List)
- Monitor certificate expiry dates

## Monitoring

### DNS Health Check

```bash
# Test from client
for host in harbor vault gitlab; do
  echo -n "$host: "
  nslookup $host.company.local dns-server-ip
done
```

### NTP Health Check

```bash
# Check all NTP servers
for server in ntp1 ntp2 ntp3; do
  echo "Testing $server:"
  chronyc sources | grep $server
done
```

### Certificate Expiry Check

```bash
# Check all certificates
for cert in /etc/ssl/certs/*.pem; do
  echo "$cert:"
  openssl x509 -in "$cert" -noout -enddate
done
```

## Support

- **Book**: Module 2, Section 2.4
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Issues**: Report bugs via GitHub Issues

## License

MIT License - See repository root for details
