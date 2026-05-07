#!/usr/bin/env bash
# Централизованное резервное копирование всех компонентов инфраструктуры
# Использование: bash backup-all.sh [backup_root]
set -euo pipefail

BACKUP_ROOT="${1:-/opt/backup}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$TIMESTAMP"
LOG_FILE="$BACKUP_ROOT/backup-$TIMESTAMP.log"

SUCCESS=0; FAILED=0

log()  { echo "[$(date +%H:%M:%S)] $1" | tee -a "$LOG_FILE"; }
ok()   { log "[OK]   $1"; ((SUCCESS++)); }
fail() { log "[FAIL] $1"; ((FAILED++)); }

mkdir -p "$BACKUP_DIR"
log "=== Централизованное резервное копирование ==="
log "  Каталог: $BACKUP_DIR"

# Harbor
log ""
log "--- Harbor ---"
if systemctl is-active --quiet harbor 2>/dev/null || docker ps --format '{{.Names}}' | grep -q harbor; then
  mkdir -p "$BACKUP_DIR/harbor"
  tar -czf "$BACKUP_DIR/harbor/config.tar.gz" /etc/harbor/ 2>/dev/null && \
    ok "Harbor конфигурация" || fail "Harbor конфигурация"
  # Данные PostgreSQL Harbor
  docker exec harbor-db pg_dumpall -U postgres 2>/dev/null | \
    gzip > "$BACKUP_DIR/harbor/harbor-db.sql.gz" && \
    ok "Harbor PostgreSQL" || fail "Harbor PostgreSQL"
else
  log "[SKIP] Harbor не запущен"
fi

# Vault
log ""
log "--- Vault ---"
if command -v vault &>/dev/null && systemctl is-active --quiet vault 2>/dev/null; then
  mkdir -p "$BACKUP_DIR/vault"
  if vault operator raft snapshot save "$BACKUP_DIR/vault/vault.snap" 2>/dev/null; then
    ok "Vault Raft snapshot"
  else
    tar -czf "$BACKUP_DIR/vault/vault-data.tar.gz" /var/lib/vault/ 2>/dev/null && \
      ok "Vault файловое хранилище" || fail "Vault данные"
  fi
  cp /etc/vault.d/vault.hcl "$BACKUP_DIR/vault/" 2>/dev/null && ok "Vault конфиг" || true
else
  log "[SKIP] Vault не запущен"
fi

# GitLab
log ""
log "--- GitLab ---"
if command -v gitlab-backup &>/dev/null; then
  mkdir -p "$BACKUP_DIR/gitlab"
  CRON=1 gitlab-backup create SKIP="builds,artifacts" 2>/dev/null | tail -2 | tee -a "$LOG_FILE"
  latest_backup=$(find /var/opt/gitlab/backups -name "*_gitlab_backup.tar" -newer "$BACKUP_ROOT" 2>/dev/null | head -1)
  if [ -n "$latest_backup" ]; then
    mv "$latest_backup" "$BACKUP_DIR/gitlab/"
    cp /etc/gitlab/gitlab-secrets.json "$BACKUP_DIR/gitlab/" 2>/dev/null
    ok "GitLab данные + секреты"
  else
    fail "GitLab backup не создан"
  fi
else
  log "[SKIP] GitLab не установлен"
fi

# Сертификаты
log ""
log "--- Сертификаты и ключи ---"
mkdir -p "$BACKUP_DIR/certs"
for dir in /etc/ssl/private /etc/vault.d/tls /etc/harbor/ssl /opt/ca; do
  [ -d "$dir" ] && tar -czf "$BACKUP_DIR/certs/$(basename $dir).tar.gz" "$dir/" 2>/dev/null && \
    ok "Сертификаты: $dir" || true
done

# Конфигурации Docker
log ""
log "--- Docker конфигурация ---"
mkdir -p "$BACKUP_DIR/docker"
cp /etc/docker/daemon.json "$BACKUP_DIR/docker/" 2>/dev/null && ok "daemon.json" || true
cp -r /etc/docker/certs.d "$BACKUP_DIR/docker/" 2>/dev/null && ok "certs.d" || true

# Контрольные суммы
log ""
log "--- Контрольные суммы ---"
find "$BACKUP_DIR" -type f ! -name "*.sha256" \
  -exec sha256sum {} \; > "$BACKUP_DIR/checksums.sha256" 2>/dev/null
ok "checksums.sha256"

# Итог
log ""
log "=== Резервное копирование завершено ==="
log "  Успешно: $SUCCESS"
log "  Ошибок:  $FAILED"
log "  Размер:  $(du -sh "$BACKUP_DIR" | cut -f1)"

[ "$FAILED" -eq 0 ] || exit 1
