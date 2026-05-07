#!/usr/bin/env bash
# Создание тишины в Alertmanager через API: подавление оповещений на плановое окно
# Использование: bash create-silence.sh [продолжительность] [метки...] [alertmanager_url]
# Примеры:
#   bash create-silence.sh 2h host=server01
#   bash create-silence.sh 4h severity=warning job=harbor
#   bash create-silence.sh 30m alertname=DiskSpaceLow environment=staging
set -euo pipefail

DURATION="${1:-1h}"
ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://alertmanager.internal:9093}"
COMMENT="${SILENCE_COMMENT:-Плановое обслуживание}"
CREATED_BY="${SILENCE_AUTHOR:-${USER:-ops-team}}"

shift 1 || true
MATCHERS=("$@")

# Если матчеры не переданы — интерактивный ввод
if [ "${#MATCHERS[@]}" -eq 0 ]; then
  echo "Матчеры не указаны. Примеры:"
  echo "  host=server01 severity=critical"
  echo "  alertname=VaultSealed"
  echo "  job=harbor"
  echo ""
  read -rp "Введите матчеры (key=value через пробел): " -a MATCHERS
fi

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Создание тишины в Alertmanager ==="
echo "URL:           $ALERTMANAGER_URL"
echo "Продолжительность: $DURATION"
echo "Матчеры:       ${MATCHERS[*]}"
echo "Комментарий:   $COMMENT"
echo "Автор:         $CREATED_BY"

# --- Проверка Alertmanager ---
echo ""
echo "--- Alertmanager ---"
if curl -sf --max-time 5 "$ALERTMANAGER_URL/-/healthy" >/dev/null 2>&1; then
  ok "Alertmanager доступен"
else
  fail "Alertmanager недоступен: $ALERTMANAGER_URL"
  exit 1
fi

# --- Вычисление времени ---
now_iso=$(python3 -c "
from datetime import datetime, timezone
print(datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))
")

# Разбор продолжительности
end_iso=$(python3 -c "
from datetime import datetime, timezone, timedelta
import re

dur = '$DURATION'
total_seconds = 0
for match in re.findall(r'(\d+)([smhd])', dur):
    val, unit = int(match[0]), match[1]
    if unit == 's': total_seconds += val
    elif unit == 'm': total_seconds += val * 60
    elif unit == 'h': total_seconds += val * 3600
    elif unit == 'd': total_seconds += val * 86400

if total_seconds == 0:
    total_seconds = 3600

end = datetime.now(timezone.utc) + timedelta(seconds=total_seconds)
print(end.strftime('%Y-%m-%dT%H:%M:%S.000Z'))
print(total_seconds)
")
end_time=$(echo "$end_iso" | head -1)
total_sec=$(echo "$end_iso" | tail -1)

ok "Начало:  $now_iso"
ok "Конец:   $end_time (${DURATION})"

# --- Формирование матчеров ---
MATCHERS_JSON=$(python3 -c "
import json
matchers = []
for m in ${MATCHERS[@]+"${MATCHERS[@]@Q}".split()}" do
    # Обрабатываем key=value и key!=value и key=~value
    pass
" 2>/dev/null || python3 - <<PYEOF
import json, sys
matchers_raw = sys.argv[1:]
matchers = []
for m in matchers_raw:
    if '=~' in m:
        k, v = m.split('=~', 1)
        matchers.append({'name': k, 'value': v, 'isRegex': True, 'isEqual': True})
    elif '!=' in m:
        k, v = m.split('!=', 1)
        matchers.append({'name': k, 'value': v, 'isRegex': False, 'isEqual': False})
    elif '=' in m:
        k, v = m.split('=', 1)
        matchers.append({'name': k, 'value': v, 'isRegex': False, 'isEqual': True})
if not matchers:
    matchers.append({'name': 'severity', 'value': 'warning', 'isRegex': False, 'isEqual': True})
print(json.dumps(matchers))
PYEOF
${MATCHERS[@]})

PAYLOAD=$(python3 -c "
import json, sys

matchers_raw = '''${MATCHERS[*]:-severity=info}'''.split()
matchers = []
for m in matchers_raw:
    if '!=' in m and '=~' not in m:
        k, v = m.split('!=', 1)
        matchers.append({'name': k, 'value': v, 'isRegex': False, 'isEqual': False})
    elif '=~' in m:
        k, v = m.split('=~', 1)
        matchers.append({'name': k, 'value': v, 'isRegex': True, 'isEqual': True})
    elif '=' in m:
        k, v = m.split('=', 1)
        matchers.append({'name': k, 'value': v, 'isRegex': False, 'isEqual': True})

payload = {
    'matchers': matchers,
    'startsAt': '$now_iso',
    'endsAt': '$end_time',
    'createdBy': '$CREATED_BY',
    'comment': '$COMMENT — создано: $(date +%Y-%m-%d)'
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
")

echo ""
echo "--- Payload ---"
echo "$PAYLOAD" | python3 -m json.tool 2>/dev/null || echo "$PAYLOAD"

# --- Создание тишины ---
echo ""
echo "--- Создание ---"
response=$(curl -sf --max-time 10 \
  -X POST \
  -H "Content-Type: application/json" \
  "$ALERTMANAGER_URL/api/v2/silences" \
  -d "$PAYLOAD" 2>/dev/null || echo "{}")

silence_id=$(echo "$response" | python3 -c "import json,sys; print(json.load(sys.stdin).get('silenceID',''))" 2>/dev/null || echo "")

if [ -n "$silence_id" ]; then
  ok "Тишина создана (ID: $silence_id)"
  ok "Активна до: $end_time"
else
  fail "Не удалось создать тишину: $response"
  exit 1
fi

# --- Проверка ---
echo ""
echo "--- Активные тишины ---"
curl -sf --max-time 5 "$ALERTMANAGER_URL/api/v2/silences" 2>/dev/null | \
  python3 -c "
import json,sys
from datetime import datetime, timezone
silences = json.load(sys.stdin)
active = [s for s in silences if s.get('status',{}).get('state') == 'active']
print(f'Активных тишин: {len(active)}')
for s in active:
    sid = s.get('id','?')[:8]
    end = s.get('endsAt','?')[:16]
    author = s.get('createdBy','?')
    comment = s.get('comment','')[:40]
    matchers = ', '.join(f\"{m['name']}={m['value']}\" for m in s.get('matchers',[]))
    print(f'  [{sid}...] до {end} | {matchers} | {author}: {comment}')
" 2>/dev/null || warn "Не удалось получить список тишин"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Управление тишинами:"
echo "  Просмотр:  $ALERTMANAGER_URL/#/silences"
echo "  Удаление:  curl -X DELETE $ALERTMANAGER_URL/api/v2/silences/$silence_id"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
