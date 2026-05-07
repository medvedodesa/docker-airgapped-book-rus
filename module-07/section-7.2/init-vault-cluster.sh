#!/usr/bin/env bash
# Инициализация Vault: unseal, настройка политик и аудит-лога
# Использование: bash init-vault-cluster.sh [vault_addr]
set -euo pipefail

VAULT_ADDR="${1:-https://vault.internal.company.local:8200}"
KEYS_FILE="${VAULT_KEYS_FILE:-/root/vault-keys.json}"
SHARES="${VAULT_KEY_SHARES:-5}"
THRESHOLD="${VAULT_KEY_THRESHOLD:-3}"

export VAULT_ADDR
export VAULT_SKIP_VERIFY="${VAULT_SKIP_VERIFY:-false}"

echo "=== Инициализация Vault Cluster ==="
echo "  Адрес:     $VAULT_ADDR"
echo "  Shares:    $SHARES  (порог: $THRESHOLD)"
echo "  Ключи:     $KEYS_FILE"

# Ожидание готовности
echo ""
echo "--- Проверка доступности ---"
for i in $(seq 1 12); do
  if vault status &>/dev/null 2>&1; then
    break
  fi
  echo "  Ожидание Vault ($i/12)..."
  sleep 5
done
vault status 2>/dev/null | grep -E "Initialized|Sealed|Version" || true

# Проверка статуса инициализации
if vault status 2>/dev/null | grep -q "Initialized.*true"; then
  echo "  [WARN] Vault уже инициализирован — пропуск инициализации"
else
  echo ""
  echo "--- Инициализация ---"
  vault operator init \
    -key-shares="$SHARES" \
    -key-threshold="$THRESHOLD" \
    -format=json > "$KEYS_FILE"
  chmod 400 "$KEYS_FILE"
  echo "  [OK] Ключи сохранены в $KEYS_FILE (chmod 400)"
  echo "  [!] НЕМЕДЛЕННО перенесите ключи в безопасное хранилище!"
fi

# Unseal
echo ""
echo "--- Unseal ---"
if vault status 2>/dev/null | grep -q "Sealed.*true"; then
  if [ -f "$KEYS_FILE" ]; then
    for i in $(seq 0 $((THRESHOLD - 1))); do
      key=$(python3 -c "import json,sys; d=json.load(open('$KEYS_FILE')); print(d['unseal_keys_b64'][$i])" 2>/dev/null)
      vault operator unseal "$key" &>/dev/null
      echo "  Ключ $((i+1))/$THRESHOLD применён"
    done
    echo "  [OK] Vault распечатан"
  else
    echo "  [WARN] Файл ключей не найден, введите ключи вручную:"
    echo "    vault operator unseal"
    exit 0
  fi
else
  echo "  [OK] Vault уже распечатан"
fi

# Логин с root token
echo ""
echo "--- Настройка ---"
if [ -f "$KEYS_FILE" ]; then
  root_token=$(python3 -c "import json; d=json.load(open('$KEYS_FILE')); print(d['root_token'])" 2>/dev/null)
  export VAULT_TOKEN="$root_token"
fi

# Аудит-лог
if ! vault audit list 2>/dev/null | grep -q "file"; then
  vault audit enable file file_path=/var/log/vault/audit.log 2>/dev/null && \
    echo "  [OK] Аудит-лог включён" || \
    echo "  [WARN] Не удалось включить аудит-лог"
fi

# Базовые политики
vault policy write default-readonly - << 'EOF' 2>/dev/null
path "secret/data/{{identity.entity.name}}/*" {
  capabilities = ["read", "list"]
}
EOF
echo "  [OK] Политика default-readonly создана"

echo ""
echo "=== Инициализация завершена ==="
echo ""
echo "Сохраните root token для первоначальной настройки:"
echo "  cat $KEYS_FILE | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d['root_token'])\""
echo ""
echo "Создайте рабочие токены и отзовите root token после настройки:"
echo "  vault token revoke <root_token>"
