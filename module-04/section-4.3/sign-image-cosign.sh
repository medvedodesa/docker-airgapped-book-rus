#!/usr/bin/env bash
# Подпись Docker-образа через Cosign с ключом из Vault Transit
# Использование: bash sign-image-cosign.sh <образ_с_тегом> [vault_addr] [vault_token]
set -euo pipefail

IMAGE="${1:-}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${3:-${VAULT_TOKEN:-}}"
VAULT_KEY_NAME="${VAULT_TRANSIT_KEY:-cosign-key}"
COSIGN_PUBKEY="${COSIGN_PUBLIC_KEY:-cosign.pub}"
HARBOR_URL="${HARBOR_URL:-harbor.internal.company.local}"

if [ -z "$IMAGE" ]; then
  echo "Укажите образ для подписи:"
  echo "  bash $0 harbor.internal.company.local/myapp/api:1.5.2-a3b4c5d"
  exit 1
fi

if [ -z "$VAULT_TOKEN" ]; then
  echo "Укажите Vault-токен: переменная VAULT_TOKEN или третий аргумент"
  exit 1
fi

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Подпись образа Cosign (Vault Transit) ==="
echo "Образ:     $IMAGE"
echo "Vault:     $VAULT_ADDR"
echo "Ключ:      $VAULT_KEY_NAME"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"

# --- Проверка naличия cosign ---
echo ""
echo "--- Инструменты ---"
if ! command -v cosign &>/dev/null; then
  fail "cosign не найден в PATH — установите или добавьте в PATH"
  exit 1
fi
ok "cosign: $(cosign version 2>/dev/null | grep GitVersion | awk '{print $2}' || echo 'найден')"

# --- Проверка доступности Vault ---
echo ""
echo "--- Vault ---"
if curl -sf --max-time 5 -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/auth/token/lookup-self" >/dev/null 2>&1; then
  ok "Vault доступен и токен действителен"
else
  fail "Vault недоступен или токен недействителен: $VAULT_ADDR"
  exit 1
fi

# Проверяем наличие Transit-ключа
key_info=$(curl -sf --max-time 10 \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "$VAULT_ADDR/v1/transit/keys/$VAULT_KEY_NAME" 2>/dev/null || echo "{}")
key_type=$(echo "$key_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('type','не найден'))" 2>/dev/null || echo "не найден")
if [ "$key_type" != "не найден" ] && [ "$key_type" != "" ]; then
  ok "Transit-ключ '$VAULT_KEY_NAME': $key_type"
else
  fail "Transit-ключ '$VAULT_KEY_NAME' не найден в Vault"
  exit 1
fi

# --- Получение дайджеста образа ---
echo ""
echo "--- Образ ---"
image_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null | cut -d@ -f2 || echo "")
if [ -z "$image_digest" ]; then
  # Пытаемся получить через crane/skopeo
  image_digest=$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || echo "")
fi
if [ -n "$image_digest" ]; then
  ok "Дайджест образа: ${image_digest:0:20}..."
else
  warn "Дайджест не определён локально — подпись будет по тегу"
fi

# --- Подпись через Cosign с Vault Transit ---
echo ""
echo "--- Подпись ---"
export VAULT_ADDR VAULT_TOKEN

# Cosign поддерживает Vault через переменные окружения COSIGN_KEY или hashivault://
COSIGN_KEY_REF="hashivault://$VAULT_KEY_NAME"

if cosign sign \
    --key "$COSIGN_KEY_REF" \
    --tlog-upload=false \
    --yes \
    "$IMAGE" 2>&1; then
  ok "Образ подписан: $IMAGE"
else
  fail "Ошибка подписи образа"
  exit 1
fi

# --- Верификация подписи ---
echo ""
echo "--- Верификация ---"
if [ -f "$COSIGN_PUBKEY" ]; then
  if cosign verify \
      --key "$COSIGN_PUBKEY" \
      --insecure-ignore-tlog=true \
      "$IMAGE" 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
    ok "Подпись верифицирована публичным ключом: $COSIGN_PUBKEY"
  else
    fail "Верификация подписи не прошла"
  fi
else
  warn "Публичный ключ $COSIGN_PUBKEY не найден — пропуск верификации"
  echo "    Экспортируйте публичный ключ: cosign public-key --key $COSIGN_KEY_REF > $COSIGN_PUBKEY"
fi

# --- Добавление аннотаций (метаданные) ---
echo ""
echo "--- Аннотации ---"
BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

cosign attest \
    --key "$COSIGN_KEY_REF" \
    --tlog-upload=false \
    --predicate /dev/stdin \
    --type slsaprovenance \
    "$IMAGE" <<EOF 2>/dev/null || warn "Аннотации не добавлены (cosign attest может не поддерживаться)"
{
  "buildDate": "$BUILD_DATE",
  "gitSha": "$GIT_SHA",
  "builder": "$(hostname)",
  "image": "$IMAGE"
}
EOF

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
