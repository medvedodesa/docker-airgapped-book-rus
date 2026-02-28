#!/bin/bash
# kernel-security-check.sh
# Validate kernel and system security configuration
#
# Usage: sudo ./kernel-security-check.sh [--fix]

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

FIX_MODE=false
if [ "${1:-}" = "--fix" ]; then
    FIX_MODE=true
fi

echo -e "${BLUE}Kernel & System Security Validation${NC}"
echo "=========================================="
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "Fix mode: $FIX_MODE"
echo ""

PASS=0
FAIL=0
WARN=0

check() {
    local LEVEL=$1
    local MESSAGE=$2
    
    case $LEVEL in
        PASS)
            echo -e "${GREEN}[PASS]${NC} $MESSAGE"
            PASS=$((PASS + 1))
            ;;
        FAIL)
            echo -e "${RED}[FAIL]${NC} $MESSAGE"
            FAIL=$((FAIL + 1))
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $MESSAGE"
            WARN=$((WARN + 1))
            ;;
    esac
}

echo "=== Kernel Parameters (sysctl) ==="
echo ""

# Network Security
check_sysctl() {
    local PARAM=$1
    local EXPECTED=$2
    local ACTUAL=$(sysctl -n $PARAM 2>/dev/null || echo "N/A")
    
    if [ "$ACTUAL" = "$EXPECTED" ]; then
        check "PASS" "$PARAM = $EXPECTED"
    elif [ "$ACTUAL" = "N/A" ]; then
        check "WARN" "$PARAM not found"
    else
        check "FAIL" "$PARAM = $ACTUAL (expected $EXPECTED)"
        
        if [ "$FIX_MODE" = true ]; then
            sysctl -w $PARAM=$EXPECTED >/dev/null 2>&1 && \
                echo "       Fixed: $PARAM set to $EXPECTED"
        fi
    fi
}

# Critical network parameters
check_sysctl "net.ipv4.ip_forward" "1"  # Required for Docker
check_sysctl "net.ipv4.conf.all.rp_filter" "1"
check_sysctl "net.ipv4.conf.all.accept_redirects" "0"
check_sysctl "net.ipv4.conf.all.send_redirects" "0"
check_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1"
check_sysctl "net.ipv4.tcp_syncookies" "1"

echo ""

# Kernel security
check_sysctl "kernel.randomize_va_space" "2"
check_sysctl "kernel.kptr_restrict" "2"
check_sysctl "kernel.dmesg_restrict" "1"
check_sysctl "kernel.yama.ptrace_scope" "1"
check_sysctl "fs.suid_dumpable" "0"

echo ""
echo "=== Auditd Configuration ==="
echo ""

# Check auditd status
if systemctl is-active auditd >/dev/null 2>&1; then
    check "PASS" "auditd service is running"
    
    # Check Docker audit rules
    DOCKER_RULES=$(auditctl -l 2>/dev/null | grep -c docker || echo "0")
    if [ "$DOCKER_RULES" -gt 0 ]; then
        check "PASS" "Docker audit rules loaded ($DOCKER_RULES rules)"
    else
        check "FAIL" "No Docker audit rules loaded"
    fi
    
    # Check audit log size
    if [ -d /var/log/audit ]; then
        AUDIT_SIZE=$(du -sh /var/log/audit 2>/dev/null | cut -f1)
        echo "       Audit log size: $AUDIT_SIZE"
    fi
else
    check "FAIL" "auditd service not running"
    
    if [ "$FIX_MODE" = true ]; then
        systemctl start auditd && \
            check "PASS" "Started auditd service"
    fi
fi

echo ""
echo "=== Firewall Configuration ==="
echo ""

# Check firewall status
if systemctl is-active firewalld >/dev/null 2>&1; then
    check "PASS" "firewalld is active"
    
    # Check default zone
    DEFAULT_ZONE=$(firewall-cmd --get-default-zone 2>/dev/null || echo "N/A")
    echo "       Default zone: $DEFAULT_ZONE"
    
elif systemctl is-active ufw >/dev/null 2>&1; then
    check "PASS" "ufw is active"
    
elif command -v iptables >/dev/null 2>&1; then
    RULES=$(iptables -L -n | grep -c "^Chain" || echo "0")
    if [ "$RULES" -gt 3 ]; then
        check "WARN" "iptables configured (no firewalld/ufw)"
    else
        check "FAIL" "No firewall configured"
    fi
else
    check "FAIL" "No firewall found"
fi

echo ""
echo "=== SSH Configuration ==="
echo ""

if [ -f /etc/ssh/sshd_config ]; then
    # Check PermitRootLogin
    ROOT_LOGIN=$(grep "^PermitRootLogin" /etc/ssh/sshd_config | awk '{print $2}')
    if [ "$ROOT_LOGIN" = "no" ]; then
        check "PASS" "Root login disabled"
    else
        check "WARN" "Root login: $ROOT_LOGIN"
    fi
    
    # Check PasswordAuthentication
    PASS_AUTH=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config | awk '{print $2}')
    if [ "$PASS_AUTH" = "no" ]; then
        check "PASS" "Password authentication disabled"
    else
        check "WARN" "Password authentication: $PASS_AUTH"
    fi
else
    check "WARN" "SSH config not found"
fi

echo ""
echo "=== Kernel Modules ==="
echo ""

# Check for blacklisted modules
if [ -d /etc/modprobe.d ]; then
    BLACKLIST_FILES=$(find /etc/modprobe.d -name "*.conf" -exec grep -l "^blacklist" {} \; | wc -l)
    if [ "$BLACKLIST_FILES" -gt 0 ]; then
        check "PASS" "Module blacklisting configured ($BLACKLIST_FILES files)"
    else
        check "WARN" "No module blacklisting configured"
    fi
fi

# Check for loaded unnecessary modules
WIRELESS=$(lsmod | grep -c "^iwl\|^cfg80211" || echo "0")
if [ "$WIRELESS" -eq 0 ]; then
    check "PASS" "Wireless modules not loaded"
else
    check "WARN" "Wireless modules loaded (datacenter?)"
fi

echo ""
echo "=== System Services ==="
echo ""

# Check unnecessary services
SERVICES_TO_CHECK=("bluetooth" "avahi-daemon" "cups")

for SERVICE in "${SERVICES_TO_CHECK[@]}"; do
    if systemctl is-enabled $SERVICE >/dev/null 2>&1; then
        check "WARN" "$SERVICE is enabled (consider disabling)"
    else
        check "PASS" "$SERVICE is disabled or not present"
    fi
done

echo ""
echo "=== Time Synchronization ==="
echo ""

if systemctl is-active chronyd >/dev/null 2>&1; then
    check "PASS" "chronyd is running"
    
    # Check time sync status
    if command -v chronyc >/dev/null 2>&1; then
        SYNC=$(chronyc tracking 2>/dev/null | grep "Reference ID" || echo "")
        if [ -n "$SYNC" ]; then
            echo "       $SYNC"
        fi
    fi
elif systemctl is-active ntpd >/dev/null 2>&1; then
    check "PASS" "ntpd is running"
else
    check "WARN" "No time synchronization service running"
fi

echo ""
echo "=== Security Updates ==="
echo ""

if command -v yum >/dev/null 2>&1; then
    UPDATES=$(yum list updates --security -q 2>/dev/null | grep -c "^" || echo "0")
    if [ "$UPDATES" -eq 0 ]; then
        check "PASS" "No security updates pending"
    else
        check "WARN" "$UPDATES security updates available"
    fi
elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq 2>/dev/null || true
    UPDATES=$(apt-get -s upgrade | grep -c "^Inst.*security" || echo "0")
    if [ "$UPDATES" -eq 0 ]; then
        check "PASS" "No security updates pending"
    else
        check "WARN" "$UPDATES security updates available"
    fi
fi

echo ""
echo "=== File Integrity ==="
echo ""

# Check AIDE
if command -v aide >/dev/null 2>&1; then
    if [ -f /var/lib/aide/aide.db.gz ]; then
        check "PASS" "AIDE database exists"
    else
        check "WARN" "AIDE installed but not initialized"
    fi
else
    check "WARN" "AIDE not installed (file integrity monitoring)"
fi

echo ""
echo "=== SELinux / AppArmor ==="
echo ""

# Check SELinux
if command -v getenforce >/dev/null 2>&1; then
    SELINUX=$(getenforce)
    if [ "$SELINUX" = "Enforcing" ]; then
        check "PASS" "SELinux is enforcing"
    else
        check "WARN" "SELinux: $SELINUX"
    fi
# Check AppArmor
elif command -v aa-status >/dev/null 2>&1; then
    if aa-status --enabled 2>/dev/null; then
        check "PASS" "AppArmor is enabled"
    else
        check "WARN" "AppArmor not enabled"
    fi
else
    check "WARN" "No MAC system (SELinux/AppArmor) found"
fi

echo ""
echo "=========================================="
echo "Security Check Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}PASS:${NC} $PASS"
echo -e "${YELLOW}WARN:${NC} $WARN"
echo -e "${RED}FAIL:${NC} $FAIL"
echo ""

TOTAL=$((PASS + WARN + FAIL))
if [ $TOTAL -gt 0 ]; then
    SCORE=$((PASS * 100 / TOTAL))
    echo "Security Score: ${SCORE}%"
fi
echo ""

# Recommendations
if [ $FAIL -gt 0 ] || [ $WARN -gt 0 ]; then
    echo "Recommendations:"
    echo ""
    
    if [ $FAIL -gt 0 ]; then
        echo "Critical Issues:"
        echo "  • Fix failed sysctl parameters"
        echo "  • Enable auditd if not running"
        echo "  • Load Docker audit rules"
        echo "  • Configure firewall"
        echo ""
    fi
    
    if [ $WARN -gt 0 ]; then
        echo "Warnings:"
        echo "  • Review SSH configuration"
        echo "  • Disable unnecessary services"
        echo "  • Apply security updates"
        echo "  • Configure MAC (SELinux/AppArmor)"
        echo ""
    fi
fi

# Exit code
if [ $FAIL -gt 0 ]; then
    exit 1
elif [ $WARN -gt 0 ]; then
    exit 2
else
    exit 0
fi
