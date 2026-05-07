#!/usr/bin/env bash
# Резервное копирование GitLab: данные + конфигурация + секреты
# Использование: bash gitlab-backup.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-/opt/backup/gitlab}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
KEEP_DAYS="${GITLAB_BACKUP_KEEP:-7}"

echo "=== Резервное копирование GitLab ==="
echo "  Каталог: $BACKUP_DIR"

command -v gitlab-backup &>/dev/null || { echo "[FAIL] gitlab-backup не найден"; exit 1; }

mkdir -p "$BACKUP_DIR/config" "$BACKUP_DIR/data"

# Основные данные через gitlab-backup
echo ""
echo "--- Данные GitLab ---"
CRON=1 gitlab-backup create BACKUP="$TIMESTAMP" \
  STRATEGY=copy \
  SKIP="builds,artifacts" \
  2>&1 | tail -5

# Найти созданный архив
backup_file=$(find /var/opt/gitlab/backups -name "${TIMESTAMP}_*gitlab_backup.tar" 2>/dev/null | head -1 || true)
if [ -n "$backup_file" ]; then
  mv "$backup_file" "$BACKUP_DIR/data/"
  echo "  [OK] $(basename $backup_file) перемещён в $BACKUP_DIR/data/"
else
  echo "  [WARN] Архив резервной копии не найден"
fi

# Конфигурация и секреты (обязательно!)
echo ""
echo "--- Конфигурация и секреты ---"
CONFIG_ARCHIVE="$BACKUP_DIR/config/gitlab-config-$TIMESTAMP.tar.gz"
tar -czf "$CONFIG_ARCHIVE" \
  /etc/gitlab/gitlab.rb \
  /etc/gitlab/gitlab-secrets.json \
  /etc/gitlab/ssl/ \
  2>/dev/null
chmod 600 "$CONFIG_ARCHIVE"
echo "  [OK] $CONFIG_ARCHIVE (содержит gitlab-secrets.json!)"

# Контрольные суммы
sha256sum "$BACKUP_DIR/data/"*"$TIMESTAMP"* \
  "$CONFIG_ARCHIVE" \
  > "$BACKUP_DIR/checksums-$TIMESTAMP.sha256" 2>/dev/null || true
echo "  [OK] checksums-$TIMESTAMP.sha256"

# Ротация
echo ""
echo "--- Ротация (старше $KEEP_DAYS дней) ---"
deleted=$(find "$BACKUP_DIR" -name "*.tar" -o -name "*.tar.gz" -mtime "+$KEEP_DAYS" \
  -delete -print 2>/dev/null | wc -l)
find "$BACKUP_DIR" -name "checksums-*" -mtime "+$KEEP_DAYS" -delete 2>/dev/null || true
echo "  Удалено: $deleted файл(ов)"

echo ""
echo "=== Резервное копирование завершено ==="
echo ""
echo "  [!] gitlab-secrets.json КРИТИЧЕН для восстановления"
echo "  Без него зашифрованные данные (CI/CD переменные) не восстановимы"
