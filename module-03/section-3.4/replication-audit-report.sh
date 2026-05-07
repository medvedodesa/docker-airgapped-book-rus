#!/usr/bin/env bash
# Отчёт об истории репликации Harbor за указанный период
# Использование: bash replication-audit-report.sh [harbor_url] [пользователь] [пароль] [дней]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
DAYS="${4:-30}"
OUTPUT="${REPLICATION_AUDIT_OUTPUT:-replication-audit-$(date +%Y%m%d).txt}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 15 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

echo "=== Отчёт об истории репликации Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Период: последние $DAYS дней"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Отчёт об истории репликации Harbor"
  echo "# Реестр: $HARBOR_URL  |  Период: $DAYS дней  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # Политики
  policies=$(api "replication/policies?page_size=100" 2>/dev/null || echo "[]")

  echo "## Политики репликации"
  echo "$policies" | python3 -c "
import json,sys
policies = json.load(sys.stdin)
print(f'   Всего политик: {len(policies)}')
print()
for p in policies:
    name = p.get('name','?')
    enabled = p.get('enabled', True)
    trigger = p.get('trigger', {}).get('type','?')
    dest = p.get('dest_registry', {})
    dest_name = dest.get('name','локально') if dest else 'локально'
    status = 'включена' if enabled else 'отключена'
    print(f'   {name:<40} trigger={trigger:<12} dest={dest_name} [{status}]')
" 2>/dev/null || echo "   (данные недоступны)"
  echo ""

  # Выполнения
  echo "## История выполнений"
  echo "$policies" | python3 -c "import json,sys; [print(p['id'],p['name']) for p in json.load(sys.stdin)]" 2>/dev/null | \
  while read -r policy_id policy_name; do
    echo "### Политика: $policy_name"
    executions=$(api "replication/executions?policy_id=$policy_id&page_size=100" 2>/dev/null || echo "[]")

    echo "$executions" | python3 -c "
import json, sys, time
from datetime import datetime

execs = json.load(sys.stdin)
days = int('$DAYS')
cutoff = time.time() - days * 86400

total = succeed = failed = 0
rows = []
for e in execs:
    st = e.get('start_time','')
    try:
        epoch = datetime.fromisoformat(st.replace('Z','+00:00')).timestamp()
    except Exception:
        continue
    if epoch < cutoff:
        continue
    total += 1
    status = e.get('status','?')
    ok_count = e.get('succeed', 0)
    err_count = e.get('failed', 0)
    if status == 'Succeed':
        succeed += 1
    elif status in ('Failed','Stopped'):
        failed += 1
    rows.append(f'   {st[:19]}  {status:<10} успешно={ok_count} ошибок={err_count}')

print(f'   Выполнений за период: {total}  (успешно={succeed} неудачно={failed})')
if rows:
    print()
    for row in rows[:20]:  # последние 20
        print(row)
    if len(rows) > 20:
        print(f'   ... и ещё {len(rows)-20} записей')
else:
    print('   Выполнений за период не было')
" 2>/dev/null
    echo ""
  done

  # Сводка
  echo "## Сводка"
  total_policies=$(echo "$policies" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  enabled_policies=$(echo "$policies" | python3 -c "import json,sys; print(sum(1 for p in json.load(sys.stdin) if p.get('enabled',True)))" 2>/dev/null || echo 0)
  echo "   Политик всего:    $total_policies"
  echo "   Активных:         $enabled_policies"
  echo "   Период отчёта:    $DAYS дней"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
