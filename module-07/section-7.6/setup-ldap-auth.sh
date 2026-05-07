#!/usr/bin/env bash
# Настройка LDAP-аутентификации в Vault для пользователей AD/FreeIPA
# Использование: bash setup-ldap-auth.sh <ldap_url> <bind_dn> <bind_pass> <user_dn>
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
LDAP_URL="${1:-ldaps://ldap.internal.company.local:636}"
BIND_DN="${2:-cn=vault-bind,ou=service,dc=company,dc=local}"
BIND_PASS="${3:-}"
USER_DN="${4:-ou=users,dc=company,dc=local}"
GROUP_DN="${5:-ou=groups,dc=company,dc=local}"

export VAULT_ADDR

echo "=== Настройка LDAP-аутентификации ==="
echo "  LDAP URL:  $LDAP_URL"
echo "  User DN:   $USER_DN"

[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }
[ -n "$BIND_PASS" ] || { echo "[FAIL] Пароль bind-пользователя не задан"; exit 1; }

# Включение LDAP auth
echo ""
echo "--- Включение LDAP ---"
vault auth enable ldap 2>/dev/null || echo "  ldap уже включён"

# Конфигурация
echo ""
echo "--- Конфигурация подключения ---"
vault write auth/ldap/config \
  url="$LDAP_URL" \
  binddn="$BIND_DN" \
  bindpass="$BIND_PASS" \
  userdn="$USER_DN" \
  userattr="uid" \
  groupdn="$GROUP_DN" \
  groupattr="cn" \
  groupfilter="(|(memberUid={{.Username}})(member={{.UserDN}}))" \
  insecure_tls=false \
  starttls=false \
  tls_min_version="tls12" \
  2>/dev/null
echo "  [OK] LDAP подключение настроено"

# Маппинг групп на политики
echo ""
echo "--- Маппинг групп LDAP → политики Vault ---"

declare -A GROUP_POLICIES=(
  ["vault-admins"]="default,sys-admin"
  ["vault-ops"]="default,ops-viewer"
  ["vault-devs"]="default,app-prod-readonly"
  ["vault-ci"]="default,db-app-readonly"
)

for group in "${!GROUP_POLICIES[@]}"; do
  vault write "auth/ldap/groups/$group" \
    policies="${GROUP_POLICIES[$group]}" \
    2>/dev/null
  echo "  [OK] $group → ${GROUP_POLICIES[$group]}"
done

# Тест подключения (без пароля — только конфигурации)
echo ""
echo "--- Проверка конфигурации ---"
vault read auth/ldap/config 2>/dev/null | grep -E "url|userdn|groupdn|tls" | sed 's/^/  /'

echo ""
echo "=== LDAP-аутентификация настроена ==="
echo ""
echo "Тест входа пользователя:"
echo "  vault login -method=ldap username=<пользователь>"
echo ""
echo "Проверка групп конкретного пользователя:"
echo "  vault write auth/ldap/login/<username> password=<pass>"
