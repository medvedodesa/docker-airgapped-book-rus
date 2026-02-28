# Module 03, Section 3.7: Replication

Scripts and guides for Harbor replication between sites.

## Files

### replication-setup.sh
Automated replication configuration:
- Add destination registry
- Create replication rule
- Configure triggers (event/scheduled/manual)
- Set filters and policies
- Test replication

### dr-failover.sh
Disaster recovery management:
- Check sync status
- Perform failover to DR site
- Failback to primary
- DNS update guidance
- Replication control

### replication-monitor.sh
Replication monitoring:
- Check all policies
- Detect failures
- Alert on stale replications
- Integration with alerting

## Quick Start

### Setup Replication

```bash
chmod +x replication-setup.sh

# Set source Harbor
export SOURCE_HARBOR="https://harbor-moscow.company.local"
export SOURCE_USER="admin"
export SOURCE_PASS="your-password"

# Run interactive setup
./replication-setup.sh

# Follow prompts:
# 1. Destination Harbor URL
# 2. Destination credentials
# 3. Replication rule settings
# 4. Test replication
```

### Monitor Replication

```bash
chmod +x replication-monitor.sh

# Check status
export HARBOR_URL="https://harbor.company.local"
./replication-monitor.sh

# With alerting
./replication-monitor.sh --alert-command "./send-alert.sh"

# Cron job (every 30 minutes)
*/30 * * * * /opt/scripts/replication-monitor.sh
```

### DR Management

```bash
chmod +x dr-failover.sh

# Check sync status
./dr-failover.sh check

# Perform failover (primary failed)
./dr-failover.sh failover

# Failback (primary restored)
./dr-failover.sh failback
```

## Replication Patterns

### Hub-and-Spoke

Central Harbor distributes to regional sites:

```
Moscow (Hub) → Saint-Petersburg (Spoke)
             → Novosibirsk (Spoke)
             → Kazan (Spoke)
```

**Setup:**
```bash
# On Moscow Harbor, create rules for each spoke
./replication-setup.sh  # Destination: SPb
./replication-setup.sh  # Destination: Novosibirsk
./replication-setup.sh  # Destination: Kazan
```

### Active-Passive DR

Primary replicates to DR for disaster recovery:

```
Primary (Active) → DR (Passive, standby)
```

**Setup:**
```bash
# On Primary Harbor
./replication-setup.sh
# Destination: DR Harbor
# Trigger: Event-based (real-time)
# Replicate deletions: Yes
```

### Multi-Site Mesh

Bidirectional replication between peers:

```
Moscow ←→ Saint-Petersburg
  ↕           ↕
Kazan  ←→  Novosibirsk
```

**Setup:** Configure replication in both directions for each pair.

## Configuration Examples

### Event-Based (Real-Time)

```
Trigger: Event-based
Events: On push, On tag deletion
Use case: DR, critical projects
```

### Scheduled (Nightly)

```
Trigger: Scheduled
Cron: 0 2 * * * (2 AM daily)
Use case: Remote sites, bandwidth optimization
```

### Manual

```
Trigger: Manual
Use case: Ad-hoc sync, testing
```

## Filtering

### By Project

```bash
# Replicate only specific projects
Projects: library, team-billing, shared-infra
```

### By Tag Pattern

```bash
# Replicate only production tags
Tag filter: prod-*, v[0-9]*
Exclude: dev-*, test-*
```

### By Labels

```bash
# Only images with specific label
Label filter: replicate=true
```

## Disaster Recovery

### Pre-Disaster Checklist

- [ ] Replication configured and tested
- [ ] DR site regularly synchronized
- [ ] DR credentials documented
- [ ] Failover procedure documented
- [ ] Team trained on DR process
- [ ] Quarterly DR drills scheduled

### Failover Procedure

**1. Verify disaster:**
```bash
./dr-failover.sh check

# Should show:
# Primary: DOWN
# DR: UP
# Sync: Recent
```

**2. Perform failover:**
```bash
./dr-failover.sh failover

# Script will:
# - Verify DR is ready
# - Guide DNS updates
# - Disable primary replication
```

**3. Update DNS:**
```bash
# Option A: DNS server
# Change: harbor.company.local → DR IP

# Option B: /etc/hosts on each Docker host
echo "<dr-ip> harbor.company.local" >> /etc/hosts
```

**4. Verify:**
```bash
# From Docker hosts
docker login harbor.company.local
docker pull harbor.company.local/library/alpine:3.18
```

### Failback Procedure

**When primary is restored:**

```bash
# 1. Check primary is accessible
./dr-failover.sh check

# 2. Sync DR → Primary (reverse replication)
# Setup temporary reverse replication rule

# 3. Perform failback
./dr-failover.sh failback

# 4. Restore DNS to primary

# 5. Verify operations

# 6. Remove reverse replication
```

## Bandwidth Optimization

### Schedule During Off-Peak

```bash
# Cron schedule for night sync
Trigger: Scheduled
Cron: 0 2 * * *  # 2 AM daily
```

### Use Selective Filters

```bash
# Only replicate production images
Tag filter: prod-*, v*
Projects: critical-apps, shared-infra
```

### Monitor Bandwidth

```bash
# Check replication task durations
curl -u admin:password \
  "https://harbor.company.local/api/v2.0/replication/executions" | \
  jq -r '.[] | "Duration: \((.end_time|fromdateiso8601) - (.start_time|fromdateiso8601))s"'
```

## Troubleshooting

### Replication Failed

```bash
# Check logs
./replication-monitor.sh

# View detailed errors
# Harbor UI → Replications → [Rule] → Executions → Failed Tasks

# Common issues:
# 1. Network connectivity
curl -v https://destination-harbor:443

# 2. Authentication
# Harbor UI → Administration → Registries → Test Connection

# 3. Quota exceeded
# Check destination project quotas
```

### Replication Stuck

```bash
# Check if in progress
curl -u admin:password \
  "https://harbor.company.local/api/v2.0/replication/executions" | \
  jq '.[] | select(.status=="InProgress")'

# If stuck for long time, may need to restart Harbor
cd /data/harbor
docker-compose restart harbor-jobservice
```

### High Replication Lag

```bash
# Check last successful replication
./dr-failover.sh check

# If lag > acceptable:
# 1. Check network bandwidth
# 2. Check destination Harbor load
# 3. Consider scheduled instead of event-based
# 4. Add selective filters
```

## Monitoring

### Daily Checks

```bash
# Automated monitoring (cron)
0 9 * * * /opt/scripts/replication-monitor.sh --alert-command "/opt/scripts/send-slack.sh"
```

### Metrics to Track

- **Success Rate:** % successful replications
- **Lag Time:** Time between push and replication complete
- **Failure Count:** Number of failed replications
- **Bandwidth Usage:** Data transferred
- **Sync Status:** Repository count comparison

### Alerts

**Setup alerts for:**
- Replication failure
- Replication lag > 24 hours
- Sync percentage < 95%
- Destination unavailable

## Best Practices

### Security

1. **Dedicated Replication Accounts**
   - Not admin accounts
   - Minimal permissions (Maintainer/Developer)
   - Regular credential rotation

2. **TLS/SSL**
   - Always use HTTPS
   - Verify certificates
   - Use internal CA

3. **Network Isolation**
   - Dedicated replication VLAN
   - Firewall rules
   - Rate limiting if needed

### Reliability

1. **Multiple DR Sites**
   - Geographic distribution
   - Not single point of failure
   - Different network providers

2. **Regular Testing**
   - Quarterly DR drills
   - Automated failover tests
   - Documented procedures

3. **Monitoring**
   - Continuous monitoring
   - Alert on failures
   - Track metrics

### Performance

1. **Bandwidth Management**
   - Schedule during off-peak
   - Use compression
   - Selective replication

2. **Resource Allocation**
   - Adequate network capacity
   - Sufficient storage on destination
   - Job worker scaling

## Next Steps

After replication setup:
1. Setup monitoring and alerts
2. Document DR procedures
3. Train team on failover
4. Schedule regular DR drills
5. Review Section 3.8 for operations

## Support

- **Book**: Module 3, Section 3.7
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Harbor Replication Docs**: https://goharbor.io/docs/latest/administration/configuring-replication/

## License

MIT License - See repository root for details
