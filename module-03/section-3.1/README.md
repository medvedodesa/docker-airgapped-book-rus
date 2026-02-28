# Module 03, Section 3.1: Why Harbor for Air-Gap

Supporting materials for understanding and evaluating Harbor as container registry solution for air-gapped environments.

## Files

### registry-comparison.md
Comprehensive comparison of container registry solutions:
- Docker Registry vs Harbor vs Quay vs Nexus
- Feature matrix
- Use case recommendations
- Migration paths
- TCO analysis

### harbor-resource-calculator.sh
Interactive script to calculate required resources for Harbor deployment:
- Storage calculation with deduplication
- CPU and RAM requirements
- Network bandwidth estimation
- Hardware recommendations
- Cost estimation

## Usage

### Comparing Registry Solutions

Read `registry-comparison.md` to understand:
- Which registry solution fits your needs
- Feature trade-offs
- Cost implications
- Migration strategies

### Calculating Resources

```bash
chmod +x harbor-resource-calculator.sh
./harbor-resource-calculator.sh

# Answer prompts:
Number of Docker hosts: 50
Number of developers/users: 20
Average images per host: 10
Average image size (MB): 500
Deployment type (single/ha): single

# Get detailed resource requirements
```

### Example Calculations

**Small Deployment (20 hosts, 10 users):**
```
Storage: ~100 GB
CPU: 4 cores
RAM: 8 GB
Cost: ~$6,000
```

**Medium Deployment (100 hosts, 50 users):**
```
Storage: ~500 GB
CPU: 8 cores
RAM: 12 GB
Cost: ~$12,000
```

**Large HA Deployment (500 hosts, 200 users):**
```
Storage: 2 TB (shared)
CPU: 12 cores per node (3 nodes)
RAM: 16 GB per node (3 nodes)
Cost: ~$45,000
```

## Decision Guide

### When to Use Harbor

Use Harbor if you have:
- Production air-gapped environment
- More than 10 Docker hosts
- Compliance requirements (PCI DSS, SOC 2)
- Need for vulnerability scanning
- Multi-tenant requirements
- Geographic distribution

### When NOT to Use Harbor

Consider simpler alternatives if:
- Development/testing only
- Less than 5 Docker hosts
- No compliance requirements
- Very limited resources
- Temporary deployment

### Feature Priorities

**Must-Have Features:**
1. Vulnerability scanning (compliance)
2. RBAC (multi-tenant)
3. HTTPS/TLS (security)
4. Audit logging (compliance)

**Nice-to-Have Features:**
1. Image signing (high-security environments)
2. Replication (multi-site)
3. Quota management (resource control)
4. Webhook integration (automation)

## Architecture Planning

### Single-Node Architecture

```
Harbor Node
├── Nginx (proxy)
├── Core (API)
├── Portal (UI)
├── Registry (storage)
├── JobService (tasks)
├── Trivy (scanning)
├── PostgreSQL (embedded)
└── Redis (embedded)

Resources: 4-8 cores, 8-16 GB RAM, 200 GB-2 TB disk
```

### HA Architecture

```
Load Balancer
    ├── Harbor Node 1
    ├── Harbor Node 2
    └── Harbor Node 3
         ↓
External Services:
├── PostgreSQL Cluster (3 nodes)
├── Redis Sentinel (3 nodes)
└── Shared Storage (NFS/S3)

Resources: 
- 3x Harbor nodes (8 cores, 16 GB RAM each)
- 3x PostgreSQL (4 cores, 8 GB RAM each)
- 3x Redis (2 cores, 2 GB RAM each)
- Shared storage: 500 GB - 5 TB
```

## Common Questions

### Q: Can I use Harbor with less than 8GB RAM?

A: Yes, minimum 4GB, but performance will suffer with many concurrent operations. Not recommended for production.

### Q: Do I need HA for 50 hosts?

A: No, single-node is sufficient for up to 100 hosts unless you have specific SLA requirements.

### Q: What storage backend should I use?

A: 
- Single-node: Local disk (ext4/xfs)
- HA: S3-compatible object storage (MinIO, Ceph)

### Q: How much does Harbor cost?

A: Harbor is free (Apache 2.0 license). Optional paid support available from VMware.

### Q: Can I migrate from Docker Registry to Harbor?

A: Yes, see migration section in `registry-comparison.md`

## Next Steps

After evaluating Harbor:
1. Read Section 3.2: Offline Installation
2. Plan your deployment (single vs HA)
3. Prepare prerequisites (Section 3.2.1)
4. Download offline installer (Section 3.2.2)

## Support

- **Book**: Module 3, Section 3.1
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Harbor Docs**: https://goharbor.io/docs/
- **CNCF Slack**: #harbor channel

## License

MIT License - See repository root for details
