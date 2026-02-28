# Module 02, Section 2.5: Automation with Ansible

Ansible playbooks and roles for automated Docker deployment in air-gapped environments.

## Structure

```
section-2.5/
├── ansible.cfg                          # Ansible configuration
├── inventory/
│   └── production/
│       ├── hosts.yml                    # Inventory file
│       └── group_vars/
│           ├── all.yml                  # Global variables
│           └── docker_hosts.yml         # Docker-specific variables
├── playbooks/
│   ├── site.yml                         # Master playbook
│   ├── 01-prepare-hosts.yml             # Host preparation
│   └── 02-install-docker.yml            # Docker installation
└── roles/
    └── docker-install/
        └── tasks/
            └── main.yml                 # Docker installation tasks
```

## Prerequisites

### On Control Node (Ansible host)

```bash
# Install Ansible
pip install ansible

# Or from package manager
sudo apt-get install ansible  # Ubuntu/Debian
sudo dnf install ansible      # RHEL/CentOS
```

### On Target Hosts

- SSH access configured
- Python 3 installed
- Sudo privileges for ansible user

## Quick Start

### 1. Configure Inventory

Edit `inventory/production/hosts.yml` with your infrastructure:

```yaml
docker_hosts:
  hosts:
    docker-01:
      ansible_host: 10.20.30.101
    docker-02:
      ansible_host: 10.20.30.102
```

### 2. Configure Variables

Edit `inventory/production/group_vars/all.yml`:

```yaml
dns_servers:
  - 10.YOUR.DNS.IP1
  - 10.YOUR.DNS.IP2
  
ntp_servers:
  - ntp1.your.domain
```

### 3. Run Playbooks

```bash
# Dry run (check mode)
ansible-playbook playbooks/site.yml --check

# Real deployment
ansible-playbook playbooks/site.yml

# Deploy to specific hosts
ansible-playbook playbooks/site.yml --limit docker-01

# Deploy to specific group
ansible-playbook playbooks/site.yml --limit docker_managers
```

## Usage Examples

### Deploy to Single Host

```bash
ansible-playbook playbooks/site.yml --limit docker-01
```

### Deploy with Step Confirmation

```bash
ansible-playbook playbooks/site.yml --step
```

### Deploy from Specific Task

```bash
ansible-playbook playbooks/site.yml \
  --start-at-task="Install Docker packages"
```

### Parallel Deployment

```bash
# Deploy to 20 hosts simultaneously
ansible-playbook playbooks/site.yml --forks 20
```

## Available Playbooks

### site.yml
Master playbook that runs all deployment steps in order.

### 01-prepare-hosts.yml
- Updates hostname
- Configures /etc/hosts
- Installs prerequisites
- Copies offline bundle
- Extracts bundle

### 02-install-docker.yml
- Creates local repository (APT/YUM)
- Installs Docker packages
- Starts Docker service
- Adds users to docker group

## Customization

### Adding New Hosts

```yaml
# In inventory/production/hosts.yml
docker_workers:
  hosts:
    docker-new-host:
      ansible_host: 10.20.30.120
```

### Changing Docker Configuration

```yaml
# In inventory/production/group_vars/docker_hosts.yml
docker_daemon_config:
  log-driver: "json-file"  # Change from local
  log-opts:
    max-size: "100m"       # Increase log size
```

### Using Different Bundle

```yaml
# In inventory/production/group_vars/docker_hosts.yml
docker_bundle_path: files/docker-offline-v2.0.tar.gz
```

## Testing

### Pre-deployment Verification

```bash
# Test connectivity
ansible -i inventory/production docker_hosts -m ping

# Check disk space
ansible -i inventory/production docker_hosts \
  -m shell -a "df -h /var"

# Verify Python
ansible -i inventory/production docker_hosts \
  -m shell -a "python3 --version"
```

### Post-deployment Verification

```bash
# Check Docker version
ansible -i inventory/production docker_hosts \
  -m shell -a "docker --version"

# Check Docker service
ansible -i inventory/production docker_hosts \
  -m shell -a "systemctl status docker"

# Run test container
ansible -i inventory/production docker_hosts \
  -m shell -a "docker run --rm alpine:3.18 echo 'Test'"
```

## Troubleshooting

### SSH Connection Issues

```bash
# Test SSH manually
ssh ansible@10.20.30.101

# Use password auth (if keys not set up)
ansible-playbook playbooks/site.yml --ask-pass

# Use different user
ansible-playbook playbooks/site.yml -u root
```

### Python Not Found

```bash
# Specify Python interpreter
ansible-playbook playbooks/site.yml \
  -e "ansible_python_interpreter=/usr/bin/python3"
```

### Sudo Password Required

```bash
# Prompt for sudo password
ansible-playbook playbooks/site.yml --ask-become-pass
```

### Playbook Failed Mid-way

```bash
# Continue from specific host
ansible-playbook playbooks/site.yml --limit @logs/retry/site.retry
```

## Best Practices

### 1. Always Test in Staging First

```bash
# Deploy to staging environment
ansible-playbook -i inventory/staging playbooks/site.yml

# Then deploy to production
ansible-playbook -i inventory/production playbooks/site.yml
```

### 2. Use Check Mode

```bash
# See what would change
ansible-playbook playbooks/site.yml --check --diff
```

### 3. Limit Parallel Execution

```bash
# For air-gap with limited bandwidth
ansible-playbook playbooks/site.yml --forks 5
```

### 4. Keep Logs

```bash
# Logs automatically saved to logs/ansible.log
tail -f logs/ansible.log
```

### 5. Use Tags

```yaml
# In playbooks, add tags:
tasks:
  - name: Install Docker
    include_role:
      name: docker-install
    tags: docker

# Run only tagged tasks:
# ansible-playbook playbooks/site.yml --tags docker
```

## Advanced Features

### Vault for Secrets

```bash
# Create encrypted vars file
ansible-vault create inventory/production/group_vars/vault.yml

# Run with vault
ansible-playbook playbooks/site.yml --ask-vault-pass
```

### Dynamic Inventory

```bash
# If using dynamic inventory
ansible-playbook playbooks/site.yml -i dynamic_inventory.py
```

### Callbacks for Better Output

```ini
# In ansible.cfg
[defaults]
callbacks_enabled = profile_tasks, timer

# Shows task execution time
```

## Support

- **Book**: Module 2, Section 2.5
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Issues**: Report bugs via GitHub Issues

## License

MIT License - See repository root for details
