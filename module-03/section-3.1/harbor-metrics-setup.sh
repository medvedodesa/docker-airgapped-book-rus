#!/usr/bin/env bash
# Настройка сбора метрик Harbor в Prometheus
# Использование: bash harbor-metrics-setup.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
PROMETHEUS_CONFIG="${PROMETHEUS_CONFIG:-/etc/prometheus/prometheus.yml}"
METRICS_PORT="${HARBOR_METRICS_PORT:-9090}"

echo "=== Настройка метрик Harbor ==="
echo "Реестр: $HARBOR_URL"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api_patch() {
  curl -sf -X PUT \
    -H "Authorization: Basic $AUTH" \
    -H "Content-Type: application/json" \
    "$HARBOR_URL/api/v2.0/$1" \
    -d "$2"
}

# --- Включение метрик в Harbor ---
echo ""
echo "--- Включение endpoint /metrics в Harbor ---"
HARBOR_CFG=/etc/harbor/harbor.yml

if [ -f "$HARBOR_CFG" ]; then
  if grep -q "metric:" "$HARBOR_CFG"; then
    echo "Секция metric: уже присутствует в $HARBOR_CFG"
  else
    cat >> "$HARBOR_CFG" <<EOF

metric:
  enabled: true
  port: $METRICS_PORT
  path: /metrics
EOF
    echo "Секция metric добавлена в $HARBOR_CFG"
    echo "Требуется перезапуск Harbor: sudo harbor/prepare && sudo docker compose -f /opt/harbor/docker-compose.yml up -d"
  fi
else
  echo "Файл $HARBOR_CFG не найден — настройте параметр metric вручную"
  echo ""
  echo "Добавьте в harbor.yml:"
  echo ""
  echo "metric:"
  echo "  enabled: true"
  echo "  port: $METRICS_PORT"
  echo "  path: /metrics"
fi

# --- Проверка доступности endpoint ---
echo ""
echo "--- Проверка /metrics ---"
HARBOR_HOST=$(echo "$HARBOR_URL" | sed 's|https\?://||')
if curl -sf --max-time 5 "http://$HARBOR_HOST:$METRICS_PORT/metrics" | grep -q "harbor_" 2>/dev/null; then
  echo "[PASS] Endpoint /metrics доступен и возвращает метрики Harbor"
else
  echo "[WARN] Endpoint /metrics недоступен — Harbor требует перезапуска или метрики не включены"
fi

# --- Добавление target в Prometheus ---
echo ""
echo "--- Конфигурация Prometheus ---"
HARBOR_HOST_ONLY=$(echo "$HARBOR_URL" | sed 's|https\?://||' | cut -d/ -f1)
SCRAPE_CONFIG="
  - job_name: 'harbor'
    scheme: http
    metrics_path: /metrics
    static_configs:
      - targets: ['${HARBOR_HOST_ONLY}:${METRICS_PORT}']
        labels:
          instance: harbor
          environment: production
"

echo "Добавьте следующий блок в scrape_configs в $PROMETHEUS_CONFIG:"
echo ""
echo "$SCRAPE_CONFIG"

if [ -f "$PROMETHEUS_CONFIG" ]; then
  if grep -q "job_name: 'harbor'" "$PROMETHEUS_CONFIG"; then
    echo "[INFO] Target harbor уже присутствует в $PROMETHEUS_CONFIG"
  else
    echo "[INFO] Добавьте блок выше в $PROMETHEUS_CONFIG и перезагрузите Prometheus:"
    echo "       curl -X POST http://prometheus.internal:9090/-/reload"
  fi
fi

echo ""
echo "=== Настройка метрик Harbor завершена ==="
echo "Ключевые метрики для мониторинга:"
echo "  harbor_project_total          — количество проектов"
echo "  harbor_artifact_pulled_total  — число операций pull"
echo "  harbor_storage_used_bytes     — использование хранилища"
echo "  harbor_health                 — состояние компонентов"
