#!/usr/bin/env bash
# Настройка Grafana provisioning: datasources и дашборды из репозитория
# Использование: bash setup-grafana-provisioning.sh [grafana_data_dir] [prometheus_url] [loki_url]
set -euo pipefail

GRAFANA_DATA="${1:-${GRAFANA_DATA_DIR:-/var/lib/grafana}}"
PROMETHEUS_URL="${2:-${PROMETHEUS_URL:-http://prometheus.internal:9090}}"
LOKI_URL="${3:-${LOKI_URL:-http://loki.internal:3100}}"
GRAFANA_URL="${GRAFANA_URL:-http://grafana.internal:3000}"
GRAFANA_ADMIN_PASS="${GF_SECURITY_ADMIN_PASSWORD:-admin}"
DASHBOARDS_DIR="$(dirname "$0")/dashboards"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Настройка Grafana provisioning ==="
echo "Grafana data: $GRAFANA_DATA"
echo "Prometheus:   $PROMETHEUS_URL"
echo "Loki:         $LOKI_URL"
echo "Дата:         $(date '+%Y-%m-%d %H:%M')"

# --- Директории provisioning ---
echo ""
echo "--- Структура директорий ---"
PROV_DIR="$GRAFANA_DATA/provisioning"
mkdir -p "$PROV_DIR/datasources" "$PROV_DIR/dashboards" "$GRAFANA_DATA/dashboards"
ok "Директории provisioning созданы"

# --- Datasources ---
echo ""
echo "--- Datasources ---"
cat > "$PROV_DIR/datasources/datasources.yaml" <<YAML
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: $PROMETHEUS_URL
    isDefault: true
    editable: false
    jsonData:
      timeInterval: "15s"
      queryTimeout: "60s"
      httpMethod: POST
    version: 1

  - name: Loki
    type: loki
    access: proxy
    url: $LOKI_URL
    isDefault: false
    editable: false
    jsonData:
      maxLines: 1000
      derivedFields:
        - datasourceUid: prometheus
          matcherRegex: "trace_id=(\\w+)"
          name: TraceID
          url: "\${__value.raw}"
    version: 1
YAML
ok "Datasources настроены: Prometheus + Loki"

# --- Dashboard provisioner ---
cat > "$PROV_DIR/dashboards/dashboards.yaml" <<YAML
apiVersion: 1

providers:
  - name: 'Air-Gap Infrastructure'
    orgId: 1
    folder: 'Infrastructure'
    folderUid: 'infra'
    type: file
    disableDeletion: true
    updateIntervalSeconds: 60
    allowUiUpdates: false
    options:
      path: $GRAFANA_DATA/dashboards
      foldersFromFilesStructure: true
YAML
ok "Dashboard provisioner настроен"

# --- Копируем дашборды из репозитория ---
echo ""
echo "--- Дашборды ---"
if [ -d "$DASHBOARDS_DIR" ]; then
  cp -r "$DASHBOARDS_DIR"/. "$GRAFANA_DATA/dashboards/"
  dash_count=$(find "$GRAFANA_DATA/dashboards" -name "*.json" 2>/dev/null | wc -l)
  ok "Скопировано дашбордов: $dash_count"
else
  warn "Директория дашбордов не найдена: $DASHBOARDS_DIR"
  warn "Создайте JSON-дашборды в $DASHBOARDS_DIR/ и перезапустите скрипт"
fi

# --- Проверка прав ---
if id grafana &>/dev/null 2>&1; then
  chown -R grafana:grafana "$GRAFANA_DATA/provisioning" "$GRAFANA_DATA/dashboards" 2>/dev/null && \
    ok "Права установлены для пользователя grafana" || true
fi

# --- Проверка Grafana ---
echo ""
echo "--- Проверка Grafana ---"
if curl -sf --max-time 5 "$GRAFANA_URL/api/health" >/dev/null 2>&1; then
  ok "Grafana доступна: $GRAFANA_URL"

  # Перезагрузка provisioning через API
  reload_result=$(curl -sf --max-time 10 \
    -u "admin:$GRAFANA_ADMIN_PASS" \
    -X POST "$GRAFANA_URL/api/admin/provisioning/dashboards/reload" 2>/dev/null && echo "ok" || echo "fail")
  [ "$reload_result" = "ok" ] && ok "Provisioning перезагружен" || \
    warn "Перезагрузка не удалась — перезапустите Grafana: docker compose restart grafana"

  # Проверка datasources
  ds_count=$(curl -sf --max-time 5 \
    -u "admin:$GRAFANA_ADMIN_PASS" \
    "$GRAFANA_URL/api/datasources" 2>/dev/null | \
    python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  ok "Datasources в Grafana: $ds_count"

  # Проверка дашбордов
  db_count=$(curl -sf --max-time 5 \
    -u "admin:$GRAFANA_ADMIN_PASS" \
    "$GRAFANA_URL/api/search?type=dash-db" 2>/dev/null | \
    python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  ok "Дашбордов в Grafana: $db_count"
else
  warn "Grafana недоступна — настройки будут применены при следующем запуске"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Grafana UI: $GRAFANA_URL"
echo "Provisioning: $PROV_DIR"
echo ""
echo "ВАЖНО: Все изменения дашбордов делайте в $DASHBOARDS_DIR/,"
echo "        а не через UI — иначе изменения потеряются при перезапуске."
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
