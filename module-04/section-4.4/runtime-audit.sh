#!/bin/bash
# runtime-audit.sh
# Audit running containers for security misconfigurations
#
# Usage: sudo ./runtime-audit.sh [--fix]

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

echo -e "${BLUE}Runtime Container Security Audit${NC}"
echo "=========================================="
echo "Date: $(date)"
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

# Get all running containers
CONTAINERS=$(docker ps -q)

if [ -z "$CONTAINERS" ]; then
    echo "No running containers found"
    exit 0
fi

for CID in $CONTAINERS; do
    NAME=$(docker inspect $CID --format '{{.Name}}' | sed 's/\///')
    IMAGE=$(docker inspect $CID --format '{{.Config.Image}}')
    
    echo ""
    echo -e "${BLUE}=== Container: $NAME ===${NC}"
    echo "Image: $IMAGE"
    echo ""
    
    # Check 1: Running as root
    USER=$(docker inspect $CID --format '{{.Config.User}}')
    if [ -z "$USER" ] || [ "$USER" = "0" ] || [ "$USER" = "root" ]; then
        check "FAIL" "Running as root user"
    else
        check "PASS" "Running as non-root ($USER)"
    fi
    
    # Check 2: Read-only filesystem
    READONLY=$(docker inspect $CID --format '{{.HostConfig.ReadonlyRootfs}}')
    if [ "$READONLY" = "true" ]; then
        check "PASS" "Read-only root filesystem"
    else
        check "WARN" "Root filesystem is writable"
    fi
    
    # Check 3: Privileged mode
    PRIVILEGED=$(docker inspect $CID --format '{{.HostConfig.Privileged}}')
    if [ "$PRIVILEGED" = "true" ]; then
        check "FAIL" "Container is privileged (CRITICAL)"
    else
        check "PASS" "Not privileged"
    fi
    
    # Check 4: Capabilities
    CAP_ADD=$(docker inspect $CID --format '{{.HostConfig.CapAdd}}')
    CAP_DROP=$(docker inspect $CID --format '{{.HostConfig.CapDrop}}')
    
    if echo "$CAP_DROP" | grep -q "ALL"; then
        check "PASS" "All capabilities dropped"
    else
        check "WARN" "Not all capabilities dropped"
    fi
    
    # Check dangerous capabilities
    DANGEROUS_CAPS=("SYS_ADMIN" "SYS_MODULE" "SYS_RAWIO")
    for CAP in "${DANGEROUS_CAPS[@]}"; do
        if echo "$CAP_ADD" | grep -q "$CAP"; then
            check "FAIL" "Dangerous capability: $CAP"
        fi
    done
    
    # Check 5: Host network mode
    NET_MODE=$(docker inspect $CID --format '{{.HostConfig.NetworkMode}}')
    if [ "$NET_MODE" = "host" ]; then
        check "FAIL" "Using host network mode"
    else
        check "PASS" "Not using host network"
    fi
    
    # Check 6: Docker socket mounted
    SOCKET_MOUNTED=$(docker inspect $CID --format '{{range .Mounts}}{{.Source}}{{end}}' | grep -c "docker.sock" || echo "0")
    if [ "$SOCKET_MOUNTED" -gt 0 ]; then
        check "FAIL" "Docker socket mounted (CRITICAL)"
    else
        check "PASS" "Docker socket not mounted"
    fi
    
    # Check 7: Resource limits
    MEMORY=$(docker inspect $CID --format '{{.HostConfig.Memory}}')
    CPU_QUOTA=$(docker inspect $CID --format '{{.HostConfig.CpuQuota}}')
    PIDS_LIMIT=$(docker inspect $CID --format '{{.HostConfig.PidsLimit}}')
    
    if [ "$MEMORY" -gt 0 ]; then
        check "PASS" "Memory limit set ($(($MEMORY / 1048576))MB)"
    else
        check "WARN" "No memory limit"
    fi
    
    if [ "$CPU_QUOTA" -gt 0 ]; then
        check "PASS" "CPU limit set"
    else
        check "WARN" "No CPU limit"
    fi
    
    if [ "$PIDS_LIMIT" -gt 0 ]; then
        check "PASS" "PID limit set ($PIDS_LIMIT)"
    else
        check "WARN" "No PID limit"
    fi
    
    # Check 8: No-new-privileges
    SECOPT=$(docker inspect $CID --format '{{.HostConfig.SecurityOpt}}')
    if echo "$SECOPT" | grep -q "no-new-privileges:true"; then
        check "PASS" "no-new-privileges enabled"
    else
        check "WARN" "no-new-privileges not enabled"
    fi
    
    # Check 9: Health check
    HEALTHCHECK=$(docker inspect $CID --format '{{.State.Health.Status}}')
    if [ -n "$HEALTHCHECK" ]; then
        if [ "$HEALTHCHECK" = "healthy" ]; then
            check "PASS" "Health check configured and healthy"
        else
            check "WARN" "Health check status: $HEALTHCHECK"
        fi
    else
        check "WARN" "No health check configured"
    fi
    
    # Check 10: Image tag
    if echo "$IMAGE" | grep -q ":latest"; then
        check "WARN" "Using 'latest' tag (not recommended)"
    else
        check "PASS" "Using specific image tag"
    fi
    
done

# Summary
echo ""
echo "=========================================="
echo "Audit Summary"
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
        echo "CRITICAL Issues (fix immediately):"
        echo "  • Remove privileged containers"
        echo "  • Unmount Docker socket"
        echo "  • Drop dangerous capabilities"
        echo "  • Disable host network mode"
        echo ""
    fi
    
    if [ $WARN -gt 0 ]; then
        echo "Warnings (address soon):"
        echo "  • Enable read-only root filesystem"
        echo "  • Set resource limits (memory, CPU, PID)"
        echo "  • Run as non-root user"
        echo "  • Enable no-new-privileges"
        echo "  • Add health checks"
        echo "  • Use specific image tags"
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
