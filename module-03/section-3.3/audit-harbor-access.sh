#!/usr/bin/env bash
# Отчёт о правах доступа всех пользователей и Robot Accounts по проектам Harbor
# Использование: bash audit-harbor-access.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
OUTPUT="${HARBOR_ACCESS_AUDIT:-harbor-access-audit-$(date +%Y%m%d).txt}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 15 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

role_name() {
  case "$1" in
    1) echo "Projectadmin" ;;
    2) echo "Developer" ;;
    3) echo "Guest" ;;
    4) echo "Maintainer" ;;
    *) echo "Роль:$1" ;;
  esac
}

echo "=== Аудит прав доступа Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Аудит прав доступа Harbor"
  echo "# Реестр: $HARBOR_URL  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # Системные администраторы
  echo "## Системные администраторы"
  users=$(api "users?page_size=500" 2>/dev/null || echo "[]")
  echo "$users" | python3 -c "
import json,sys
for u in json.load(sys.stdin):
    if u.get('sysadmin_flag'):
        name = u.get('username','?')
        email = u.get('email','')
        print(f'   {name} ({email})')
" 2>/dev/null || echo "   (недоступно)"
  echo ""

  # Права по проектам
  echo "## Права по проектам"
  projects=$(api "projects?page_size=100" 2>/dev/null || echo "[]")
  echo "$projects" | python3 -c "import json,sys; [print(p['name'],p['project_id']) for p in json.load(sys.stdin)]" 2>/dev/null | \
  while read -r proj_name proj_id; do
    echo "### Проект: $proj_name (id=$proj_id)"

    # Члены проекта (пользователи)
    members=$(api "projects/$proj_id/members?page_size=500" 2>/dev/null || echo "[]")
    member_count=$(echo "$members" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    echo "    Участников: $member_count"

    echo "$members" | python3 -c "
import json,sys
members = json.load(sys.stdin)
for m in members:
    etype = m.get('entity_type','?')
    ename = m.get('entity_name','?')
    role  = m.get('role_id', 0)
    roles = {1:'Projectadmin', 2:'Developer', 3:'Guest', 4:'Maintainer'}
    role_str = roles.get(role, f'role:{role}')
    marker = '[robot]' if etype == 'r' else ''
    print(f'    {ename:<35} {role_str:<15} {marker}')
" 2>/dev/null || echo "    (данные недоступны)"
    echo ""
  done

  # Итоговая статистика
  echo "## Итоговая статистика"
  total_users=$(echo "$users" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  admin_count=$(echo "$users" | python3 -c "import json,sys; print(sum(1 for u in json.load(sys.stdin) if u.get('sysadmin_flag')))" 2>/dev/null || echo 0)
  echo "   Пользователей всего:       $total_users"
  echo "   Системных администраторов: $admin_count"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
echo "Рекомендация: проверьте, что каждый пользователь в роли Projectadmin обоснован."
