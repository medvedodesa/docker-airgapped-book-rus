# Docker Threat Model Template
# Air-Gapped Environment

## 1. System Overview

**Environment Type:** Air-Gapped Docker Infrastructure  
**Organization:** _[Your Organization]_  
**Assessment Date:** _[Date]_  
**Assessor:** _[Name]_  

**System Description:**
```
Describe your Docker environment:
- Number of hosts
- Critical applications
- Data classification
- Compliance requirements
```

---

## 2. Asset Inventory

### Critical Assets

| Asset | Description | Classification | Location |
|-------|-------------|----------------|----------|
| Docker Images | Production application images | Confidential | Harbor registry |
| Application Data | Customer/business data | Sensitive | Volume mounts |
| Secrets | API keys, certs, passwords | Secret | Vault/environment |
| Infrastructure | Docker hosts, network | Critical | On-premise |
| Audit Logs | Compliance evidence | Confidential | Log server |

### Asset Valuation

| Asset | Confidentiality | Integrity | Availability | Total Value |
|-------|----------------|-----------|--------------|-------------|
| Docker Images | High (3) | High (3) | Medium (2) | 8 |
| Application Data | Critical (4) | Critical (4) | High (3) | 11 |
| Secrets | Critical (4) | Critical (4) | High (3) | 11 |

**Scale:** Low (1), Medium (2), High (3), Critical (4)

---

## 3. Threat Actors

### Internal Threats (Primary in Air-Gap)

**1. Malicious Insider**
- **Profile:** Disgruntled employee with system access
- **Motivation:** Financial gain, revenge, ideology
- **Capabilities:** Authorized access, technical knowledge
- **Likelihood:** Low-Medium
- **Impact:** Critical

**2. Compromised Account**
- **Profile:** Legitimate user account stolen/hijacked
- **Motivation:** Varies by attacker
- **Capabilities:** User-level access
- **Likelihood:** Medium
- **Impact:** High

**3. Negligent User**
- **Profile:** Well-meaning but careless employee
- **Motivation:** None (accidental)
- **Capabilities:** Authorized access
- **Likelihood:** High
- **Impact:** Medium

**4. Third-Party Contractor**
- **Profile:** External vendor with limited access
- **Motivation:** Potentially malicious or negligent
- **Capabilities:** Limited authorized access
- **Likelihood:** Medium
- **Impact:** High

### External Threats (Secondary in Air-Gap)

**5. Nation-State APT**
- **Profile:** Advanced Persistent Threat
- **Motivation:** Espionage, sabotage
- **Capabilities:** High resources, sophisticated
- **Likelihood:** Low (but high impact if targeted)
- **Impact:** Critical

**6. Supply Chain Compromise**
- **Profile:** Pre-compromised hardware/software
- **Motivation:** Varies
- **Capabilities:** Deep access
- **Likelihood:** Low
- **Impact:** Critical

---

## 4. Attack Vectors

### High Risk Vectors

**USB/Removable Media**
- **Description:** Malicious files introduced via USB drives
- **Entry Point:** Workstations, servers
- **Threat Actors:** Insider, APT
- **Likelihood:** High
- **Examples:**
  - Infected Docker images
  - Malware payloads
  - Data exfiltration tools

**Insider Access Abuse**
- **Description:** Authorized user abuses privileges
- **Entry Point:** SSH, Docker daemon, console
- **Threat Actors:** Malicious insider, compromised account
- **Likelihood:** Medium
- **Examples:**
  - Privileged container launch
  - Data theft via docker cp
  - Configuration tampering

**Physical Access**
- **Description:** Unauthorized physical access to servers
- **Entry Point:** Datacenter, server room
- **Threat Actors:** Insider, APT
- **Likelihood:** Low-Medium
- **Examples:**
  - Boot from USB
  - Hardware tampering
  - Device theft

### Medium Risk Vectors

**Social Engineering**
- **Description:** Manipulation to gain access/information
- **Entry Point:** Physical or phone-based
- **Threat Actors:** APT, insider
- **Likelihood:** Medium
- **Examples:**
  - Tailgating into secure area
  - Credential phishing (internal)

**Misconfiguration**
- **Description:** Security controls improperly configured
- **Entry Point:** Any system component
- **Threat Actors:** Negligent user
- **Likelihood:** High
- **Examples:**
  - Privileged containers in production
  - Docker socket exposed
  - Weak access controls

**Vulnerable Software**
- **Description:** Unpatched CVEs in software
- **Entry Point:** Applications, OS, Docker
- **Threat Actors:** Any attacker
- **Likelihood:** Medium
- **Examples:**
  - Container escape (CVE-2019-5736)
  - Kernel vulnerabilities
  - Application exploits

### Low Risk Vectors (in Air-Gap)

- Network-based attacks (no internet)
- DDoS (limited external connectivity)
- Email phishing (no external email)
- Web-based attacks (isolated web apps)

---

## 5. Attack Trees

### Attack: Gain Root Access on Docker Host

```
Goal: Root access on Docker host
│
├─ Method 1: Container Escape
│  ├─ Exploit container runtime vulnerability
│  │  └─ Requires: Vulnerable runc/containerd version
│  ├─ Exploit kernel vulnerability
│  │  └─ Requires: Unpatched kernel
│  └─ Abuse privileged container
│     └─ Requires: Access to start containers
│
├─ Method 2: Abuse Docker Socket
│  ├─ Access container with socket mount
│  │  └─ Requires: Container with socket access
│  └─ Launch privileged container
│     └─ Requires: Docker API access
│
├─ Method 3: Credential Theft
│  ├─ Steal SSH keys
│  │  └─ Requires: Access to key storage
│  ├─ Crack password
│  │  └─ Requires: Password hash
│  └─ Social engineering
│     └─ Requires: Physical access to target
│
└─ Method 4: Physical Access
   ├─ Boot from USB
   │  └─ Requires: Physical access + no secure boot
   └─ Direct console access
      └─ Requires: Physical access + no console lock
```

### Attack: Exfiltrate Sensitive Data

```
Goal: Steal application data
│
├─ Method 1: Container Access
│  ├─ docker exec into container
│  │  └─ docker cp data out
│  └─ docker volume mount
│     └─ Copy data to USB
│
├─ Method 2: Direct Volume Access
│  ├─ Mount volume on host
│  └─ Copy files to removable media
│
├─ Method 3: Log Analysis
│  ├─ Extract secrets from logs
│  └─ Reconstruct sensitive data
│
└─ Method 4: Backup Theft
   └─ Steal backup media
```

---

## 6. Threat Scenarios

### Scenario 1: Malicious Image Deployment

**Attacker:** Insider developer  
**Attack Vector:** USB drive with backdoored image  
**Attack Steps:**
1. Developer builds image with backdoor on external machine
2. Saves image as .tar file on USB
3. Brings USB into air-gap environment
4. Loads image: `docker load < malicious-image.tar`
5. Pushes to Harbor (if not scanned)
6. Image deployed to production
7. Backdoor activates, provides persistent access

**Impact:** Critical - code execution, data theft, persistence  
**Likelihood:** Medium (depends on controls)  
**Existing Controls:**
- [ ] Image scanning (Trivy)
- [ ] Image signing requirement
- [ ] Code review process
- [ ] USB port restrictions

**Residual Risk:** _[Calculate after controls]_

### Scenario 2: Privileged Container Escape

**Attacker:** Compromised application in container  
**Attack Vector:** Vulnerability exploit → privileged container  
**Attack Steps:**
1. Application vulnerability exploited
2. Attacker gains shell in container
3. Discovers container is privileged
4. Mounts host filesystem: `mount /dev/sda1 /mnt`
5. Accesses host files, SSH keys, secrets
6. Establishes persistence on host
7. Lateral movement to other hosts

**Impact:** Critical - full host compromise  
**Likelihood:** Low (if privileged containers restricted)  
**Existing Controls:**
- [ ] Privileged container prohibition
- [ ] Runtime security monitoring (Falco)
- [ ] Application security testing
- [ ] Network segmentation

**Residual Risk:** _[Calculate after controls]_

### Scenario 3: Physical Server Theft

**Attacker:** External threat actor  
**Attack Vector:** Physical access → server theft  
**Attack Steps:**
1. Attacker gains physical access (social engineering)
2. Identifies and steals server/disk
3. Analyzes data offline
4. Extracts sensitive information

**Impact:** High - data breach, service disruption  
**Likelihood:** Low (depends on physical security)  
**Existing Controls:**
- [ ] Physical access control
- [ ] Full disk encryption
- [ ] Tamper-evident seals
- [ ] CCTV monitoring

**Residual Risk:** _[Calculate after controls]_

---

## 7. Risk Register

| ID | Threat | Likelihood | Impact | Risk Score | Mitigation | Residual Risk |
|----|--------|-----------|--------|------------|------------|---------------|
| T-01 | Malicious image via USB | High (3) | Critical (4) | 12 | Image scanning, signing | Medium (4) |
| T-02 | Insider with root access | Medium (2) | Critical (4) | 8 | RBAC, audit, 2-person rule | Low (2) |
| T-03 | Container escape | Low (1) | Critical (4) | 4 | Kernel hardening, seccomp | Low (1) |
| T-04 | Resource exhaustion DoS | Medium (2) | High (3) | 6 | Cgroups limits, monitoring | Low (2) |
| T-05 | Physical server theft | Low (1) | High (3) | 3 | FDE, physical security | Low (1) |
| T-06 | Credential theft | Medium (2) | High (3) | 6 | MFA, Vault, rotation | Low (2) |
| T-07 | Misconfiguration | High (3) | Medium (2) | 6 | Config management, review | Medium (4) |

**Risk Scoring:**
- Likelihood: Low (1), Medium (2), High (3)
- Impact: Low (1), Medium (2), High (3), Critical (4)
- Risk = Likelihood × Impact

---

## 8. Security Controls Mapping

### Preventive Controls

| Control | Threats Mitigated | Status |
|---------|------------------|--------|
| Image scanning (Trivy) | T-01, T-03 | ☐ Implemented |
| Image signing (Notary) | T-01 | ☐ Implemented |
| RBAC (Harbor, Docker) | T-02 | ☐ Implemented |
| MFA | T-02, T-06 | ☐ Implemented |
| Full disk encryption | T-05 | ☐ Implemented |
| Cgroups resource limits | T-04 | ☐ Implemented |
| Seccomp/AppArmor | T-03 | ☐ Implemented |
| USB port control | T-01, T-05 | ☐ Implemented |

### Detective Controls

| Control | Threats Detected | Status |
|---------|-----------------|--------|
| Audit logging (auditd) | T-02, T-03, T-06 | ☐ Implemented |
| Runtime monitoring (Falco) | T-03, T-04 | ☐ Implemented |
| Vulnerability scanning | T-03 | ☐ Implemented |
| SIEM/log analysis | All | ☐ Implemented |

### Responsive Controls

| Control | Threats Responded To | Status |
|---------|---------------------|--------|
| Incident response plan | All | ☐ Documented |
| Automated alerting | T-03, T-04 | ☐ Implemented |
| Backup/recovery | T-05, T-07 | ☐ Implemented |

---

## 9. Mitigation Priorities

### Priority 0 (Immediate - Critical Risk)

- [ ] **T-01:** Implement mandatory image scanning
- [ ] **T-01:** Enforce image signing for production

### Priority 1 (Next 30 days - High Risk)

- [ ] **T-02:** Implement RBAC across all systems
- [ ] **T-04:** Configure cgroups resource limits
- [ ] **T-06:** Deploy Vault for secrets management

### Priority 2 (Next 90 days - Medium Risk)

- [ ] **T-03:** Deploy Falco runtime monitoring
- [ ] **T-07:** Implement configuration management
- [ ] All: Comprehensive audit logging

### Priority 3 (Next 6 months - Low Risk)

- [ ] **T-05:** Review physical security controls
- [ ] All: Incident response testing
- [ ] All: Security awareness training

---

## 10. Review & Updates

**Review Schedule:**
- **Quarterly:** Full threat model review
- **Monthly:** Risk register update
- **Ad-hoc:** After major changes or incidents

**Next Review Date:** _[Date]_  
**Responsible:** _[Name/Team]_

**Change Log:**

| Date | Change | Reason | Updated By |
|------|--------|--------|------------|
| | | | |

---

## Template Usage Instructions

1. **Fill in organization details** in section 1
2. **Customize asset inventory** in section 2 with your specific assets
3. **Review threat actors** in section 3, add any specific to your org
4. **Map attack vectors** in section 4 to your environment
5. **Create attack trees** in section 5 for critical scenarios
6. **Develop threat scenarios** in section 6 specific to your use cases
7. **Populate risk register** in section 7 with identified threats
8. **Map existing controls** in section 8
9. **Prioritize mitigations** in section 9 based on risk scores
10. **Schedule regular reviews** as per section 10

Save completed threat model and share with security team for review.
