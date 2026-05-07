#!/usr/bin/env bash
# Тест плана аварийного восстановления: проверка резервных копий без реального восстановления
# Использование: bash dr-test.sh [backup_dir]
set -euo pipefail

BACKUP_DIR="${1:-/opt/backup}"
TEST_LOG="/tmp/dr-test-$(date +%Y%m%d_%H%M%S).log"
PASS=0; WARN=0; FAIL=0

log()  { echo "[$(date +%H:%M:%S)] $1" | tee -a "$TEST_LOG"; }
ok()   { log "  [PASS] $1"; ((PASS++)); }
warn() { log "  [WARN] $1"; ((WARN++)); }
fail() { log "  [FAIL] $1"; ((FAIL++)); }

log "=== Тест плана аварийного восстановления ==="
log "  Каталог резервных копий: $BACKUP_DIR"
log "  Лог: $TEST_LOG"

# Поиск последней резервной копии
latest_backup=$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r | head -1)
[ -n "$latest_backup" ] && ok "Найдена резервная копия: $(basename $latest_backup)" || \
  { fail "Резервные копии не найдены в $BACKUP_DIR"; exit 1; }

log ""
log "--- Проверка контрольных сумм ---"
CHECKSUM_FILE="$latest_backup/checksums.sha256"
if [ -f "$CHECKSUM_FILE" ]; then
  cd "$latest_backup" && sha256sum --check "$CHECKSUM_FILE" 2>/dev/null | \
    grep -c "OK" | xargs -I{} log "  {} файл(ов) прошли проверку" || true
  failed_check=$(cd "$latest_backup" && sha256sum --check "$CHECKSUM_FILE" 2>/dev/null | grep "FAILED" | wc -l)
  [ "$failed_check" -eq 0 ] && ok "Контрольные суммы верны" || fail "$failed_check файл(ов) повреждены"
else
  warn "Файл контрольных сумм не найден"
fi

# Проверка Vault snapshot
log ""
log "--- Vault snapshot ---"
VAULT_SNAP=$(find "$latest_backup" -name "*.snap" 2>/dev/null | head -1)
if [ -n "$VAULT_SNAP" ]; then
  size=$(du -sh "$VAULT_SNAP" | cut -f1)
  ok "Vault snapshot: $size"
  # Проверка что файл не нулевой
  [ -s "$VAULT_SNAP" ] && ok "Snapshot не пустой" || fail "Snapshot пустой"
else
  warn "Vault snapshot не найден"
fi

# Проверка GitLab backup
log ""
log "--- GitLab backup ---"
GITLAB_BACKUP=$(find "$latest_backup" -name "*_gitlab_backup.tar" 2>/dev/null | head -1)
if [ -n "$GITLAB_BACKUP" ]; then
  size=$(du -sh "$GITLAB_BACKUP" | cut -f1)
  ok "GitLab backup: $size"
  tar -tf "$GITLAB_BACKUP" &>/dev/null && ok "GitLab tar архив целостен" || fail "GitLab архив повреждён"
else
  warn "GitLab backup не найден"
fi

# Проверка PostgreSQL dump
log ""
log "--- PostgreSQL dump ---"
PG_DUMP=$(find "$latest_backup" -name "*.sql.gz" 2>/dev/null | head -1)
if [ -n "$PG_DUMP" ]; then
  size=$(du -sh "$PG_DUMP" | cut -f1)
  ok "PostgreSQL dump: $size"
  gunzip -t "$PG_DUMP" 2>/dev/null && ok "Gzip целостен" || fail "Dump повреждён"
else
  warn "PostgreSQL dump не найден"
fi

# Проверка документации по восстановлению
log ""
log "--- Документация ---"
for doc in /opt/runbooks/restore-procedure.md /etc/dr/recovery-plan.md; do
  [ -f "$doc" ] && ok "Runbook: $doc" || warn "Runbook не найден: $doc"
done

# Дата резервной копии
backup_date=$(stat -c %Y "$latest_backup" 2>/dev/null || stat -f %m "$latest_backup" 2>/dev/null)
now=$(date +%s)
age_hours=$(( (now - backup_date) / 3600 ))
[ "$age_hours" -le 25 ] && ok "Резервная копия свежая: $age_hours ч. назад" || \
  warn "Резервная копия старше 24 ч.: $age_hours ч."

log ""
log "=== Итог DR-теста: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="

[ "$FAIL" -eq 0 ] || { log "  DR-тест: ПРОВАЛЕН"; exit 1; }
[ "$WARN" -eq 0 ] || log "  DR-тест: ПРОЙДЕН с предупреждениями"
log "  DR-тест: ПРОЙДЕН"
