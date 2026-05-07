#!/usr/bin/env bash
# Обработчик оповещений Falco: отправка в Alertmanager и Loki
# Запускается как program_output Falco или через webhook
# Использование: echo '<JSON>' | bash falco-alert-handler.sh
#   или: bash falco-alert-handler.sh --test
set -euo pipefail

ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://alertmanager.internal:9093}"
LOKI_URL="${LOKI_URL:-http://loki.internal:3100}"
ALERT_LABELS="${ALERT_LABELS:-host=$(hostname)}"
SEVERITY_MAP_HIGH="container_escape_attempt,write_below_binary_dir,mkdir_binary_dir"
SEVERITY_MAP_WARN="read_sensitive_file_trusted_after_startup,modify_binary_dirs"
LOG_FILE="${FALCO_HANDLER_LOG:-/var/log/falco-handler.log}"
TEST_MODE="${1:-}"

# ── Читаем событие из stdin или тест ─────────────────────────────────────────
if [ "$TEST_MODE" = "--test" ]; then
  INPUT='{
    "output": "23:15:02.123456789: Warning Sensitive file opened for reading by non-trusted program (user=root command=cat /etc/shadow file=/etc/shadow)",
    "priority": "WARNING",
    "rule": "read_sensitive_file_trusted_after_startup",
    "time": "2024-01-15T23:15:02.123456789Z",
    "output_fields": {
      "container.id": "abc123def456",
      "container.name": "api-service",
      "proc.name": "cat",
      "user.name": "root",
      "fd.name": "/etc/shadow"
    }
  }'
  echo "=== ТЕСТОВЫЙ РЕЖИМ ==="
else
  INPUT=$(cat)
fi

# ── Парсинг JSON события ──────────────────────────────────────────────────────
parse() { echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('$1',''))" 2>/dev/null || echo ""; }

RULE=$(parse rule)
PRIORITY=$(parse priority)
OUTPUT=$(parse output)
EVENT_TIME=$(parse time)
CONTAINER_ID=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('output_fields',{}).get('container.id','host'))" 2>/dev/null || echo "host")
CONTAINER_NAME=$(echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('output_fields',{}).get('container.name',''))" 2>/dev/null || echo "")

[ -z "$RULE" ] && { echo "Событие не распознано — пустой rule" >&2; exit 0; }

# ── Определение уровня серьёзности ────────────────────────────────────────────
AM_SEVERITY="warning"
case "${PRIORITY^^}" in
  CRITICAL|EMERGENCY) AM_SEVERITY="critical" ;;
  ERROR|ALERT)        AM_SEVERITY="critical" ;;
  WARNING)            AM_SEVERITY="warning" ;;
  NOTICE|INFO)        AM_SEVERITY="info" ;;
  DEBUG)              AM_SEVERITY="info" ;;
esac
if echo "$SEVERITY_MAP_HIGH" | grep -qw "$RULE"; then
  AM_SEVERITY="critical"
fi

# ── Логирование в файл ────────────────────────────────────────────────────────
{
  echo "$(date '+%Y-%m-%d %H:%M:%S') [$AM_SEVERITY] RULE=$RULE CONTAINER=${CONTAINER_NAME:-$CONTAINER_ID}"
  echo "  $OUTPUT"
} >> "$LOG_FILE" 2>/dev/null || true

# ── Отправка в Loki ───────────────────────────────────────────────────────────
send_to_loki() {
  local now_ns
  now_ns=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

  local payload
  payload=$(python3 -c "
import json
payload = {
  'streams': [{
    'stream': {
      'job': 'falco',
      'host': '$(hostname)',
      'severity': '$AM_SEVERITY',
      'rule': '$RULE',
      'container': '${CONTAINER_NAME:-$CONTAINER_ID}'
    },
    'values': [['$now_ns', json.dumps({
      'output': '''$OUTPUT''',
      'rule': '$RULE',
      'priority': '$PRIORITY',
      'container_id': '$CONTAINER_ID',
      'container_name': '${CONTAINER_NAME:-}'
    })]]
  }]
}
print(json.dumps(payload))
" 2>/dev/null)

  if [ -n "$payload" ]; then
    curl -sf --max-time 5 \
      -H "Content-Type: application/json" \
      -X POST "$LOKI_URL/loki/api/v1/push" \
      -d "$payload" >/dev/null 2>&1 && return 0 || return 1
  fi
  return 1
}

# ── Отправка в Alertmanager ───────────────────────────────────────────────────
send_to_alertmanager() {
  local alert_payload
  alert_payload=$(python3 -c "
import json
alert = [{
  'labels': {
    'alertname': 'FalcoAlert',
    'severity': '$AM_SEVERITY',
    'rule': '$RULE',
    'host': '$(hostname)',
    'container': '${CONTAINER_NAME:-$CONTAINER_ID}'
  },
  'annotations': {
    'summary': 'Falco: $RULE',
    'description': '''$OUTPUT''',
    'priority': '$PRIORITY'
  },
  'generatorURL': 'http://$(hostname):8765/falco'
}]
print(json.dumps(alert))
" 2>/dev/null)

  if [ -n "$alert_payload" ]; then
    curl -sf --max-time 5 \
      -H "Content-Type: application/json" \
      -X POST "$ALERTMANAGER_URL/api/v2/alerts" \
      -d "$alert_payload" >/dev/null 2>&1 && return 0 || return 1
  fi
  return 1
}

# ── Выполнение отправки ───────────────────────────────────────────────────────
loki_ok=false
am_ok=false

send_to_loki   && loki_ok=true   || true
send_to_alertmanager && am_ok=true || true

if [ "$TEST_MODE" = "--test" ]; then
  echo ""
  echo "Событие: $RULE ($PRIORITY → $AM_SEVERITY)"
  echo "Контейнер: ${CONTAINER_NAME:-$CONTAINER_ID}"
  $loki_ok && echo "[OK] Loki: отправлено" || echo "[FAIL] Loki: не отправлено ($LOKI_URL)"
  $am_ok   && echo "[OK] Alertmanager: отправлено" || echo "[FAIL] Alertmanager: не отправлено ($ALERTMANAGER_URL)"
fi

# Для критичных событий — также stderr для немедленного логирования systemd
if [ "$AM_SEVERITY" = "critical" ]; then
  echo "FALCO CRITICAL: $RULE — ${CONTAINER_NAME:-host} — $OUTPUT" >&2
fi

exit 0
