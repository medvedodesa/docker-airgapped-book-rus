#!/usr/bin/env bash
# Развёртывание Loki + Promtail для сбора логов контейнеров
# Использование: bash deploy-loki-promtail.sh [harbor_host] [data_dir]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
DATA_DIR="${2:-/opt/monitoring}"
NETWORK="${MONITORING_NETWORK:-monitoring-net}"

echo "=== Развёртывание Loki + Promtail ==="

mkdir -p "$DATA_DIR/loki" "$DATA_DIR/config/loki" "$DATA_DIR/config/promtail"
chown -R 10001:10001 "$DATA_DIR/loki" 2>/dev/null || true

# Конфигурация Loki
cat > "$DATA_DIR/config/loki/loki.yml" << 'LOKICONF'
auth_enabled: false

server:
  http_listen_port: 3100
  grpc_listen_port: 9096
  log_level: warn

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: inmemory

query_range:
  results_cache:
    cache:
      embedded_cache:
        enabled: true
        max_size_mb: 100

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  retention_period: 30d

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

ruler:
  alertmanager_url: http://alertmanager:9093

analytics:
  reporting_enabled: false
LOKICONF
echo "  [OK] loki.yml"

# Конфигурация Promtail
cat > "$DATA_DIR/config/promtail/promtail.yml" << PROMTAILCONF
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: containers
    static_configs:
      - targets:
          - localhost
        labels:
          job: containerlogs
          host: $(hostname)
          __path__: /var/lib/docker/containers/*/*-json.log

    pipeline_stages:
      - json:
          expressions:
            output: log
            stream: stream
            timestamp: time
            attrs:
      - json:
          expressions:
            tag: attrs.tag
          source: attrs
      - regex:
          expression: '^(?P<container_name>[^/]+)/(?P<container_id>[^/]+)$$'
          source: tag
      - timestamp:
          format: RFC3339Nano
          source: timestamp
      - labels:
          stream:
          container_name:
      - output:
          source: output

  - job_name: syslog
    static_configs:
      - targets:
          - localhost
        labels:
          job: syslog
          host: $(hostname)
          __path__: /var/log/syslog
PROMTAILCONF
echo "  [OK] promtail.yml"

# Запуск Loki
echo ""
echo "--- Запуск Loki ---"
docker rm -f loki 2>/dev/null || true
docker run -d \
  --name loki \
  --restart unless-stopped \
  --network "$NETWORK" \
  -v "$DATA_DIR/loki:/loki" \
  -v "$DATA_DIR/config/loki:/etc/loki:ro" \
  -p 3100:3100 \
  "${HARBOR_HOST}/monitoring/loki:latest" \
  -config.file=/etc/loki/loki.yml \
  2>/dev/null
echo "  [OK] Loki :3100"

# Запуск Promtail
echo ""
echo "--- Запуск Promtail ---"
docker rm -f promtail 2>/dev/null || true
docker run -d \
  --name promtail \
  --restart unless-stopped \
  --network "$NETWORK" \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v /var/log:/var/log:ro \
  -v "$DATA_DIR/config/promtail:/etc/promtail:ro" \
  "${HARBOR_HOST}/monitoring/promtail:latest" \
  -config.file=/etc/promtail/promtail.yml \
  2>/dev/null
echo "  [OK] Promtail"

echo ""
echo "=== Loki + Promtail запущены ==="
echo ""
echo "Настройте Grafana Data Source:"
echo "  URL: http://loki:3100"
echo "  Type: Loki"
