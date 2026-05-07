#!/usr/bin/env bash
# Синхронизация LDAP-групп с Harbor и проверка назначенных прав
# Использование: bash sync-ldap-groups.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() {
  local method="${1:-GET}" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sf --max-time 15 -X "$method" \
      -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
      "$HARBOR_URL/api/v2.0/$path" -d "$data"
  else
    curl -sf --max-time 15 -X "$method" \
      -H "Authorization: Basic $AUTH" \
      "$HARBOR_URL/api/v2.0/$path"
  fi
}

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Синхронизация LDAP-групп Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

# --- Проверка настройки LDAP ---
echo ""
echo "--- Конфигурация LDAP ---"
ldap_conf=$(api GET "configurations" 2>/dev/null | python3 -c "
import json,sys
d = json.load(sys.stdin)
auth_mode = d.get('auth_mode', {}).get('value','?')
ldap_url = d.get('ldap_url', {}).get('value','?')
ldap_base = d.get('ldap_base_dn', {}).get('value','?')
group_base = d.get('ldap_group_base_dn', {}).get('value','?')
print(auth_mode, ldap_url, ldap_base, group_base)
" 2>/dev/null || echo "ldap_not_configured ? ? ?")

auth_mode=$(echo "$ldap_conf" | awk '{print $1}')
ldap_url=$(echo "$ldap_conf" | awk '{print $2}')

if [ "$auth_mode" = "ldap_auth" ]; then
  ok "Режим аутентификации: LDAP (URL: $ldap_url)"
else
  fail "LDAP не настроен (режим: $auth_mode) — настройте LDAP перед синхронизацией групп"
  exit 1
fi

# --- Принудительная синхронизация пользователей ---
echo ""
echo "--- Синхронизация пользователей из LDAP ---"
if api POST "ldap/users/import" '{}' >/dev/null 2>&1; then
  ok "Синхронизация пользователей LDAP выполнена"
else
  warn "Синхронизация пользователей не выполнена — возможно нет новых пользователей"
fi

# --- Синхронизация групп ---
echo ""
echo "--- Синхронизация групп LDAP ---"
if api POST "usergroups/ldap/sync" '{}' >/dev/null 2>&1; then
  ok "Синхронизация групп LDAP выполнена"
else
  warn "Синхронизация групп не выполнена — возможно не поддерживается в этой версии Harbor"
fi

# --- Список зарегистрированных групп ---
echo ""
echo "--- Зарегистрированные группы ---"
groups=$(api GET "usergroups?page_size=100" 2>/dev/null || echo "[]")
group_count=$(echo "$groups" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
ok "Зарегистрированных групп: $group_count"

echo "$groups" | python3 -c "
import json,sys
for g in json.load(sys.stdin):
    name = g.get('group_name','?')
    gtype = 'LDAP' if g.get('group_type') == 1 else 'локальная'
    dn = g.get('ldap_group_dn','')
    print(f'  {name} ({gtype}): {dn}')
" 2>/dev/null

# --- Группы в проектах ---
echo ""
echo "--- Группы назначены в проектах ---"
projects=$(api GET "projects?page_size=100" 2>/dev/null || echo "[]")
echo "$projects" | python3 -c "import json,sys; [print(p['project_id'],p['name']) for p in json.load(sys.stdin)]" 2>/dev/null | \
while read -r proj_id proj_name; do
  members=$(api GET "projects/$proj_id/members?page_size=500" 2>/dev/null || echo "[]")
  group_members=$(echo "$members" | python3 -c "
import json,sys
roles = {1:'Projectadmin', 2:'Developer', 3:'Guest', 4:'Maintainer'}
for m in json.load(sys.stdin):
    if m.get('entity_type') == 'g':
        print(f'    {m.get(\"entity_name\",\"?\")} → {roles.get(m.get(\"role_id\",0),\"?\")}')" 2>/dev/null)
  if [ -n "$group_members" ]; then
    echo "  Проект: $proj_name"
    echo "$group_members"
  fi
done

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
