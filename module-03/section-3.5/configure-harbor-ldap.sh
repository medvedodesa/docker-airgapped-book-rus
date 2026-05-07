#!/usr/bin/env bash
# Настройка LDAP-аутентификации Harbor через API
# Использование: bash configure-harbor-ldap.sh <harbor_url> <admin_pass> <ldap_url> <bind_dn> <bind_pass> <base_dn>
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
ADMIN_PASS="${2:-Harbor12345}"
LDAP_URL="${3:-ldaps://ldap.internal.company.local}"
BIND_DN="${4:-CN=harbor-svc,OU=ServiceAccounts,DC=company,DC=local}"
BIND_PASS="${5:-}"
BASE_DN="${6:-OU=Users,DC=company,DC=local}"
UID_ATTR="${7:-sAMAccountName}"
GROUP_BASE_DN="${8:-OU=Groups,DC=company,DC=local}"

API="$HARBOR_URL/api/v2.0"
AUTH="-u admin:$ADMIN_PASS"

echo "=== Настройка LDAP для Harbor ==="
echo "  Harbor:   $HARBOR_URL"
echo "  LDAP:     $LDAP_URL"
echo "  Base DN:  $BASE_DN"

# 1. Тест соединения
echo ""
echo "--- Тест LDAP-соединения ---"
test_payload=$(cat << EOF
{
  "ldap_url": "$LDAP_URL",
  "ldap_search_dn": "$BIND_DN",
  "ldap_search_password": "$BIND_PASS",
  "ldap_base_dn": "$BASE_DN",
  "ldap_uid": "$UID_ATTR"
}
EOF
)

http_code=$(curl -sk $AUTH -o /tmp/ldap_test_result.json -w "%{http_code}" \
  -X POST "$API/ldap/ping" \
  -H "Content-Type: application/json" \
  -d "$test_payload" 2>/dev/null)

if [ "$http_code" = "200" ]; then
  echo "  [OK] LDAP-соединение успешно"
else
  echo "  [FAIL] LDAP-соединение не удалось (HTTP $http_code)"
  cat /tmp/ldap_test_result.json 2>/dev/null
  exit 1
fi

# 2. Применение конфигурации
echo ""
echo "--- Применение конфигурации LDAP ---"
config_payload=$(cat << EOF
{
  "auth_mode": "ldap_auth",
  "ldap_url": "$LDAP_URL",
  "ldap_search_dn": "$BIND_DN",
  "ldap_search_password": "$BIND_PASS",
  "ldap_base_dn": "$BASE_DN",
  "ldap_uid": "$UID_ATTR",
  "ldap_group_base_dn": "$GROUP_BASE_DN",
  "ldap_group_attribute_name": "cn",
  "ldap_group_search_filter": "(objectClass=group)",
  "ldap_scope": 2,
  "ldap_group_membership_attribute": "memberOf",
  "ldap_verify_cert": true
}
EOF
)

http_code=$(curl -sk $AUTH -o /dev/null -w "%{http_code}" \
  -X PUT "$API/configurations" \
  -H "Content-Type: application/json" \
  -d "$config_payload" 2>/dev/null)

[ "$http_code" = "200" ] && echo "  [OK] LDAP-конфигурация применена" || \
  { echo "  [FAIL] Ошибка применения: HTTP $http_code"; exit 1; }

echo ""
echo "=== LDAP настроен ==="
echo "  ВАЖНО: теперь все локальные пользователи (кроме admin) потеряют доступ!"
echo "  Войдите в Harbor с LDAP-учётными данными для проверки."
