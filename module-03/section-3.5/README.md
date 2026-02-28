# Module 03, Section 3.5: Image Signing & Content Trust

Scripts and configurations for Docker image signing with Harbor Notary and Cosign.

## Files

### notary-setup.sh
Automated Harbor Notary setup:
- Verify Notary components running
- Configure Docker Content Trust
- Initialize test repository
- Backup signing keys
- Complete setup guide

### sign-workflow.sh
Helper script for signing workflow:
- Check local image
- Verify existing signature
- Push and sign image
- Verify signature
- Show signer details

### cosign-setup.sh
Alternative Cosign setup:
- Install Cosign
- Generate key pair
- Backup keys
- Test signing
- Distribution guide

### gitlab-ci-signing.yml
Complete CI/CD signing pipeline:
- Build image
- Sign with Notary or Cosign
- Verify signature
- Deploy only if signed
- Production approval gate

## Quick Start

### Notary Setup

```bash
chmod +x notary-setup.sh
./notary-setup.sh

# Follow prompts to:
# 1. Verify Notary is running
# 2. Configure Content Trust
# 3. Initialize test repository
# 4. Backup keys
```

### Sign an Image

```bash
chmod +x sign-workflow.sh

# Sign image
./sign-workflow.sh harbor.company.local/myproject/app:v1.0

# Or manually:
export DOCKER_CONTENT_TRUST=1
docker push harbor.company.local/myproject/app:v1.0
```

### Cosign Alternative

```bash
chmod +x cosign-setup.sh
./cosign-setup.sh

# Sign with Cosign
cosign sign --key ~/.cosign/cosign.key harbor.company.local/app:v1.0

# Verify
cosign verify --key ~/.cosign/cosign.pub harbor.company.local/app:v1.0
```

## Notary Configuration

### Enable Content Trust

```bash
# Permanently (add to ~/.bashrc or ~/.zshrc)
export DOCKER_CONTENT_TRUST=1
export DOCKER_CONTENT_TRUST_SERVER=https://harbor.company.local:4443

# Per-command
DOCKER_CONTENT_TRUST=1 docker push harbor.company.local/app:v1.0
```

### Key Management

**Root Key (CRITICAL):**
- Created on first repository initialization
- Stored in: `~/.docker/trust/private/root_keys/`
- Used rarely (only for key rotation)
- MUST be backed up securely

**Repository Key:**
- Created per repository
- Stored in: `~/.docker/trust/private/tuf_keys/`
- Used for every push to repository
- Can be rotated if compromised

**Backup Keys:**
```bash
# Backup all keys
tar czf docker-trust-backup.tar.gz ~/.docker/trust/private/

# Encrypt backup
gpg --encrypt --recipient your@email.com docker-trust-backup.tar.gz

# Store encrypted backup:
# - Encrypted USB drive
# - Physical safe
# - Secure cloud storage with encryption
```

### Delegation (Team Signing)

```bash
# Generate delegation key for team member
docker trust key generate alice alice-key.pub

# Add as signer
docker trust signer add --key alice-key.pub alice \
  harbor.company.local/myproject/app

# Alice can now sign
# On Alice's machine:
docker trust sign harbor.company.local/myproject/app:v1.0
```

## Cosign Configuration

### Generate Keys

```bash
# Generate key pair
cosign generate-key-pair

# Output:
# cosign.key (private - keep secure)
# cosign.pub (public - distribute)
```

### Sign Images

```bash
# Sign
cosign sign --key cosign.key harbor.company.local/app:v1.0

# Sign with annotations
cosign sign --key cosign.key \
  --annotations builder=ci-pipeline \
  --annotations commit=$GIT_COMMIT \
  harbor.company.local/app:v1.0
```

### Verify Signatures

```bash
# Verify
cosign verify --key cosign.pub harbor.company.local/app:v1.0

# Verify with policy
cosign verify --key cosign.pub \
  --annotations builder=ci-pipeline \
  harbor.company.local/app:v1.0
```

## CI/CD Integration

### GitLab CI Setup

**1. Prepare keys for CI/CD:**

```bash
# Notary keys
cat ~/.docker/trust/private/root.key | base64 -w 0
cat ~/.docker/trust/private/repo.key | base64 -w 0

# Cosign keys
cat ~/.cosign/cosign.key | base64 -w 0
cat ~/.cosign/cosign.pub | base64 -w 0
```

**2. Add CI/CD variables in GitLab:**
```
Settings → CI/CD → Variables

Notary:
- DOCKER_TRUST_ROOT_KEY (base64-encoded, protected, masked)
- DOCKER_TRUST_REPOSITORY_KEY (base64-encoded, protected, masked)
- DOCKER_CONTENT_TRUST_ROOT_PASSPHRASE (protected, masked)
- DOCKER_CONTENT_TRUST_REPOSITORY_PASSPHRASE (protected, masked)

Cosign:
- COSIGN_PRIVATE_KEY (base64-encoded, protected, masked)
- COSIGN_PUBLIC_KEY (base64-encoded, protected)
- COSIGN_PASSWORD (protected, masked)
```

**3. Use provided pipeline:**
```bash
cp gitlab-ci-signing.yml /path/to/your/project/.gitlab-ci.yml

# Edit variables as needed
vim .gitlab-ci.yml
```

## Harbor Configuration

### Enable Content Trust per Project

```
1. Login to Harbor Web UI
2. Projects → [Your Project]
3. Configuration
4. ☑ Enable content trust
5. Save
```

Now only signed images can be pulled from this project.

### Verify in Harbor UI

```
1. Projects → [Project] → Repositories
2. Click on repository
3. Click on tag
4. Look for "Signed" badge
5. Click "Signature" tab to see details
```

## Testing

### Test Signed Push

```bash
# Enable Content Trust
export DOCKER_CONTENT_TRUST=1

# Build test image
docker build -t harbor.company.local/test/demo:v1 .

# Push (will prompt for passphrases on first push)
docker push harbor.company.local/test/demo:v1

# Verify
docker trust inspect harbor.company.local/test/demo:v1
```

### Test Unsigned Block

```bash
# Try to pull unsigned image with Content Trust enabled
export DOCKER_CONTENT_TRUST=1
docker pull harbor.company.local/test/unsigned:latest

# Should fail with:
# Error: remote trust data does not exist
```

### Test Signature Verification

```bash
# Pull signed image
export DOCKER_CONTENT_TRUST=1
docker pull harbor.company.local/test/demo:v1

# Should succeed and show:
# Pull complete
# Tagging ... 
# (signature verified automatically)
```

## Troubleshooting

### Notary Server Unreachable

```bash
# Check Notary is running
docker ps | grep notary

# Check endpoint
curl -k https://harbor.company.local:4443/_notary_server/health

# Check firewall
sudo firewall-cmd --list-ports | grep 4443
```

### Lost Root Key

```
CRITICAL: Root key cannot be recovered if lost

If root key is lost:
1. You CANNOT rotate repository keys
2. You CAN still sign with existing repository keys
3. Consider creating new repositories with new root keys
4. Document incident for security audit
```

### Passphrase Forgotten

```bash
# No way to recover passphrase
# Options:
# 1. Use backup key if available
# 2. Generate new keys (loses signature history)
# 3. Rotate keys if root key is available
```

### Cosign Verification Failed

```bash
# Check public key is correct
cat cosign.pub

# Verify image was signed
cosign verify --key cosign.pub --insecure-ignore-tlog harbor.company.local/app:v1.0

# Check signatures in Harbor
# Web UI → Repository → Artifacts → Signature tab
```

## Security Best Practices

### Key Storage

1. **Never commit keys to Git**
   - Add to .gitignore
   - Use CI/CD secrets
   - Encrypt backups

2. **Use strong passphrases**
   - 20+ characters
   - Include symbols, numbers, mixed case
   - Store in password manager

3. **Rotate keys regularly**
   - Every 6-12 months
   - Immediately if compromise suspected
   - Document rotation process

### Access Control

1. **Limit who can sign**
   - Only trusted developers
   - Automated CI/CD only
   - Audit signer list regularly

2. **Use delegation**
   - Different keys per team
   - Granular access control
   - Easier key rotation

3. **Enable Content Trust requirement**
   - On production projects
   - Block unsigned images
   - Enforce in deployment pipeline

## Comparison: Notary vs Cosign

| Aspect | Notary | Cosign |
|--------|--------|--------|
| **Setup Complexity** | Medium | Low |
| **Harbor Integration** | Native | Experimental |
| **Key Management** | TUF roles | Simple keypair |
| **Kubernetes** | Limited | Excellent |
| **Air-gap** | Excellent | Good |
| **Maturity** | Established | Newer |
| **Recommendation** | Production | Kubernetes-focused |

## Next Steps

After setting up signing:
1. Configure RBAC (Section 3.6)
2. Setup replication (Section 3.7)
3. Operations & maintenance (Section 3.8)

## Support

- **Book**: Module 3, Section 3.5
- **GitHub**: https://github.com/medvedodesa/docker-airgapped-book-rus
- **Notary Docs**: https://github.com/notaryproject/notary
- **Cosign Docs**: https://docs.sigstore.dev/cosign/overview/

## License

MIT License - See repository root for details
