# Container Registry Comparison for Air-Gapped Environments

This document provides detailed comparison of container registry solutions suitable for air-gapped Docker infrastructure.

## Quick Comparison Matrix

| Feature | Docker Registry | Harbor | Quay | Nexus | Verdict |
|---------|----------------|--------|------|-------|---------|
| **Web UI** | No | Yes | Yes | Yes | Harbor+ |
| **Vulnerability Scanning** | No | Yes (Trivy) | Yes (Clair) | Basic | Harbor+ |
| **Image Signing** | No | Yes (Notary) | Yes | No | Harbor/Quay |
| **RBAC** | No | Yes | Yes | Yes | Harbor+ |
| **Replication** | No | Yes | Yes | Yes | All equal |
| **LDAP/OIDC** | No | Yes | Yes | Yes | All equal |
| **Audit Logging** | Basic | Comprehensive | Yes | Yes | Harbor+ |
| **Air-gap Documentation** | Minimal | Excellent | Limited | Limited | Harbor++ |
| **Resource Usage** | Low (100MB) | Medium (4GB) | High (8GB+) | High (8GB+) | Registry+ |
| **Deployment Complexity** | Simple | Medium | Complex | Complex | Registry+ |
| **License** | Apache 2.0 | Apache 2.0 | Apache 2.0/Paid | Apache 2.0/Paid | All equal |
| **Best For** | Dev/Test | **Production** | Large Enterprise | Multi-format |

## Detailed Analysis

### Docker Registry

**Pros:**
- Simplest deployment (single binary)
- Minimal resource usage
- Official Docker solution
- Well-documented API

**Cons:**
- No UI (CLI/API only)
- No vulnerability scanning
- No RBAC
- No image signing
- No replication
- Basic logging
- Not suitable for production air-gap

**Use Cases:**
- Development environments
- Small teams (< 5 people)
- Temporary/disposable registries
- When compliance is not required

**Resource Requirements:**
- CPU: 1 core
- RAM: 100-200 MB
- Disk: Depends on images

### Harbor

**Pros:**
- Complete feature set for production
- Excellent air-gap documentation
- Trivy integration (best-in-class scanner)
- Notary for image signing
- Full RBAC with projects
- Multi-site replication
- Comprehensive audit logs
- Robot accounts for CI/CD
- Active community (CNCF graduated)
- All features in open source

**Cons:**
- More complex deployment
- Requires PostgreSQL + Redis
- Higher resource usage than basic registry

**Use Cases:**
- Production air-gapped environments
- Enterprise deployments
- Multi-tenant scenarios
- Compliance-heavy industries
- Geographic distribution

**Resource Requirements:**
- CPU: 4-8 cores
- RAM: 8-16 GB
- Disk: 200 GB - 2 TB

### Quay

**Pros:**
- RedHat backing
- Good feature set
- Geo-replication
- Clair vulnerability scanning

**Cons:**
- Complex offline installation
- Limited air-gap documentation
- Heavier than Harbor
- Some features require paid license

**Use Cases:**
- RedHat ecosystem (OpenShift)
- Large enterprises
- When already using RedHat products

**Resource Requirements:**
- CPU: 8+ cores
- RAM: 16+ GB
- Disk: 500 GB+

### Nexus Repository

**Pros:**
- Universal artifact manager
- Supports Docker + Maven + npm + PyPI
- Good for consolidating all artifacts
- Mature product

**Cons:**
- Docker support is secondary
- Weaker Docker-specific features
- Overkill for pure Docker use
- Complex configuration

**Use Cases:**
- Organizations needing multi-format repository
- Java/Maven shops
- When consolidating all artifacts in one place

**Resource Requirements:**
- CPU: 4-8 cores
- RAM: 8-16 GB
- Disk: 500 GB - 5 TB

## Decision Tree

```
Do you only need Docker images?
├─ Yes → Continue
│   │
│   Is this for production?
│   ├─ Yes → Continue
│   │   │
│   │   Do you need compliance/security features?
│   │   ├─ Yes → HARBOR (recommended)
│   │   └─ No → Harbor or Docker Registry
│   │
│   └─ No (dev/test) → Docker Registry
│
└─ No (need Maven, npm, etc.) → Nexus Repository
```

## Recommendation for Air-Gap

**For 95% of air-gapped Docker deployments: Harbor**

Reasons:
1. Best air-gap documentation
2. All necessary features in open source
3. Active community support
4. Proven in production (Google, AWS use it)
5. Reasonable resource requirements
6. Excellent security features

**Exceptions:**
- Very small deployments (< 10 hosts, no compliance): Docker Registry
- RedHat-only shops: Quay
- Need multi-format repository: Nexus

## Migration Paths

### From Docker Registry to Harbor

```bash
# 1. Pull all images from Docker Registry
docker images registry.company.local/* --format "{{.Repository}}:{{.Tag}}" > images.txt

# 2. For each image:
while read image; do
  docker pull $image
  new_image=$(echo $image | sed 's/registry.company.local/harbor.company.local/')
  docker tag $image $new_image
  docker push $new_image
done < images.txt
```

### From Quay to Harbor

Harbor supports direct replication from Quay:
1. Configure Quay as replication endpoint in Harbor
2. Create replication rule
3. Trigger replication
4. Verify all images copied

## Cost Analysis

### Total Cost of Ownership (3 years, 100 hosts)

| Solution | Hardware | Licensing | Operations | Total |
|----------|----------|-----------|------------|-------|
| Docker Registry | $5K | $0 | $30K* | $35K |
| Harbor | $10K | $0 | $25K | $35K |
| Quay (OSS) | $15K | $0 | $35K | $50K |
| Nexus (OSS) | $15K | $0 | $30K | $45K |

*Higher ops cost due to lack of features (manual vulnerability checks, etc.)

## Support Options

### Harbor
- Community: Free (GitHub, Slack)
- VMware Tanzu: Paid support available
- Documentation: Excellent

### Docker Registry
- Community: Free (GitHub)
- Docker Inc: Paid support
- Documentation: Good for basic usage

### Quay
- RedHat: Paid support required for production
- Community: Limited
- Documentation: Good

### Nexus
- Sonatype: Paid support available
- Community: Free
- Documentation: Good

## Conclusion

Harbor is the clear winner for production air-gapped Docker environments due to:
- Complete feature set
- Excellent air-gap support
- All features in open source
- Active community
- Proven track record

Only consider alternatives if you have specific requirements not met by Harbor.
