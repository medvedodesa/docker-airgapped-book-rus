#!/usr/bin/env bash
# Генерация Secret ID для AppRole с передачей через временный файл и немедленным удалением
# Использование: bash generate-secret-id.sh <role_name> [vault_addr] [vault_token]
set -euo pipefail

ROLE_NAME="${1:-${VAULT_APPROLE_ROLE:-}}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${3:-${VAULT_TOKEN:-}}"
SECRET_ID_FILE="${SECRET_ID_FILE:-/tmp/.vault-secret-id-$$}"
TTL="${SECRET_ID_TTL:-1h}"
USE_COUNT="${SECRET_ID_USE_COUNT:-1}"

if [ -z "$ROLE_NAME" ] || [ -z "$VAULT_TOKEN" ]; then
  echo "Использование: bash $0 <role_name> [vault_addr] [vault_token]"
  echo "Или: VAULT_APPROLE_ROLE=<role> VAULT_TOKEN=<token> bash $0"
  exit 1
fi

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Гарантируем удаление временного файла при выходе
trap 'rm -f "$SECRET_ID_FILE" 2>/dev/null; exit' EXIT INT TERM

echo "=== Генерация Secret ID для AppRole ==="
echo "Роль:    $ROLE_NAME"
echo "Vault:   $VAULT_ADDR"
echo "TTL:     $TTL"
echo "Число использований: $USE_COUNT"

# ── Проверка роли ─────────────────────────────────────────────────────────
echo ""
echo "── Проверка роли ────────────────────────────────────────────────────────"
role_info=$(curl -sf --max-time 10 \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/approle/role/$ROLE_NAME" 2>/dev/null || echo "{}")

if echo "$role_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}))" 2>/dev/null | grep -q "token_ttl"; then
  token_ttl=$(echo "$role_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('token_ttl','?'))" 2>/dev/null)
  token_policies=$(echo "$role_info" | python3 -c "import json,sys; print(', '.join(json.load(sys.stdin).get('data',{}).get('token_policies',[])))" 2>/dev/null)
  ok "Роль $ROLE_NAME существует (token_ttl=$token_ttl, policies=$token_policies)"
else
  fail "Роль $ROLE_NAME не найдена — создайте через setup-approle.sh"
  exit 1
fi

# ── Генерация Secret ID ───────────────────────────────────────────────────
echo ""
echo "── Генерация ────────────────────────────────────────────────────────────"

# Метаданные для аудита
METADATA=$(python3 -c "
import json, os, datetime
print(json.dumps({
  'generated_by': os.environ.get('USER','automation'),
  'generated_at': datetime.datetime.utcnow().isoformat() + 'Z',
  'host': os.uname().nodename,
  'purpose': 'automated-deployment'
}))
" 2>/dev/null || echo '{}')

PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'ttl': '$TTL',
  'num_uses': $USE_COUNT,
  'metadata': json.dumps($METADATA)
}))
" 2>/dev/null || echo "{\"ttl\": \"$TTL\", \"num_uses\": $USE_COUNT}")

response=$(curl -sf --max-time 10 \
  -X POST \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  -H "Content-Type: application/json" \
  "$VAULT_ADDR/v1/auth/approle/role/$ROLE_NAME/secret-id" \
  -d "$PAYLOAD" 2>/dev/null || echo "{}")

secret_id=$(echo "$response" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d.get('data',{}).get('secret_id',''))
" 2>/dev/null || echo "")

secret_accessor=$(echo "$response" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d.get('data',{}).get('secret_id_accessor',''))
" 2>/dev/null || echo "")

if [ -z "$secret_id" ]; then
  fail "Не удалось сгенерировать Secret ID — проверьте права токена и имя роли"
  exit 1
fi
ok "Secret ID сгенерирован (accessor=$secret_accessor)"

# ── Запись во временный файл ──────────────────────────────────────────────
echo ""
echo "── Передача ─────────────────────────────────────────────────────────────"
touch "$SECRET_ID_FILE"
chmod 600 "$SECRET_ID_FILE"
echo "$secret_id" > "$SECRET_ID_FILE"
ok "Secret ID записан во временный файл: $SECRET_ID_FILE"

# ── Передача целевому процессу ────────────────────────────────────────────
# Способ 1: через файл (рекомендуется — файл удаляется ловушкой)
echo ""
echo "Secret ID доступен в: $SECRET_ID_FILE"
echo "Используйте немедленно и не сохраняйте постоянно."
echo ""

# Если задана переменная для передачи через env
if [ -n "${SECRET_ID_TARGET_VAR:-}" ]; then
  export "$SECRET_ID_TARGET_VAR"="$secret_id"
  ok "Secret ID экспортирован в переменную: $SECRET_ID_TARGET_VAR"
fi

# ── Верификация: можно ли получить токен ─────────────────────────────────
echo ""
echo "── Верификация ──────────────────────────────────────────────────────────"
role_id=$(curl -sf --max-time 10 \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/auth/approle/role/$ROLE_NAME/role-id" 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('role_id',''))" 2>/dev/null || echo "")

if [ -n "$role_id" ]; then
  test_token=$(curl -sf --max-time 10 \
    -X POST \
    -H "Content-Type: application/json" \
    "$VAULT_ADDR/v1/auth/approle/login" \
    -d "{\"role_id\": \"$role_id\", \"secret_id\": \"$secret_id\"}" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('auth',{}).get('client_token',''))" 2>/dev/null || echo "")

  if [ -n "$test_token" ]; then
    ok "Верификация: токен успешно получен с Role ID + Secret ID"
    # Сразу отзываем тестовый токен (использовали один из NUM_USES)
    curl -sf -X POST \
      -H "X-Vault-Token: $test_token" \
      "$VAULT_ADDR/v1/auth/token/revoke-self" >/dev/null 2>&1 || true
  else
    fail "Верификация: не удалось получить токен — Secret ID может быть уже использован"
  fi
fi

# ── Удаление временного файла ─────────────────────────────────────────────
echo ""
echo "── Удаление временного файла ────────────────────────────────────────────"
rm -f "$SECRET_ID_FILE"
ok "Временный файл удалён: $SECRET_ID_FILE"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Accessor для аудита: $secret_accessor"
echo "Время жизни Secret ID: $TTL (использований: $USE_COUNT)"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
