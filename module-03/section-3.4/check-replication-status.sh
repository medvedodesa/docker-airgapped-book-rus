#!/usr/bin/env bash
# Мониторинг статуса всех заданий репликации Harbor
# Использование: bash check-replication-status.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
FAIL_ON_ERROR="${FAIL_ON_ERROR:-true}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 15 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Статус репликации Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

# --- Политики репликации ---
echo ""
echo "--- Политики репликации ---"
policies=$(api "replication/policies?page_size=100" 2>/dev/null || echo "[]")
policy_count=$(echo "$policies" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
echo "Политик всего: $policy_count"
echo ""

echo "$policies" | python3 -c "import json,sys; [print(p['id'], p['name'], p.get('enabled',True)) for p in json.load(sys.stdin)]" 2>/dev/null | \
while read -r policy_id policy_name enabled; do
  echo "  Политика: $policy_name (id=$policy_id, включена=$enabled)"

  # Последнее выполнение
  executions=$(api "replication/executions?policy_id=$policy_id&page_size=5" 2>/dev/null || echo "[]")
  echo "$executions" | python3 -c "
import json, sys
from datetime import datetime

execs = json.load(sys.stdin)
if not execs:
    print('    Выполнений не было')
else:
    e = execs[0]  # последнее
    status = e.get('status', '?')
    start_time = e.get('start_time', '')
    end_time = e.get('end_time', '')
    succeed = e.get('succeed', 0)
    failed = e.get('failed', 0)
    in_progress = e.get('in_progress', 0)
    stopped = e.get('stopped', 0)

    status_mark = '[PASS]' if status == 'Succeed' else '[FAIL]' if status in ('Failed','Stopped') else '[INFO]'
    print(f'    {status_mark} Последнее выполнение: {status}')
    print(f'    Начало: {start_time}  Конец: {end_time}')
    print(f'    Задач: успешно={succeed} ошибок={failed} в процессе={in_progress}')
    if failed > 0:
        print(f'    [WARN] Есть неудачные задачи: {failed}')
" 2>/dev/null
  echo ""
done

# --- Активные (in progress) выполнения ---
echo "--- Активные выполнения ---"
running=$(api "replication/executions?status=InProgress&page_size=20" 2>/dev/null || echo "[]")
running_count=$(echo "$running" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
if [ "$running_count" -gt 0 ]; then
  echo "$running" | python3 -c "
import json,sys
for e in json.load(sys.stdin):
    print(f'  В процессе: policy_id={e.get(\"policy_id\")} start={e.get(\"start_time\")} in_progress={e.get(\"in_progress\",0)}')
" 2>/dev/null
  warn "Активных выполнений репликации: $running_count"
else
  ok "Активных выполнений нет"
fi

# --- Неудачные выполнения за последние сутки ---
echo ""
echo "--- Ошибки репликации (последние 24 часа) ---"
failed_exec=$(api "replication/executions?status=Failed&page_size=50" 2>/dev/null || echo "[]")
failed_count=$(echo "$failed_exec" | python3 -c "
import json,sys,time
execs = json.load(sys.stdin)
cutoff = time.time() - 86400
count = 0
for e in execs:
    st = e.get('start_time','')
    try:
        import datetime
        epoch = datetime.datetime.fromisoformat(st.replace('Z','+00:00')).timestamp()
        if epoch > cutoff:
            count += 1
    except Exception:
        pass
print(count)
" 2>/dev/null || echo 0)

if [ "$failed_count" -gt 0 ]; then
  fail "Неудачных выполнений за 24 часа: $failed_count — проверьте задания через Harbor UI"
else
  ok "Неудачных выполнений за 24 часа: нет"
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ] && [ "$FAIL_ON_ERROR" = "true" ]; then
  exit 1
fi
exit 0
