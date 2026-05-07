#!/usr/bin/env bash
# Тестирование входа пользователя через LDAP в Harbor
# Использование: bash test-harbor-ldap-login.sh [harbor_url] [test_user] [test_pass] [admin_user] [admin_pass]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
TEST_USER="${2:-${LDAP_TEST_USER:-}}"
TEST_PASS="${3:-${LDAP_TEST_PASS:-}}"
ADMIN_USER="${4:-admin}"
ADMIN_PASS="${5:-${HARBOR_PASSWORD:-}}"

if [ -z "$TEST_USER" ] || [ -z "$TEST_PASS" ]; then
  echo "Укажите тестового пользователя LDAP:"
  echo "  Переменные: LDAP_TEST_USER, LDAP_TEST_PASS"
  echo "  Или аргументы: bash $0 [harbor_url] [test_user] [test_pass]"
  exit 1
fi

HARBOR_HOST=$(echo "$HARBOR_URL" | sed 's|https\?://||' | cut -d/ -f1)
ADMIN_AUTH=$(echo -n "$ADMIN_USER:$ADMIN_PASS" | base64)
api_admin() { curl -sf --max-time 15 -H "Authorization: Basic $ADMIN_AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Тестирование LDAP-аутентификации в Harbor ==="
echo "Реестр:          $HARBOR_URL"
echo "Тестовый юзер:   $TEST_USER"
echo "Дата:            $(date '+%Y-%m-%d %H:%M')"

# --- Проверка LDAP-режима ---
echo ""
echo "--- Режим аутентификации ---"
auth_mode=$(api_admin "configurations" | python3 -c "
import json,sys; d=json.load(sys.stdin); print(d.get('auth_mode',{}).get('value','?'))" 2>/dev/null || echo "?")
if [ "$auth_mode" = "ldap_auth" ]; then
  ok "Harbor настроен на LDAP-аутентификацию"
else
  fail "Режим аутентификации: $auth_mode (ожидается ldap_auth)"
  exit 1
fi

# --- Тест входа через Harbor API ---
echo ""
echo "--- Тест аутентификации через Harbor API ---"
TEST_AUTH=$(echo -n "$TEST_USER:$TEST_PASS" | base64)
login_result=$(curl -sf --max-time 10 \
  -H "Authorization: Basic $TEST_AUTH" \
  "$HARBOR_URL/api/v2.0/users/current" 2>/dev/null || echo "")

if echo "$login_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('username',''))" 2>/dev/null | grep -q .; then
  returned_user=$(echo "$login_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('username',''))" 2>/dev/null)
  ok "Аутентификация API: успешно (вернулся username: $returned_user)"

  is_admin=$(echo "$login_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sysadmin_flag',False))" 2>/dev/null || echo false)
  if [ "$is_admin" = "True" ] || [ "$is_admin" = "true" ]; then
    warn "Пользователь $TEST_USER имеет права системного администратора Harbor"
  else
    ok "Права системного администратора: нет"
  fi
else
  fail "Аутентификация API: неудача (пользователь $TEST_USER / неверный пароль или LDAP недоступен)"
fi

# --- Тест docker login ---
echo ""
echo "--- Тест docker login ---"
if echo "$TEST_PASS" | docker login "$HARBOR_HOST" -u "$TEST_USER" --password-stdin >/dev/null 2>&1; then
  ok "docker login $HARBOR_HOST от имени $TEST_USER: успешно"
  docker logout "$HARBOR_HOST" >/dev/null 2>&1 || true
else
  fail "docker login $HARBOR_HOST от имени $TEST_USER: неудача"
fi

# --- Список проектов доступных пользователю ---
echo ""
echo "--- Доступные проекты ---"
user_projects=$(curl -sf --max-time 15 \
  -H "Authorization: Basic $TEST_AUTH" \
  "$HARBOR_URL/api/v2.0/projects?page_size=50" 2>/dev/null | \
  python3 -c "
import json,sys
projects = json.load(sys.stdin)
print(f'   Проектов доступно: {len(projects)}')
for p in projects[:10]:
    role = p.get('role_id',0)
    roles = {1:'Projectadmin', 2:'Developer', 3:'Guest', 4:'Maintainer'}
    print(f'   {p.get(\"name\",\"?\")}: {roles.get(role,\"?\")}')
if len(projects) > 10:
    print(f'   ... и ещё {len(projects)-10}')
" 2>/dev/null || echo "   (данные недоступны)")
echo "$user_projects"

# --- Сохранение результата ---
RESULT_FILE="ldap-integration-test-$(date +%Y%m%d).txt"
{
  echo "# Результат теста LDAP-аутентификации Harbor"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M')"
  echo "# Реестр: $HARBOR_URL"
  echo "# Тестовый пользователь: $TEST_USER"
  echo "# PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
} > "$RESULT_FILE"
echo ""
echo "Результат сохранён: $RESULT_FILE (артефакт R-3.5-1)"

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
