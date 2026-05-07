#!/usr/bin/env bash
# Добавление нового сервиса в конфигурацию Prometheus с горячей перезагрузкой
# Использование: bash add-service-target.sh <имя_сервиса> <хост:порт> [prometheus_config] [prometheus_url]
set -euo pipefail

SERVICE_NAME="${1:-}"
SERVICE_ENDPOINT="${2:-}"
PROM_CONFIG="${3:-${PROMETHEUS_CONFIG:-/etc/prometheus/prometheus.yml}}"
PROMETHEUS_URL="${4:-${PROMETHEUS_URL:-http://prometheus.internal:9090}}"
METRICS_PATH="${METRICS_PATH:-/metrics}"
SCRAPE_INTERVAL="${SCRAPE_INTERVAL:-15s}"
LABELS="${SERVICE_LABELS:-}"

if [ -z "$SERVICE_NAME" ] || [ -z "$SERVICE_ENDPOINT" ]; then
  echo "Использование: bash $0 <имя_сервиса> <хост:порт> [prometheus.yml] [prometheus_url]"
  echo ""
  echo "Примеры:"
  echo "  bash $0 harbor harbor.internal:9090"
  echo "  bash $0 vault vault.internal:8200 /etc/prometheus/prometheus.yml http://prometheus.internal:9090"
  echo "  METRICS_PATH=/metrics SCRAPE_INTERVAL=30s bash $0 myapp myapp.internal:8080"
  exit 1
fi

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Добавление сервиса в Prometheus ==="
echo "Сервис:   $SERVICE_NAME"
echo "Endpoint: $SERVICE_ENDPOINT"
echo "Путь:     $METRICS_PATH"
echo "Конфиг:   $PROM_CONFIG"

# --- Проверка endpoint ---
echo ""
echo "--- Проверка доступности ---"
host=$(echo "$SERVICE_ENDPOINT" | cut -d: -f1)
port=$(echo "$SERVICE_ENDPOINT" | cut -d: -f2)
metrics_url="http://$SERVICE_ENDPOINT$METRICS_PATH"

if curl -sf --max-time 5 "$metrics_url" | grep -q "^#" 2>/dev/null; then
  ok "Endpoint отвечает в формате Prometheus: $metrics_url"
  metric_count=$(curl -sf --max-time 5 "$metrics_url" 2>/dev/null | grep -c "^# HELP" || echo 0)
  ok "Метрик доступно: $metric_count"
else
  warn "Endpoint недоступен или не возвращает метрики Prometheus: $metrics_url"
  echo "    Продолжаем — сервис может быть недоступен временно"
fi

# --- Проверка конфигурационного файла ---
echo ""
echo "--- Конфигурация Prometheus ---"
[ -f "$PROM_CONFIG" ] || { fail "Файл конфигурации не найден: $PROM_CONFIG"; exit 1; }

# Проверяем что job уже не существует
if grep -q "job_name: '$SERVICE_NAME'" "$PROM_CONFIG" 2>/dev/null || \
   grep -q "job_name: \"$SERVICE_NAME\"" "$PROM_CONFIG" 2>/dev/null; then
  warn "Job '$SERVICE_NAME' уже существует в конфигурации"
  echo "    Текущая конфигурация:"
  python3 -c "
import yaml
with open('$PROM_CONFIG') as f:
    cfg = yaml.safe_load(f)
for job in cfg.get('scrape_configs', []):
    if job.get('job_name') == '$SERVICE_NAME':
        print('   ', yaml.dump(job, default_flow_style=False).strip())
" 2>/dev/null || grep -A 10 "job_name: '$SERVICE_NAME'" "$PROM_CONFIG" | head -12
  echo ""
  echo "Пропуск добавления — job уже существует."
  exit 0
fi

# --- Формирование нового job ---
EXTRA_LABELS=""
if [ -n "$LABELS" ]; then
  EXTRA_LABELS=$(echo "$LABELS" | tr ',' '\n' | while IFS='=' read -r k v; do
    echo "          $k: $v"
  done)
fi

NEW_JOB=$(cat <<YAML

  - job_name: '$SERVICE_NAME'
    scrape_interval: $SCRAPE_INTERVAL
    metrics_path: '$METRICS_PATH'
    static_configs:
      - targets: ['$SERVICE_ENDPOINT']
        labels:
          service: '$SERVICE_NAME'
          environment: production
$([ -n "$EXTRA_LABELS" ] && echo "$EXTRA_LABELS")
YAML
)

# --- Резервная копия ---
cp "$PROM_CONFIG" "${PROM_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
ok "Резервная копия создана"

# --- Добавление в конфиг ---
echo ""
echo "--- Добавление job ---"
echo "$NEW_JOB" >> "$PROM_CONFIG"
ok "Job '$SERVICE_NAME' добавлен в $PROM_CONFIG"

# --- Валидация YAML ---
if command -v python3 &>/dev/null; then
  python3 -c "
import yaml, sys
try:
    with open('$PROM_CONFIG') as f:
        yaml.safe_load(f)
    print('YAML валиден')
except yaml.YAMLError as e:
    print(f'ОШИБКА YAML: {e}')
    sys.exit(1)
" 2>/dev/null && ok "YAML-синтаксис корректен" || {
    fail "YAML содержит ошибки — восстанавливаем резервную копию"
    cp "${PROM_CONFIG}.backup."* "$PROM_CONFIG" 2>/dev/null || true
    exit 1
  }
fi

# --- Горячая перезагрузка Prometheus ---
echo ""
echo "--- Перезагрузка Prometheus ---"
reload_result=$(curl -sf --max-time 10 -X POST "$PROMETHEUS_URL/-/reload" 2>/dev/null && echo "ok" || echo "fail")
if [ "$reload_result" = "ok" ]; then
  ok "Prometheus перезагружен: $PROMETHEUS_URL/-/reload"
  sleep 2
else
  warn "Горячая перезагрузка не удалась — перезапустите Prometheus вручную"
  echo "    docker compose restart prometheus"
  echo "    или: kill -HUP <pid prometheus>"
fi

# --- Проверка что target появился ---
echo ""
echo "--- Проверка цели в Prometheus ---"
sleep 3
target_status=$(curl -sf --max-time 10 \
  "$PROMETHEUS_URL/api/v1/targets" 2>/dev/null | \
  python3 -c "
import json,sys
data = json.load(sys.stdin)
for t in data.get('data',{}).get('activeTargets',[]):
    labels = t.get('labels',{})
    if labels.get('job') == '$SERVICE_NAME':
        health = t.get('health','?')
        last_err = t.get('lastError','')
        print(f'{health} {last_err}'.strip())
" 2>/dev/null || echo "")

if echo "$target_status" | grep -q "^up"; then
  ok "Цель активна: $SERVICE_NAME (up)"
elif echo "$target_status" | grep -q "^down"; then
  warn "Цель добавлена, но недоступна: $SERVICE_NAME (down) — ${target_status#down }"
elif [ -z "$target_status" ]; then
  warn "Цель не найдена в активных — возможно перезагрузка ещё не завершена"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Проверить в Prometheus UI:"
echo "  $PROMETHEUS_URL/targets?search=$SERVICE_NAME"
echo "  $PROMETHEUS_URL/graph?g0.expr=up{job=\"$SERVICE_NAME\"}"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
