#!/usr/bin/env bash
# Деплой с инжекцией секретов из Vault через Vault Agent
# Использование: bash deploy-with-vault.sh <service_name> <image>
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
SERVICE="${1:-}"
IMAGE="${2:-}"
VAULT_ROLE="${VAULT_ROLE:-}"
VAULT_ROLE_ID="${VAULT_ROLE_ID:-}"
VAULT_SECRET_ID="${VAULT_SECRET_ID:-}"

[ -n "$SERVICE" ] && [ -n "$IMAGE" ] || {
  echo "Использование: $0 <service_name> <image:tag>"
  exit 1
}
[ -n "$VAULT_ROLE_ID" ] && [ -n "$VAULT_SECRET_ID" ] || {
  echo "[FAIL] VAULT_ROLE_ID и VAULT_SECRET_ID должны быть установлены"
  exit 1
}

export VAULT_ADDR

echo "=== Деплой с секретами из Vault ==="
echo "  Сервис: $SERVICE"
echo "  Образ:  $IMAGE"

# Аутентификация в Vault
echo ""
echo "--- Аутентификация Vault ---"
VAULT_TOKEN=$(vault write -field=token auth/approle/login \
  role_id="$VAULT_ROLE_ID" \
  secret_id="$VAULT_SECRET_ID" \
  2>/dev/null)
export VAULT_TOKEN
echo "  [OK] Токен получен"

# Получение секретов
echo ""
echo "--- Получение секретов ---"
SECRETS_JSON=$(vault kv get -format=json "secret/prod/$SERVICE" 2>/dev/null | \
  python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['data']['data']))" \
  2>/dev/null || echo '{}')

# Формирование Docker secret/env аргументов
ENV_ARGS=()
while IFS="=" read -r key value; do
  [ -n "$key" ] && ENV_ARGS+=("--env" "${key}=${value}")
done < <(echo "$SECRETS_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for k,v in d.items():
    print(f'{k}={v}')
" 2>/dev/null)

echo "  [OK] Получено $(echo "$SECRETS_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "?") секретов"

# Деплой сервиса
echo ""
echo "--- Деплой ---"
docker service update \
  --image "$IMAGE" \
  "${ENV_ARGS[@]}" \
  --update-parallelism 1 \
  --update-failure-action rollback \
  "$SERVICE" \
  2>/dev/null && echo "  [OK] Сервис обновлён" || {
  echo "  [FAIL] Ошибка обновления сервиса"
  vault token revoke -self 2>/dev/null || true
  exit 1
}

# Отзыв токена
vault token revoke -self 2>/dev/null || true
echo "  [OK] Vault токен отозван"

echo ""
echo "=== Деплой завершён: $SERVICE ($IMAGE) ==="
