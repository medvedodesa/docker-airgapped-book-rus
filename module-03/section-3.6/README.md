# Module 03, Section 3.6: RBAC & Multi-tenancy

Scripts and configurations for Harbor access control and multi-tenancy management.

## Files

### rbac-setup.sh
Automated RBAC configuration:
- Create multiple projects
- Set quotas and policies
- Add users to projects
- Assign roles
- Configuration summary

### robot-account-manager.sh
Robot account management:
- Create robot accounts
- List existing robots
- Delete robots
- Rotate credentials
- Interactive menus

### ldap-config.yml
LDAP integration examples:
- Basic LDAP configuration
- Active Directory setup
- OpenLDAP example
- FreeIPA example
- Group-based access
- Troubleshooting guide

### quota-monitor.sh
Storage quota monitoring:
- Check all project quotas
- Alert on threshold breach
- Show top repositories
- Integration with alerting

## Quick Start

### Setup RBAC

```bash
chmod +x rbac-setup.sh

# Set credentials
export HARBOR_URL="https://harbor.company.local"
export HARBOR_USER="admin"
export HARBOR_PASS="your-password"

# Run setup
./rbac-setup.sh
```

### Manage Robot Accounts

```bash
chmod +x robot-account-manager.sh

# Create robot account
./robot-account-manager.sh create

# List robots
./robot-account-manager.sh list

# Rotate credentials
./robot-account-manager.sh rotate

# Delete robot
./robot-account-manager.sh delete
```

### Monitor Quotas

```bash
chmod +x quota-monitor.sh

# Check quotas (80% threshold)
./quota-monitor.sh

# Custom threshold (90%)
./quota-monitor.sh --threshold 90

# With alerting
./quota-monitor.sh --threshold 80 --alert-command "./send-slack-alert.sh"

# Run via cron (daily check)
0 9 * * * /opt/scripts/quota-monitor.sh --threshold 80
```

## Project Structure

### Create Projects

**Via Web UI:**
```
Projects → New Project
- Name: team-billing
- Access Level: Private
- Storage Quota: 100 GB
```

**Via Script:**
```bash
# Edit rbac-setup.sh to define projects
PROJECTS=(
    ["team-billing"]="false:107374182400"   # private:100GB
    ["team-analytics"]="false:107374182400"
)
```

### Project Naming Conventions

**By Team:**
```
team-billing/
team-analytics/
team-devops/
```

**By Environment:**
```
prod-billing/
staging-billing/
dev-billing/
```

**By Function:**
```
shared-infra/
library/
monitoring/
```

## Role Management

### Role Hierarchy

```
1. Project Admin (role_id=1)
   - Full control
   - Manage members
   - Delete project

2. Maintainer (role_id=4)
   - Push/pull images
   - Delete tags
   - Scan images

3. Developer (role_id=2)
   - Push/pull images
   - Scan images

4. Guest (role_id=3)
   - Pull only
   - View metadata

5. Limited Guest (role_id=5)
   - Pull specific tags only
```

### Add User to Project

**Via API:**
```bash
PROJECT_ID=$(curl -s -u admin:password \
  "https://harbor.company.local/api/v2.0/projects?name=team-billing" | \
  jq -r '.[0].project_id')

curl -X POST -u admin:password \
  -H "Content-Type: application/json" \
  "https://harbor.company.local/api/v2.0/projects/$PROJECT_ID/members" \
  -d '{
    "role_id": 2,
    "member_user": {"username": "alice"}
  }'
```

## LDAP Integration

### Configure LDAP

**1. Edit harbor.yml:**
```bash
# Copy example configuration
cp ldap-config.yml harbor.yml.ldap-section

# Edit harbor.yml with LDAP settings
vim harbor.yml
```

**2. Test LDAP connection:**
```
Harbor Web UI → Administration → Configuration → Authentication
- Click "Test LDAP Server"
- Enter test credentials
```

**3. Restart Harbor:**
```bash
cd /data/harbor
docker-compose restart
```

### LDAP Group Mapping

**Automatic admin privileges:**
```yaml
ldap:
  group_admin_dn: cn=harbor-admins,ou=groups,dc=company,dc=local
```

**All members of this group become Harbor admins**

### Troubleshooting LDAP

```bash
# Enable debug logging
log:
  level: debug

# Check logs
docker logs harbor-core | grep -i ldap

# Common issues:
# - Connection refused: Check firewall
# - User not found: Verify base_dn and filter
# - Auth failed: Check user password
# - Group not working: Verify group_membership_attribute
```

## Robot Accounts

### Create for CI/CD

```bash
./robot-account-manager.sh create

# Input:
Project name: team-billing
Robot account name: gitlab-ci
Description: GitLab CI/CD pipeline
Expiration (days): 365
Permissions: 2 (Pull + Push)

# Output:
Name: robot$team-billing+gitlab-ci
Token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...
```

### Use in CI/CD

**GitLab CI:**
```yaml
# .gitlab-ci.yml
variables:
  HARBOR_ROBOT_USERNAME: robot$team-billing+gitlab-ci
  HARBOR_ROBOT_TOKEN: <token-from-ci-variable>

before_script:
  - echo "$HARBOR_ROBOT_TOKEN" | docker login harbor.company.local \
      -u "$HARBOR_ROBOT_USERNAME" --password-stdin
```

**Jenkins:**
```groovy
withCredentials([usernamePassword(
  credentialsId: 'harbor-robot',
  usernameVariable: 'HARBOR_USER',
  passwordVariable: 'HARBOR_TOKEN'
)]) {
  sh 'docker login ${HARBOR_URL} -u ${HARBOR_USER} -p ${HARBOR_TOKEN}'
}
```

### Rotate Credentials

```bash
./robot-account-manager.sh rotate

# Creates new robot with -new suffix
# Update CI/CD with new credentials
# Delete old robot after verification
```

## Quota Management

### Set Quotas

**Per Project:**
```bash
# Via API
curl -X PUT -u admin:password \
  -H "Content-Type: application/json" \
  "https://harbor.company.local/api/v2.0/projects/$PROJECT_ID" \
  -d '{"metadata": {"storage_limit": "107374182400"}}'
```

**Default for New Projects:**
```yaml
# In harbor.yml
quota_per_project_enable: true
storage_per_project: 107374182400  # 100GB
```

### Monitor Usage

```bash
# Check current usage
./quota-monitor.sh

# Set up daily monitoring
crontab -e
0 9 * * * /opt/scripts/quota-monitor.sh --threshold 80 2>&1 | mail -s "Harbor Quota Report" admin@company.com
```

### Quota Cleanup

**When quota exceeded:**

1. **Check top consumers:**
```bash
# Via Web UI:
Projects → [Project] → Repositories
Sort by size
```

2. **Delete old tags:**
```
Projects → [Project] → Configuration → Tag Retention
Rule: Retain last 10 tags
```

3. **Run garbage collection:**
```
Administration → Garbage Collection → Run Now
```

4. **Request quota increase:**
```bash
# If legitimately needed
curl -X PUT -u admin:password \
  "https://harbor.company.local/api/v2.0/projects/$PROJECT_ID" \
  -d '{"metadata": {"storage_limit": "214748364800"}}'  # 200GB
```

## Best Practices

### Access Control

1. **Least Privilege**
   - Start with Guest role
   - Promote to Developer when needed
   - Limit Project Admin role

2. **Use Groups**
   - LDAP group-based access
   - Easier management at scale
   - Automatic provisioning

3. **Robot Accounts**
   - One per pipeline
   - Short expiration (90-365 days)
   - Regular rotation

### Project Organization

1. **Clear Naming**
   - team-* or env-* prefixes
   - Descriptive names
   - Consistent convention

2. **Appropriate Quotas**
   - Start conservative
   - Monitor usage
   - Adjust as needed

3. **Security Policies**
   - Enable auto-scan
   - Prevent vulnerabilities
   - Content trust for production

### Monitoring

1. **Daily Quota Checks**
   - Automated monitoring
   - Alert before quota hit
   - Proactive cleanup

2. **Access Auditing**
   - Review members quarterly
   - Remove inactive users
   - Verify robot accounts

3. **Usage Reports**
   - Track growth trends
   - Plan capacity
   - Identify optimization opportunities

## Troubleshooting

### User Cannot Login

```bash
# Check auth mode
# Harbor UI → Administration → Configuration
# Should show: LDAP Auth or OIDC Auth

# Test LDAP
docker logs harbor-core | grep -i ldap | tail -20

# Verify user exists in LDAP
ldapsearch -x -H ldap://ldap.company.local \
  -D "cn=admin,dc=company,dc=local" \
  -w password \
  -b "ou=users,dc=company,dc=local" \
  "(uid=alice)"
```

### Robot Account Not Working

```bash
# Verify robot exists
./robot-account-manager.sh list

# Check if token expired
# Web UI → Projects → Robot Accounts
# Look for "Expires" date

# Test login manually
docker login harbor.company.local \
  -u 'robot$project+name' \
  -p 'token'
```

### Quota Exceeded

```bash
# Check current usage
./quota-monitor.sh

# Run garbage collection
# Web UI → Administration → Garbage Collection → Run Now

# Or increase quota temporarily
curl -X PUT -u admin:password \
  "https://harbor.company.local/api/v2.0/projects/$PROJECT_ID" \
  -d '{"metadata": {"storage_limit": "214748364800"}}'
```

## Next Steps

After RBAC setup:
1. Configure replication (Section 3.7)
2. Setup operations & maintenance (Section 3.8)
3. Document access procedures
4. Train team on workflows

## Support

- **Book**: Module 3, Section 3.6
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Harbor RBAC Docs**: https://goharbor.io/docs/latest/administration/managing-users/

## License

MIT License - See repository root for details
