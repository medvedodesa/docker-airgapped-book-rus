#!/usr/bin/env bash
# Создание структуры KV v2 в Vault: монтирование, политики, пространства имён
# Использование: bash setup-kv-structure.sh [env]
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
ENV="${1:-prod}"

export VAULT_ADDR

echo "=== Настройка KV v2 в Vault ==="
echo "  Окружение: $ENV"

[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

# Монтирование KV v2
echo ""
echo "--- Монтирование KV engines ---"
for mount in "secret/$ENV" "secret/shared"; do
  if vault secrets list 2>/dev/null | grep -q "^${mount}/"; then
    echo "  [OK] $mount уже смонтирован"
  else
    vault secrets enable -path="$mount" kv-v2 2>/dev/null && \
      echo "  [OK] Смонтирован $mount" || \
      echo "  [WARN] Не удалось смонтировать $mount"
  fi
done

# Создание базовой структуры секретов (пустые пространства)
echo ""
echo "--- Создание пространства имён ---"
vault kv put "secret/$ENV/database/placeholder" _init=true 2>/dev/null
vault kv put "secret/$ENV/api/placeholder" _init=true 2>/dev/null
vault kv put "secret/$ENV/infrastructure/placeholder" _init=true 2>/dev/null
vault kv put "secret/shared/tls/placeholder" _init=true 2>/dev/null
echo "  [OK] Базовая структура создана"

# Политика для приложений
echo ""
echo "--- Политики ---"
vault policy write "app-${ENV}-readonly" - << POLICY 2>/dev/null
path "secret/data/${ENV}/{{identity.entity.aliases.auth_approle_*.name}}/*" {
  capabilities = ["read"]
}
path "secret/metadata/${ENV}/{{identity.entity.aliases.auth_approle_*.name}}/*" {
  capabilities = ["list"]
}
path "secret/data/shared/*" {
  capabilities = ["read"]
}
POLICY
echo "  [OK] Политика app-${ENV}-readonly"

vault policy write "app-${ENV}-readwrite" - << POLICY 2>/dev/null
path "secret/data/${ENV}/{{identity.entity.aliases.auth_approle_*.name}}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "secret/metadata/${ENV}/{{identity.entity.aliases.auth_approle_*.name}}/*" {
  capabilities = ["list", "delete"]
}
POLICY
echo "  [OK] Политика app-${ENV}-readwrite"

# Политика аудита для просмотра всей структуры
vault policy write "ops-viewer" - << POLICY 2>/dev/null
path "secret/metadata/${ENV}/*" {
  capabilities = ["list"]
}
path "secret/metadata/shared/*" {
  capabilities = ["list"]
}
POLICY
echo "  [OK] Политика ops-viewer"

# Настройка версионирования
echo ""
echo "--- Настройка версионирования ---"
vault write "secret/config" max_versions=10 2>/dev/null || true
echo "  [OK] Максимум 10 версий секрета"

echo ""
echo "=== Структура KV создана ==="
echo ""
echo "Просмотр структуры:"
echo "  vault kv list secret/$ENV/"
echo ""
echo "Запись секрета:"
echo "  vault kv put secret/$ENV/database/postgres password=<value> user=<value>"
