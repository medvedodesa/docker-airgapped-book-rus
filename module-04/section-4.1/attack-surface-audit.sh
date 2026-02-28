#!/bin/bash
# attack-surface-audit.sh
# Automated Docker attack surface scanner
#
# Usage: ./attack-surface-audit.sh [--output report.txt]

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

OUTPUT_FILE="${2:-/tmp/docker-attack-surface-$(date +%Y%m%d-%H%M%S).txt}"

echo -e "${BLUE}Docker Attack Surface Audit${NC}"
echo "=========================================="
echo "Date: $(date)"
echo "Output: $OUTPUT_FILE"
echo ""

{
    echo "Docker Attack Surface Audit Report"
    echo "Generated: $(date)"
    echo "Host: $(hostname)"
    echo "=========================================="
    echo ""

    # CRITICAL: Docker Socket Exposure
    echo "=== [CRITICAL] Docker Socket Exposure ==="
    echo ""
    
    # Check if socket is world-readable
    SOCKET_PERMS=$(stat -c "%a" /var/run/docker.sock 2>/dev/null || echo "000")
    if [ "$SOCKET_PERMS" == "660" ] || [ "$SOCKET_PERMS" == "600" ]; then
        echo "[✓] Docker socket permissions OK: $SOCKET_PERMS"
    else
        echo "[✗] WARNING: Docker socket permissions: $SOCKET_PERMS"
        echo "    Recommended: 660 or 600"
    fi
    
    # Check containers with socket mounted
    echo ""
    echo "Containers with Docker socket access:"
    SOCKET_CONTAINERS=$(docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        if docker inspect "$ID" | grep -q "/var/run/docker.sock"; then
            echo "  [✗] CRITICAL: $NAME (ID: $ID)"
            docker inspect "$ID" | grep -A 2 "docker.sock"
        fi
    done)
    
    if [ -z "$SOCKET_CONTAINERS" ]; then
        echo "  [✓] No containers with socket access"
    else
        echo "$SOCKET_CONTAINERS"
    fi
    echo ""
    
    # CRITICAL: Privileged Containers
    echo "=== [CRITICAL] Privileged Containers ==="
    echo ""
    
    PRIV_CONTAINERS=$(docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        if docker inspect "$ID" --format '{{.HostConfig.Privileged}}' | grep -q true; then
            echo "  [✗] CRITICAL: $NAME (ID: $ID)"
        fi
    done)
    
    if [ -z "$PRIV_CONTAINERS" ]; then
        echo "[✓] No privileged containers running"
    else
        echo "Privileged containers found:"
        echo "$PRIV_CONTAINERS"
    fi
    echo ""
    
    # HIGH: Dangerous Capabilities
    echo "=== [HIGH] Dangerous Capabilities ==="
    echo ""
    
    DANGEROUS_CAPS=("SYS_ADMIN" "SYS_MODULE" "SYS_RAWIO" "SYS_PTRACE" "DAC_READ_SEARCH")
    
    docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        CAPS=$(docker inspect "$ID" --format '{{.HostConfig.CapAdd}}')
        
        for CAP in "${DANGEROUS_CAPS[@]}"; do
            if echo "$CAPS" | grep -q "$CAP"; then
                echo "  [✗] $NAME: Has dangerous capability $CAP"
            fi
        done
    done
    
    echo ""
    
    # HIGH: Host Network Mode
    echo "=== [HIGH] Host Network Mode ==="
    echo ""
    
    HOST_NET=$(docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        if docker inspect "$ID" --format '{{.HostConfig.NetworkMode}}' | grep -q host; then
            echo "  [✗] $NAME: Using host network"
        fi
    done)
    
    if [ -z "$HOST_NET" ]; then
        echo "[✓] No containers using host network"
    else
        echo "$HOST_NET"
    fi
    echo ""
    
    # HIGH: Host PID Namespace
    echo "=== [HIGH] Host PID Namespace ==="
    echo ""
    
    HOST_PID=$(docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        if docker inspect "$ID" --format '{{.HostConfig.PidMode}}' | grep -q host; then
            echo "  [✗] $NAME: Using host PID namespace"
        fi
    done)
    
    if [ -z "$HOST_PID" ]; then
        echo "[✓] No containers using host PID namespace"
    else
        echo "$HOST_PID"
    fi
    echo ""
    
    # MEDIUM: Dangerous Volume Mounts
    echo "=== [MEDIUM] Dangerous Volume Mounts ==="
    echo ""
    
    docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        MOUNTS=$(docker inspect "$ID" --format '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}')
        
        # Check for dangerous mounts
        if echo "$MOUNTS" | grep -q "^/:" || echo "$MOUNTS" | grep -q ":/host"; then
            echo "  [✗] $NAME: Mounts root filesystem"
            echo "      $MOUNTS"
        elif echo "$MOUNTS" | grep -q "/etc:" || echo "$MOUNTS" | grep -q "/var:"; then
            echo "  [!] $NAME: Mounts sensitive directory"
            echo "      $MOUNTS"
        fi
    done
    echo ""
    
    # MEDIUM: Containers Running as Root
    echo "=== [MEDIUM] Containers Running as Root ==="
    echo ""
    
    ROOT_COUNT=0
    NONROOT_COUNT=0
    
    docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        USER=$(docker inspect "$ID" --format '{{.Config.User}}')
        
        if [ -z "$USER" ] || [ "$USER" == "0" ] || [ "$USER" == "root" ]; then
            echo "  [!] $NAME: Running as root"
            ROOT_COUNT=$((ROOT_COUNT + 1))
        else
            NONROOT_COUNT=$((NONROOT_COUNT + 1))
        fi
    done
    
    echo ""
    echo "Summary: $ROOT_COUNT containers as root, $NONROOT_COUNT as non-root"
    echo ""
    
    # MEDIUM: Read-Write Filesystems
    echo "=== [MEDIUM] Read-Write Filesystems ==="
    echo ""
    
    docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        READONLY=$(docker inspect "$ID" --format '{{.HostConfig.ReadonlyRootfs}}')
        
        if [ "$READONLY" != "true" ]; then
            echo "  [!] $NAME: Has read-write filesystem"
        fi
    done
    echo ""
    
    # INFO: Docker Daemon Configuration
    echo "=== [INFO] Docker Daemon Configuration ==="
    echo ""
    
    # Check if daemon is listening on TCP
    if netstat -tuln | grep -q ":2375\|:2376"; then
        echo "[✗] CRITICAL: Docker daemon exposed on network"
        netstat -tuln | grep ":2375\|:2376"
    else
        echo "[✓] Docker daemon not exposed on network"
    fi
    echo ""
    
    # Check for authorization plugin
    if docker info 2>/dev/null | grep -q "Authorization"; then
        echo "[✓] Authorization plugin configured"
    else
        echo "[!] No authorization plugin (consider configuring)"
    fi
    echo ""
    
    # Check for user namespace remapping
    if docker info 2>/dev/null | grep -q "userns"; then
        echo "[✓] User namespace remapping enabled"
    else
        echo "[!] User namespace remapping disabled"
    fi
    echo ""
    
    # INFO: Image Analysis
    echo "=== [INFO] Image Security ==="
    echo ""
    
    echo "Images summary:"
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | head -20
    echo ""
    
    # Check for 'latest' tag usage
    LATEST_COUNT=$(docker ps --format '{{.Image}}' | grep -c ":latest" || true)
    echo "Containers using 'latest' tag: $LATEST_COUNT"
    if [ "$LATEST_COUNT" -gt 0 ]; then
        echo "[!] Avoid 'latest' tag in production"
    fi
    echo ""
    
    # INFO: Network Security
    echo "=== [INFO] Network Configuration ==="
    echo ""
    
    echo "Docker networks:"
    docker network ls
    echo ""
    
    # Check for containers on default bridge
    BRIDGE_COUNT=$(docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        NET=$(docker inspect "$ID" --format '{{.HostConfig.NetworkMode}}')
        if [ "$NET" == "default" ] || [ "$NET" == "bridge" ]; then
            echo "$NAME"
        fi
    done | wc -l)
    
    echo "Containers on default bridge: $BRIDGE_COUNT"
    if [ "$BRIDGE_COUNT" -gt 0 ]; then
        echo "[!] Consider using custom networks for isolation"
    fi
    echo ""
    
    # INFO: Resource Limits
    echo "=== [INFO] Resource Limits ==="
    echo ""
    
    NO_LIMITS=0
    
    docker ps --format '{{.ID}}:{{.Names}}' | while IFS=: read -r ID NAME; do
        MEM=$(docker inspect "$ID" --format '{{.HostConfig.Memory}}')
        CPU=$(docker inspect "$ID" --format '{{.HostConfig.CpuQuota}}')
        
        if [ "$MEM" == "0" ] && [ "$CPU" == "0" ]; then
            echo "  [!] $NAME: No resource limits"
            NO_LIMITS=$((NO_LIMITS + 1))
        fi
    done
    
    echo ""
    echo "Containers without resource limits: $NO_LIMITS"
    echo ""
    
    # Summary
    echo "=========================================="
    echo "AUDIT SUMMARY"
    echo "=========================================="
    echo ""
    
    echo "Critical Issues:"
    echo "  - Privileged containers: $(docker ps --format '{{.ID}}' | while read ID; do docker inspect "$ID" --format '{{.HostConfig.Privileged}}' | grep -c true || true; done | paste -sd+ | bc || echo 0)"
    echo "  - Containers with socket access: [check above]"
    echo "  - Docker daemon network exposure: [check above]"
    echo ""
    
    echo "High Risk:"
    echo "  - Host network mode: [check above]"
    echo "  - Dangerous capabilities: [check above]"
    echo "  - Root filesystem mounts: [check above]"
    echo ""
    
    echo "Medium Risk:"
    echo "  - Containers as root: $ROOT_COUNT"
    echo "  - Read-write filesystems: [check above]"
    echo "  - No resource limits: $NO_LIMITS"
    echo ""
    
    echo "Recommendations:"
    echo "1. Remove privileged containers if possible"
    echo "2. Never mount Docker socket into containers"
    echo "3. Use specific capabilities instead of privileged mode"
    echo "4. Run containers as non-root user"
    echo "5. Use read-only root filesystem where possible"
    echo "6. Configure resource limits (CPU, memory)"
    echo "7. Use custom networks, not default bridge"
    echo "8. Avoid 'latest' tag in production"
    echo "9. Enable authorization plugin"
    echo "10. Consider user namespace remapping"
    echo ""
    
} | tee "$OUTPUT_FILE"

# Print summary to console
echo ""
echo "=========================================="
echo -e "${GREEN}Audit Complete${NC}"
echo "=========================================="
echo ""
echo "Full report saved to: $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "1. Review critical issues immediately"
echo "2. Plan mitigation for high-risk items"
echo "3. Schedule regular audits (weekly/monthly)"
echo "4. Track remediation progress"
echo ""
