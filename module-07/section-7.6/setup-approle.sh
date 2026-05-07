#!/usr/bin/env bash
# Настройка AppRole аутентификации в Vault для CI/CD и сервисов
# Использование: bash setup-approle.sh <app_name> <policy_name> [token_ttl]
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
APP_NAME="${1:-}"
POLICY_NAME="${2:-}"
TOKEN_TTL="${3:-1h}"
TOKEN_MAX_TTL="${4:-24h}"
SECRET_ID_TTL="${5:-720h}"   # 30 дней

[ -n "$APP_NAME" ] && [ -n "$POLICY_NAME" ] || {
  echo "Использование: $0 <app_name> <policy_name> [token_ttl]"
  echo "Пример: $0 gitlab-runner db-app-readonly 1h"
  exit 1
}

export VAULT_ADDR

echo "=== Настройка AppRole: $APP_NAME ==="
[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

# Включение AppRole
echo ""
echo "--- Включение метода аутентификации ---"
vault auth enable approle 2>/dev/null || echo "  approle уже включён"

# Создание AppRole
echo ""
echo "--- Создание AppRole ---"
vault write "auth/approle/role/$APP_NAME" \
  secret_id_ttl="$SECRET_ID_TTL" \
  secret_id_num_uses=0 \
  token_ttl="$TOKEN_TTL" \
  token_max_ttl="$TOKEN_MAX_TTL" \
  token_policies="$POLICY_NAME" \
  token_type=service \
  bind_secret_id=true \
  2>/dev/null
echo "  [OK] AppRole $APP_NAME создан"

# Получение RoleID (не секретный)
role_id=$(vault read -field=role_id "auth/approle/role/$APP_NAME/role-id" 2>/dev/null)
echo "  RoleID: $role_id"

# Генерация первоначального SecretID
echo ""
echo "--- Генерация SecretID ---"
secret_id=$(vault write -f -field=secret_id "auth/approle/role/$APP_NAME/secret-id" 2>/dev/null)

# Сохранение в файл с ограниченными правами
CREDS_FILE="/tmp/approle-${APP_NAME}.json"
cat > "$CREDS_FILE" << JSON
{
  "role_id": "$role_id",
  "secret_id": "$secret_id",
  "app_name": "$APP_NAME",
  "policy": "$POLICY_NAME"
}
JSON
chmod 400 "$CREDS_FILE"
echo "  [OK] Credentials сохранены в $CREDS_FILE (chmod 400)"
echo "  [!] Передайте secret_id приложению по защищённому каналу"

# Проверка аутентификации
echo ""
echo "--- Проверка ---"
test_token=$(vault write -field=token auth/approle/login \
  role_id="$role_id" \
  secret_id="$secret_id" \
  2>/dev/null || true)

if [ -n "$test_token" ]; then
  echo "  [OK] Аутентификация работает"
  # Немедленно отзываем тестовый токен
  VAULT_TOKEN="$test_token" vault token revoke -self 2>/dev/null || true
  echo "  [OK] Тестовый токен отозван"
else
  echo "  [WARN] Не удалось проверить аутентификацию"
fi

echo ""
echo "=== AppRole $APP_NAME настроен ==="
echo ""
echo "Использование в приложении:"
echo "  VAULT_ROLE_ID=$role_id"
echo "  VAULT_SECRET_ID=<из $CREDS_FILE>"
echo ""
echo "Генерация нового SecretID (ротация):"
echo "  bash generate-secret-id.sh $APP_NAME"
