#!/usr/bin/env bash
# Ротация статического секрета в Vault KV v2 с уведомлением
# Использование: bash rotate-static-secret.sh <secret_path> <key> <new_value>
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
SECRET_PATH="${1:-}"
SECRET_KEY="${2:-}"
NEW_VALUE="${3:-}"

[ -n "$SECRET_PATH" ] && [ -n "$SECRET_KEY" ] && [ -n "$NEW_VALUE" ] || {
  echo "Использование: $0 <secret_path> <ключ> <новое_значение>"
  echo "Пример: $0 secret/prod/database/postgres password 'new_p@ssw0rd'"
  exit 1
}

[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

export VAULT_ADDR

echo "=== Ротация секрета ==="
echo "  Путь: $SECRET_PATH"
echo "  Ключ: $SECRET_KEY"

# Текущая версия
echo ""
echo "--- Текущее состояние ---"
current_meta=$(vault kv metadata get -format=json "$SECRET_PATH" 2>/dev/null || echo '{}')
current_version=$(echo "$current_meta" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('current_version',0))" 2>/dev/null || echo "0")
echo "  Текущая версия: $current_version"

# Чтение текущего значения для проверки (только метаданные, без вывода значения)
current_data=$(vault kv get -format=json "$SECRET_PATH" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['data']['data'].keys()))" 2>/dev/null || echo "[]")
echo "  Существующие ключи: $current_data"

# Запись нового значения с patch (сохраняем остальные ключи)
echo ""
echo "--- Обновление ---"
vault kv patch "$SECRET_PATH" "${SECRET_KEY}=${NEW_VALUE}" 2>/dev/null && \
  echo "  [OK] Секрет обновлён (patch)" || {
  # Если patch не работает (первая запись), используем put
  vault kv put "$SECRET_PATH" "${SECRET_KEY}=${NEW_VALUE}" 2>/dev/null
  echo "  [OK] Секрет записан (put)"
}

# Новая версия
new_version=$(vault kv metadata get -format=json "$SECRET_PATH" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('current_version',0))" 2>/dev/null || echo "?")
echo "  Новая версия: $new_version"

# Запись в лог ротации
ROTATION_LOG="/var/log/vault/rotations.log"
if [ -d "$(dirname $ROTATION_LOG)" ]; then
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ROTATED path=$SECRET_PATH key=$SECRET_KEY v$current_version->v$new_version" \
    >> "$ROTATION_LOG" 2>/dev/null || true
fi

echo ""
echo "=== Ротация завершена ==="
echo ""
echo "Откат к предыдущей версии:"
echo "  vault kv rollback -version=$current_version $SECRET_PATH"
