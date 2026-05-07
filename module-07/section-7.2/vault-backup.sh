#!/usr/bin/env bash
# Резервное копирование Vault: снимок Raft или файловое хранилище
# Использование: bash vault-backup.sh [backup_dir]
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
BACKUP_DIR="${1:-/opt/backup/vault}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/vault-snapshot-$TIMESTAMP.snap"
KEEP_DAYS="${VAULT_BACKUP_KEEP:-14}"

export VAULT_ADDR

echo "=== Резервное копирование Vault ==="
echo "  Адрес:   $VAULT_ADDR"
echo "  Каталог: $BACKUP_DIR"

# Проверка токена
[ -n "${VAULT_TOKEN:-}" ] || {
  echo "[FAIL] Переменная VAULT_TOKEN не установлена"
  exit 1
}

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

# Проверка состояния
echo ""
echo "--- Состояние кластера ---"
vault status 2>/dev/null | grep -E "Initialized|Sealed|Version|HA Mode|Storage Type" || true

storage_type=$(vault status -format=json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_type','unknown'))" 2>/dev/null || echo "unknown")
echo "  Тип хранилища: $storage_type"

# Снимок
echo ""
echo "--- Создание снимка ---"
if vault operator raft snapshot save "$BACKUP_FILE" 2>/dev/null; then
  size=$(du -sh "$BACKUP_FILE" | cut -f1)
  echo "  [OK] Raft-снимок: $BACKUP_FILE ($size)"
elif [ "$storage_type" = "file" ]; then
  # Файловое хранилище — tar с остановкой сервиса
  echo "  [WARN] Raft недоступен, используем файловое копирование"
  echo "  [WARN] Для файлового хранилища рекомендуется остановить Vault перед копированием"
  tar -czf "${BACKUP_FILE%.snap}.tar.gz" -C /var/lib/vault/data . 2>/dev/null
  BACKUP_FILE="${BACKUP_FILE%.snap}.tar.gz"
  size=$(du -sh "$BACKUP_FILE" | cut -f1)
  echo "  [OK] Файловый архив: $BACKUP_FILE ($size)"
else
  echo "  [FAIL] Не удалось создать снимок"
  exit 1
fi

# Контрольная сумма
sha256sum "$BACKUP_FILE" > "${BACKUP_FILE}.sha256"
echo "  [OK] SHA256: ${BACKUP_FILE}.sha256"

# Ротация старых резервных копий
echo ""
echo "--- Ротация резервных копий (старше $KEEP_DAYS дней) ---"
deleted=$(find "$BACKUP_DIR" -name "vault-snapshot-*" -mtime "+$KEEP_DAYS" -delete -print 2>/dev/null | wc -l)
echo "  Удалено: $deleted файл(ов)"

remaining=$(find "$BACKUP_DIR" -name "vault-snapshot-*" | wc -l)
echo "  Актуальных резервных копий: $remaining"

echo ""
echo "=== Резервное копирование завершено: $BACKUP_FILE ==="
