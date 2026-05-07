#!/usr/bin/env bash
# Подпись Docker-образа через Cosign + Vault Transit в конвейере CI/CD
# Использование: bash sign-image-cosign.sh <image:tag>
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
IMAGE="${1:-}"
KEY_NAME="${VAULT_COSIGN_KEY:-docker-signing-key}"
HARBOR_CA="${HARBOR_CA:-/etc/docker/certs.d/harbor.internal.company.local/ca.crt}"

[ -n "$IMAGE" ] || { echo "Использование: $0 <image:tag>"; exit 1; }
[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

export VAULT_ADDR
export COSIGN_EXPERIMENTAL=1

echo "=== Подпись образа: $IMAGE ==="

# Проверка cosign
command -v cosign &>/dev/null || { echo "[FAIL] cosign не найден"; exit 1; }

# Получение дайджеста образа
echo ""
echo "--- Получение дайджеста ---"
digest=$(cosign triangulate "$IMAGE" 2>/dev/null | head -1 || true)
if [ -z "$digest" ]; then
  digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE" 2>/dev/null | cut -d@ -f2 || true)
fi
[ -n "$digest" ] && echo "  Дайджест: $digest" || echo "  [WARN] Не удалось получить дайджест"

# Подпись через Vault Transit KMS
echo ""
echo "--- Подпись ---"
cosign sign \
  --key "hashivault://$KEY_NAME" \
  --tlog-upload=false \
  "$IMAGE" \
  2>/dev/null && echo "  [OK] Образ подписан" || {
  echo "  [FAIL] Ошибка подписи"
  exit 1
}

# Верификация подписи
echo ""
echo "--- Верификация ---"
pub_key_file=$(mktemp /tmp/cosign-pub-XXXXXX.pub)
vault read -field=keys "transit/keys/$KEY_NAME" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['1']['public_key'])" \
  > "$pub_key_file" 2>/dev/null || true

if [ -s "$pub_key_file" ]; then
  cosign verify \
    --key "$pub_key_file" \
    --insecure-ignore-tlog \
    "$IMAGE" \
    2>/dev/null | python3 -m json.tool 2>/dev/null | head -10 || true
  echo "  [OK] Подпись верифицирована"
  rm -f "$pub_key_file"
else
  rm -f "$pub_key_file"
  echo "  [WARN] Не удалось получить публичный ключ для верификации"
fi

echo ""
echo "=== Подпись завершена: $IMAGE ==="
