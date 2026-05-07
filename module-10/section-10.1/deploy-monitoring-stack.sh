#!/usr/bin/env bash
# Развёртывание стека мониторинга: Prometheus + Grafana + Alertmanager
# Использование: bash deploy-monitoring-stack.sh [harbor_host] [data_dir]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
DATA_DIR="${2:-/opt/monitoring}"
NETWORK="${MONITORING_NETWORK:-monitoring-net}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9090}"
GRAFANA_PORT="${GRAFANA_PORT:-3000}"

echo "=== Развёртывание стека мониторинга ==="
echo "  Harbor:  $HARBOR_HOST"
echo "  Данные:  $DATA_DIR"

# Создание директорий
echo ""
echo "--- Директории ---"
for dir in "$DATA_DIR/prometheus" "$DATA_DIR/grafana" "$DATA_DIR/alertmanager" \
           "$DATA_DIR/config/prometheus" "$DATA_DIR/config/grafana" "$DATA_DIR/config/alertmanager"; do
  mkdir -p "$dir"
  echo "  [OK] $dir"
done
chown -R 65534:65534 "$DATA_DIR/prometheus" 2>/dev/null || true   # nobody (Prometheus)
chown -R 472:472 "$DATA_DIR/grafana" 2>/dev/null || true           # grafana user

# Docker network
echo ""
echo "--- Сеть ---"
docker network inspect "$NETWORK" &>/dev/null 2>&1 || \
  docker network create --driver overlay --attachable "$NETWORK" 2>/dev/null
echo "  [OK] $NETWORK"

# Базовая конфигурация Prometheus
cat > "$DATA_DIR/config/prometheus/prometheus.yml" << PROMCONF
global:
  scrape_interval: 30s
  evaluation_interval: 30s
  external_labels:
    cluster: 'internal'
    environment: 'prod'

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'docker'
    static_configs:
      - targets: ['dockerd-exporter:9323']

  - job_name: 'node'
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/node/*.json
        refresh_interval: 30s
PROMCONF
echo "  [OK] prometheus.yml"

# Docker Compose манифест
cat > "$DATA_DIR/docker-compose.yml" << COMPOSE
version: '3.8'

networks:
  monitoring-net:
    external: true
    name: ${NETWORK}

volumes:
  prometheus_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DATA_DIR}/prometheus
  grafana_data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: ${DATA_DIR}/grafana

services:
  prometheus:
    image: ${HARBOR_HOST}/monitoring/prometheus:latest
    restart: unless-stopped
    volumes:
      - prometheus_data:/prometheus
      - ${DATA_DIR}/config/prometheus:/etc/prometheus:ro
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=30d'
      - '--web.enable-lifecycle'
    networks: [monitoring-net]
    ports:
      - "${PROMETHEUS_PORT}:9090"

  grafana:
    image: ${HARBOR_HOST}/monitoring/grafana:latest
    restart: unless-stopped
    volumes:
      - grafana_data:/var/lib/grafana
      - ${DATA_DIR}/config/grafana:/etc/grafana/provisioning:ro
    environment:
      - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_password
      - GF_SERVER_DOMAIN=grafana.internal.company.local
      - GF_ANALYTICS_REPORTING_ENABLED=false
      - GF_ANALYTICS_CHECK_FOR_UPDATES=false
    networks: [monitoring-net]
    ports:
      - "${GRAFANA_PORT}:3000"
    depends_on: [prometheus]

  alertmanager:
    image: ${HARBOR_HOST}/monitoring/alertmanager:latest
    restart: unless-stopped
    volumes:
      - ${DATA_DIR}/config/alertmanager:/etc/alertmanager:ro
      - ${DATA_DIR}/alertmanager:/alertmanager
    networks: [monitoring-net]
    ports:
      - "9093:9093"
COMPOSE
echo "  [OK] docker-compose.yml"

# Запуск
echo ""
echo "--- Запуск ---"
docker compose -f "$DATA_DIR/docker-compose.yml" up -d 2>/dev/null
echo "  [OK] Стек мониторинга запущен"

sleep 5
echo ""
echo "--- Статус ---"
docker compose -f "$DATA_DIR/docker-compose.yml" ps 2>/dev/null | head -10

echo ""
echo "=== Стек мониторинга развёрнут ==="
echo "  Prometheus: http://localhost:$PROMETHEUS_PORT"
echo "  Grafana:    http://localhost:$GRAFANA_PORT"
