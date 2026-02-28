#!/bin/bash
# cis-audit.sh
# Automated CIS Docker Benchmark compliance checker
#
# Usage: ./cis-audit.sh [--fix] [--report report.html]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

FIX_MODE=false
REPORT_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --fix)
            FIX_MODE=true
            shift
            ;;
        --report)
            REPORT_FILE="$2"
            shift 2
            ;;
        *)
            echo "Usage: $0 [--fix] [--report report.html]"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}CIS Docker Benchmark Compliance Audit${NC}"
echo "=========================================="
echo "Date: $(date)"
echo "Fix mode: $FIX_MODE"
echo ""

# Counters
PASS=0
FAIL=0
WARN=0

# Results array
declare -a RESULTS

# Function: Add result
add_result() {
    local STATUS=$1
    local CONTROL=$2
    local DESCRIPTION=$3
    local DETAILS=$4
    
    RESULTS+=("$STATUS|$CONTROL|$DESCRIPTION|$DETAILS")
    
    case $STATUS in
        PASS)
            PASS=$((PASS + 1))
            echo -e "${GREEN}[PASS]${NC} $CONTROL: $DESCRIPTION"
            ;;
        FAIL)
            FAIL=$((FAIL + 1))
            echo -e "${RED}[FAIL]${NC} $CONTROL: $DESCRIPTION"
            [ -n "$DETAILS" ] && echo "       $DETAILS"
            ;;
        WARN)
            WARN=$((WARN + 1))
            echo -e "${YELLOW}[WARN]${NC} $CONTROL: $DESCRIPTION"
            [ -n "$DETAILS" ] && echo "       $DETAILS"
            ;;
    esac
}

echo "=== Section 1: Host Configuration ==="
echo ""

# 1.1.1: Separate partition for containers
if mount | grep -q '/var/lib/docker'; then
    add_result "PASS" "1.1.1" "Separate partition for containers" ""
else
    add_result "WARN" "1.1.1" "No separate partition for containers" "Recommend: Create dedicated partition/LVM"
fi

# 1.1.2: Harden container host
if [ -f /etc/selinux/config ]; then
    SELINUX=$(grep ^SELINUX= /etc/selinux/config | cut -d= -f2)
    if [ "$SELINUX" = "enforcing" ]; then
        add_result "PASS" "1.1.2" "SELinux enforcing" ""
    else
        add_result "FAIL" "1.1.2" "SELinux not enforcing" "Current: $SELINUX"
        if [ "$FIX_MODE" = true ]; then
            sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
            setenforce 1 2>/dev/null || true
            echo "       Fixed: Set SELinux to enforcing"
        fi
    fi
fi

# 1.2.1: Audit Docker daemon
if auditctl -l | grep -q dockerd; then
    add_result "PASS" "1.2.1" "Docker daemon audited" ""
else
    add_result "FAIL" "1.2.1" "Docker daemon not audited" "Missing auditd rules"
    if [ "$FIX_MODE" = true ]; then
        echo "-w /usr/bin/dockerd -k docker" >> /etc/audit/rules.d/docker.rules
        augenrules --load
        echo "       Fixed: Added auditd rule for dockerd"
    fi
fi

# 1.2.2: Audit Docker files
if auditctl -l | grep -q '/var/lib/docker'; then
    add_result "PASS" "1.2.2" "Docker files audited" ""
else
    add_result "FAIL" "1.2.2" "Docker files not audited" ""
fi

echo ""
echo "=== Section 2: Docker Daemon Configuration ==="
echo ""

# 2.1: ICC (Inter-Container Communication)
ICC=$(docker info --format '{{.BridgeNfIptables}}' 2>/dev/null || echo "true")
if [ "$ICC" = "false" ]; then
    add_result "PASS" "2.1" "ICC restricted" ""
else
    add_result "WARN" "2.1" "ICC not restricted" "Containers can communicate freely"
fi

# 2.2: Logging level
LOG_LEVEL=$(ps aux | grep dockerd | grep -o 'log-level=[^ ]*' | cut -d= -f2 || echo "info")
if [ "$LOG_LEVEL" = "info" ] || [ "$LOG_LEVEL" = "debug" ]; then
    add_result "PASS" "2.2" "Logging level appropriate" "Level: $LOG_LEVEL"
else
    add_result "WARN" "2.2" "Logging level may be insufficient" "Level: $LOG_LEVEL"
fi

# 2.3: iptables enabled
if docker info --format '{{.Iptables}}' 2>/dev/null | grep -q true; then
    add_result "PASS" "2.3" "iptables enabled" ""
else
    add_result "FAIL" "2.3" "iptables disabled" "Network isolation compromised"
fi

# 2.4: Insecure registries
if [ -f /etc/docker/daemon.json ]; then
    INSECURE=$(jq -r '.["insecure-registries"]' /etc/docker/daemon.json 2>/dev/null || echo "null")
    if [ "$INSECURE" = "null" ] || [ "$INSECURE" = "[]" ]; then
        add_result "PASS" "2.4" "No insecure registries" ""
    else
        add_result "FAIL" "2.4" "Insecure registries configured" "Found: $INSECURE"
    fi
else
    add_result "PASS" "2.4" "No daemon.json (no insecure registries)" ""
fi

# 2.5: Live restore
if [ -f /etc/docker/daemon.json ]; then
    LIVE_RESTORE=$(jq -r '.["live-restore"]' /etc/docker/daemon.json 2>/dev/null || echo "false")
    if [ "$LIVE_RESTORE" = "true" ]; then
        add_result "PASS" "2.5" "Live restore enabled" ""
    else
        add_result "WARN" "2.5" "Live restore disabled" "Recommend enabling for high availability"
    fi
fi

# 2.6: User namespace remapping
USERNS=$(docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -o 'name=userns')
if [ -n "$USERNS" ]; then
    add_result "PASS" "2.6" "User namespace remapping enabled" ""
else
    add_result "WARN" "2.6" "User namespace remapping not enabled" "Level 2 control"
fi

echo ""
echo "=== Section 3: Docker Files Configuration ==="
echo ""

# 3.1: docker.service file ownership
if [ -f /lib/systemd/system/docker.service ]; then
    OWNER=$(stat -c %U:%G /lib/systemd/system/docker.service)
    if [ "$OWNER" = "root:root" ]; then
        add_result "PASS" "3.1" "docker.service ownership correct" ""
    else
        add_result "FAIL" "3.1" "docker.service ownership incorrect" "Found: $OWNER"
    fi
fi

# 3.2: docker.service file permissions
if [ -f /lib/systemd/system/docker.service ]; then
    PERMS=$(stat -c %a /lib/systemd/system/docker.service)
    if [ "$PERMS" = "644" ] || [ "$PERMS" = "600" ]; then
        add_result "PASS" "3.2" "docker.service permissions correct" ""
    else
        add_result "FAIL" "3.2" "docker.service permissions incorrect" "Found: $PERMS"
        if [ "$FIX_MODE" = true ]; then
            chmod 644 /lib/systemd/system/docker.service
            echo "       Fixed: Set permissions to 644"
        fi
    fi
fi

# 3.3: Docker socket ownership
if [ -S /var/run/docker.sock ]; then
    SOCK_OWNER=$(stat -c %U:%G /var/run/docker.sock)
    if [ "$SOCK_OWNER" = "root:docker" ]; then
        add_result "PASS" "3.3" "Docker socket ownership correct" ""
    else
        add_result "WARN" "3.3" "Docker socket ownership" "Found: $SOCK_OWNER"
    fi
fi

# 3.4: Docker socket permissions
if [ -S /var/run/docker.sock ]; then
    SOCK_PERMS=$(stat -c %a /var/run/docker.sock)
    if [ "$SOCK_PERMS" = "660" ] || [ "$SOCK_PERMS" = "600" ]; then
        add_result "PASS" "3.4" "Docker socket permissions correct" ""
    else
        add_result "FAIL" "3.4" "Docker socket permissions incorrect" "Found: $SOCK_PERMS"
        if [ "$FIX_MODE" = true ]; then
            chmod 660 /var/run/docker.sock
            echo "       Fixed: Set permissions to 660"
        fi
    fi
fi

echo ""
echo "=== Section 5: Container Runtime ==="
echo ""

# Check running containers
if ! docker ps -q >/dev/null 2>&1; then
    add_result "WARN" "5.x" "Cannot check containers" "Docker daemon not accessible"
else
    CONTAINER_COUNT=$(docker ps -q | wc -l)
    
    if [ "$CONTAINER_COUNT" -eq 0 ]; then
        add_result "WARN" "5.x" "No running containers to audit" ""
    else
        # 5.1: Privileged containers
        PRIV_COUNT=$(docker ps -q | xargs -I {} docker inspect {} --format '{{.HostConfig.Privileged}}' | grep -c true || echo "0")
        if [ "$PRIV_COUNT" -eq 0 ]; then
            add_result "PASS" "5.1" "No privileged containers" ""
        else
            add_result "FAIL" "5.1" "Privileged containers detected" "Count: $PRIV_COUNT"
        fi
        
        # 5.2: Root user in containers
        ROOT_COUNT=0
        docker ps --format '{{.Names}}' | while read CONTAINER; do
            USER=$(docker inspect "$CONTAINER" --format '{{.Config.User}}')
            if [ -z "$USER" ] || [ "$USER" = "0" ] || [ "$USER" = "root" ]; then
                ROOT_COUNT=$((ROOT_COUNT + 1))
            fi
        done
        
        if [ "$ROOT_COUNT" -eq 0 ]; then
            add_result "PASS" "5.2" "No containers running as root" ""
        else
            add_result "WARN" "5.2" "Containers running as root" "Count: $ROOT_COUNT"
        fi
        
        # 5.3: Resource limits
        NO_LIMITS=0
        docker ps -q | while read CID; do
            MEM=$(docker inspect "$CID" --format '{{.HostConfig.Memory}}')
            CPU=$(docker inspect "$CID" --format '{{.HostConfig.CpuQuota}}')
            if [ "$MEM" = "0" ] && [ "$CPU" = "0" ]; then
                NO_LIMITS=$((NO_LIMITS + 1))
            fi
        done
        
        if [ "$NO_LIMITS" -eq 0 ]; then
            add_result "PASS" "5.3" "All containers have resource limits" ""
        else
            add_result "WARN" "5.3" "Containers without resource limits" "Count: $NO_LIMITS"
        fi
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "Audit Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}PASS:${NC} $PASS"
echo -e "${RED}FAIL:${NC} $FAIL"
echo -e "${YELLOW}WARN:${NC} $WARN"
echo ""

TOTAL=$((PASS + FAIL + WARN))
if [ "$TOTAL" -gt 0 ]; then
    COMPLIANCE=$((PASS * 100 / TOTAL))
    echo "Compliance Score: ${COMPLIANCE}%"
fi
echo ""

# Generate report if requested
if [ -n "$REPORT_FILE" ]; then
    echo "Generating HTML report: $REPORT_FILE"
    
    cat > "$REPORT_FILE" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>CIS Docker Benchmark Audit Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #333; }
        .summary { background: #f0f0f0; padding: 15px; margin: 20px 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #4CAF50; color: white; }
        .pass { color: green; font-weight: bold; }
        .fail { color: red; font-weight: bold; }
        .warn { color: orange; font-weight: bold; }
    </style>
</head>
<body>
    <h1>CIS Docker Benchmark Audit Report</h1>
    <div class="summary">
        <p><strong>Date:</strong> $(date)</p>
        <p><strong>Hostname:</strong> $(hostname)</p>
        <p><strong>Compliance Score:</strong> ${COMPLIANCE}%</p>
        <p><span class="pass">PASS: $PASS</span> | <span class="fail">FAIL: $FAIL</span> | <span class="warn">WARN: $WARN</span></p>
    </div>
    
    <h2>Detailed Results</h2>
    <table>
        <tr>
            <th>Status</th>
            <th>Control</th>
            <th>Description</th>
            <th>Details</th>
        </tr>
EOF
    
    for RESULT in "${RESULTS[@]}"; do
        IFS='|' read -r STATUS CONTROL DESCRIPTION DETAILS <<< "$RESULT"
        echo "<tr><td class=\"$(echo $STATUS | tr '[:upper:]' '[:lower:]')\">$STATUS</td><td>$CONTROL</td><td>$DESCRIPTION</td><td>$DETAILS</td></tr>" >> "$REPORT_FILE"
    done
    
    cat >> "$REPORT_FILE" << EOF
    </table>
</body>
</html>
EOF
    
    echo "Report saved to: $REPORT_FILE"
fi

# Exit code
if [ "$FAIL" -gt 0 ]; then
    exit 1
else
    exit 0
fi
