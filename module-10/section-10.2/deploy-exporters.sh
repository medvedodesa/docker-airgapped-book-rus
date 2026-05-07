#!/usr/bin/env bash
# Развёртывание exporters: node_exporter, cAdvisor, postgres_exporter
# Использование: bash deploy-exporters.sh [harbor_host]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
NETWORK="${MONITORING_NETWORK:-monitoring-net}"

echo "=== Развёртывание exporters ==="
echo "  Harbor:  $HARBOR_HOST"

# node_exporter
echo ""
echo "--- node_exporter ---"
docker rm -f node_exporter 2>/dev/null || true
docker run -d \
  --name node_exporter \
  --restart unless-stopped \
  --network "$NETWORK" \
  --pid host \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /:/rootfs:ro \
  --cap-drop ALL \
  --cap-add SYS_PTRACE \
  --security-opt no-new-privileges \
  "${HARBOR_HOST}/monitoring/node-exporter:latest" \
  --path.procfs=/host/proc \
  --path.rootfs=/rootfs \
  --path.sysfs=/host/sys \
  --collector.filesystem.mount-points-exclude='^/(sys|proc|dev|host|etc)($$|/)' \
  2>/dev/null
echo "  [OK] node_exporter :9100"

# cAdvisor
echo ""
echo "--- cAdvisor ---"
docker rm -f cadvisor 2>/dev/null || true
docker run -d \
  --name cadvisor \
  --restart unless-stopped \
  --network "$NETWORK" \
  -v /:/rootfs:ro \
  -v /var/run:/var/run:ro \
  -v /sys:/sys:ro \
  -v /var/lib/docker/:/var/lib/docker:ro \
  -v /dev/disk/:/dev/disk:ro \
  --privileged \
  --device /dev/kmsg \
  "${HARBOR_HOST}/monitoring/cadvisor:latest" \
  --docker_only=true \
  --disable_metrics=disk,network \
  2>/dev/null
echo "  [OK] cAdvisor :8080"

# Docker daemon metrics
echo ""
echo "--- Docker daemon metrics ---"
if ! docker info --format '{{.ExperimentalBuild}}' &>/dev/null; then
  echo "  [WARN] Docker daemon недоступен"
else
  # Проверить что в daemon.json включён metrics-addr
  DAEMON_JSON="/etc/docker/daemon.json"
  if [ -f "$DAEMON_JSON" ] && python3 -c "import json; d=json.load(open('$DAEMON_JSON')); assert 'metrics-addr' in d" 2>/dev/null; then
    echo "  [OK] Docker metrics включены"
  else
    echo "  [WARN] Добавьте в /etc/docker/daemon.json:"
    echo '    "metrics-addr": "127.0.0.1:9323"'
    echo '    "experimental": true'
  fi
fi

# Добавление целей в Prometheus
echo ""
echo "--- Targets для Prometheus ---"
TARGETS_DIR="${2:-/opt/monitoring/config/prometheus/targets/node}"
mkdir -p "$TARGETS_DIR"
cat > "$TARGETS_DIR/local.json" << JSON
[
  {
    "targets": ["node_exporter:9100"],
    "labels": {"job": "node", "host": "$(hostname)", "env": "prod"}
  },
  {
    "targets": ["cadvisor:8080"],
    "labels": {"job": "cadvisor", "host": "$(hostname)", "env": "prod"}
  }
]
JSON
echo "  [OK] $TARGETS_DIR/local.json"

echo ""
echo "=== Exporters запущены ==="
docker ps --filter "name=node_exporter" --filter "name=cadvisor" \
  --format "{{.Names}}\t{{.Status}}" 2>/dev/null
