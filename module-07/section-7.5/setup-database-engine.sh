#!/usr/bin/env bash
# Настройка Vault Database Secrets Engine для PostgreSQL
# Использование: bash setup-database-engine.sh <db_host> <db_name> <admin_user> <admin_pass>
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
DB_HOST="${1:-postgres.internal.company.local}"
DB_PORT="${2:-5432}"
DB_NAME="${3:-appdb}"
ADMIN_USER="${4:-vault_admin}"
ADMIN_PASS="${5:-}"

export VAULT_ADDR

echo "=== Настройка Vault Database Engine (PostgreSQL) ==="
echo "  Host:   $DB_HOST:$DB_PORT"
echo "  DB:     $DB_NAME"
echo "  Admin:  $ADMIN_USER"

[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }
[ -n "$ADMIN_PASS" ] || { echo "[FAIL] Пароль администратора не задан (аргумент 5)"; exit 1; }

# Включение Database engine
echo ""
echo "--- Включение Database Secrets Engine ---"
vault secrets enable -path=database database 2>/dev/null || echo "  database уже включён"

# Конфигурация подключения
echo ""
echo "--- Конфигурация подключения ---"
vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-readonly,app-readwrite,app-migration" \
  connection_url="postgresql://{{username}}:{{password}}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require" \
  username="$ADMIN_USER" \
  password="$ADMIN_PASS" \
  2>/dev/null
echo "  [OK] Подключение postgres настроено"

# Ротация credentials администратора (Vault управляет паролем)
vault write -f database/rotate-root/postgres 2>/dev/null && \
  echo "  [OK] Пароль root-пользователя ротирован (управляется Vault)" || \
  echo "  [WARN] Не удалось ротировать root-пароль"

# Роль только для чтения
echo ""
echo "--- Создание ролей ---"
vault write database/roles/app-readonly \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT CONNECT ON DATABASE $DB_NAME TO \"{{name}}\";
GRANT USAGE ON SCHEMA public TO \"{{name}}\";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h" \
  2>/dev/null
echo "  [OK] Роль app-readonly (TTL 1h / max 24h)"

# Роль с записью
vault write database/roles/app-readwrite \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
GRANT CONNECT ON DATABASE $DB_NAME TO \"{{name}}\";
GRANT USAGE ON SCHEMA public TO \"{{name}}\";
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="8h" \
  2>/dev/null
echo "  [OK] Роль app-readwrite (TTL 1h / max 8h)"

# Политика Vault
echo ""
echo "--- Политика Vault ---"
vault policy write db-app-readonly - << 'POLICY' 2>/dev/null
path "database/creds/app-readonly" {
  capabilities = ["read"]
}
POLICY
vault policy write db-app-readwrite - << 'POLICY' 2>/dev/null
path "database/creds/app-readwrite" {
  capabilities = ["read"]
}
POLICY
echo "  [OK] Политики db-app-readonly, db-app-readwrite"

echo ""
echo "=== Database Engine настроен ==="
echo ""
echo "Получение временных credentials:"
echo "  vault read database/creds/app-readonly"
