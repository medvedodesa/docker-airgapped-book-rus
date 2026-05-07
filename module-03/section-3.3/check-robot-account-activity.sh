#!/usr/bin/env bash
# Отчёт об активности Robot Accounts в Harbor за указанный период
# Использование: bash check-robot-account-activity.sh [harbor_url] [пользователь] [пароль] [дней]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
DAYS="${4:-30}"
OUTPUT="${ROBOT_ACTIVITY_OUTPUT:-robot-activity-$(date +%Y%m%d).txt}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 15 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

echo "=== Отчёт об активности Robot Accounts ==="
echo "Реестр: $HARBOR_URL"
echo "Период: последние $DAYS дней"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Отчёт об активности Robot Accounts"
  echo "# Реестр: $HARBOR_URL  |  Период: $DAYS дней  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # Получаем все Robot Accounts (системного уровня)
  echo "## Системные Robot Accounts"
  robots=$(api "robots?page_size=100&level=system" 2>/dev/null || echo "[]")
  robot_count=$(echo "$robots" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  echo "   Всего: $robot_count"
  echo ""

  now_epoch=$(date +%s)
  warning_count=0

  echo "$robots" | python3 -c "
import json, sys, time
from datetime import datetime

robots = json.load(sys.stdin)
days = int('$DAYS')
now = int('$now_epoch')
cutoff = now - days * 86400

print(f'   {\"Имя\":<40} {\"Истекает\":<20} {\"Статус\":<12} {\"Предупреждение\"}')
print(f'   {\"-\"*40} {\"-\"*20} {\"-\"*12} {\"-\"*20}')

for r in robots:
    name = r.get('name', '?')
    enabled = r.get('disable', False)
    status = 'отключён' if enabled else 'активен'
    exp = r.get('expires_at', -1)

    if exp == -1:
        exp_str = 'бессрочный'
        warning = ''
    else:
        exp_dt = datetime.fromtimestamp(exp)
        exp_str = exp_dt.strftime('%Y-%m-%d')
        days_left = (exp - now) // 86400
        if days_left < 0:
            warning = 'ИСТЁК'
        elif days_left < 14:
            warning = f'истекает через {days_left} дн.'
        else:
            warning = ''

    print(f'   {name:<40} {exp_str:<20} {status:<12} {warning}')
" 2>/dev/null || echo "   (данные недоступны)"

  echo ""

  # Robot Accounts на уровне проектов
  echo "## Robot Accounts по проектам"
  projects=$(api "projects?page_size=100" 2>/dev/null || echo "[]")
  echo "$projects" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    print(p['name'])
" 2>/dev/null | while read -r project; do
    proj_robots=$(api "robots?page_size=100&level=project&q=ProjectName%3D$project" 2>/dev/null || echo "[]")
    count=$(echo "$proj_robots" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
      echo "   Проект $project: $count Robot Account(s)"
    fi
  done

  echo ""
  echo "## Аудит-журнал: операции Robot Accounts за $DAYS дней"
  audit=$(api "audit-logs?page_size=500" 2>/dev/null || echo "[]")
  echo "$audit" | python3 -c "
import json, sys, time
from datetime import datetime

logs = json.load(sys.stdin)
days = int('$DAYS')
now = int('$now_epoch')
cutoff = now - days * 86400

robot_ops = {}
for entry in logs:
    username = entry.get('username', '')
    if not username.startswith('robot\$'):
        continue
    op_time = entry.get('op_time', '')
    try:
        epoch = int(datetime.fromisoformat(op_time.replace('Z','+00:00')).timestamp())
    except Exception:
        continue
    if epoch < cutoff:
        continue
    op = entry.get('operation', '?')
    resource = entry.get('resource_type', '?')
    robot_ops.setdefault(username, {}).setdefault(op, 0)
    robot_ops[username][op] += 1

if not robot_ops:
    print('   Операций Robot Accounts за период не обнаружено')
else:
    for robot, ops in sorted(robot_ops.items()):
        ops_str = ', '.join(f'{k}={v}' for k,v in ops.items())
        print(f'   {robot}: {ops_str}')
" 2>/dev/null || echo "   (журнал аудита недоступен)"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
