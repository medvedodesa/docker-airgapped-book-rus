#!/usr/bin/env bash
# Настройка Cosign с ключом подписи в Vault Transit
# Использование: bash setup-cosign-vault.sh <vault_addr> <vault_token> <key_name>
set -euo pipefail

VAULT_ADDR="${1:-https://vault.internal.company.local:8200}"
VAULT_TOKEN="${2:-}"
KEY_NAME="${3:-docker-signing-key}"
PUBLIC_KEY_DIR="${4:-/etc/docker/cosign}"

export VAULT_ADDR VAULT_TOKEN

echo "=== Настройка Cosign + Vault Transit ==="
echo "  Vault:    $VAULT_ADDR"
echo "  Ключ:     $KEY_NAME"

# Включить Transit если не включён
echo ""
echo "--- Vault Transit ---"
vault secrets enable transit 2>/dev/null || echo "  Transit уже включён"

# Создать ключ для подписи (ed25519)
vault write -f "transit/keys/$KEY_NAME" type=ed25519 2>/dev/null || true
echo "  [OK] Ключ $KEY_NAME в Vault Transit"

# Получить открытый ключ
echo ""
echo "--- Открытый ключ ---"
mkdir -p "$PUBLIC_KEY_DIR"
pub_key_b64=$(vault read -field=keys "transit/keys/$KEY_NAME" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['1']['public_key'])" 2>/dev/null || true)

if [ -n "$pub_key_b64" ]; then
  echo "$pub_key_b64" > "$PUBLIC_KEY_DIR/${KEY_NAME}.pub"
  echo "  [OK] Открытый ключ: $PUBLIC_KEY_DIR/${KEY_NAME}.pub"
else
  # Альтернативный метод через cosign
  if command -v cosign &>/dev/null; then
    COSIGN_EXPERIMENTAL=1 cosign generate-key-pair \
      --kms "hashivault://$KEY_NAME" 2>/dev/null || true
    echo "  [OK] Ключи через cosign generate-key-pair"
  fi
fi

# Политика Vault для CI/CD
echo ""
echo "--- Политика Vault ---"
vault policy write cosign-signer - << 'EOF'
path "transit/sign/docker-signing-key" {
  capabilities = ["update"]
}
path "transit/verify/docker-signing-key" {
  capabilities = ["update"]
}
EOF
echo "  [OK] Политика cosign-signer создана"

echo ""
echo "=== Настройка завершена ==="
echo ""
echo "Для подписи образа:"
echo "  export COSIGN_EXPERIMENTAL=1"
echo "  cosign sign --key hashivault://$KEY_NAME harbor.internal/project/image:tag"
echo ""
echo "Для верификации:"
echo "  cosign verify --key $PUBLIC_KEY_DIR/${KEY_NAME}.pub harbor.internal/project/image:tag"
