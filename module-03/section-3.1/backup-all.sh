#!/usr/bin/env bash
# Резервное копирование всех компонентов Harbor: PostgreSQL и blob storage
# Использование: bash backup-all.sh [директория_резервных_копий]
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

BACKUP_DIR="${1:-/opt/harbor-backups}"
DATE=$(date +%Y%m%d_%H%M%S)
HARBOR_DIR="${HARBOR_DIR:-/opt/harbor}"
HARBOR_DATA="${HARBOR_DATA:-/data}"

echo "=== Резервное копирование Harbor ==="
echo "Хост: $(hostname)  |  Дата: $(date)"
echo "Директория резервных копий: $BACKUP_DIR"
echo ""

mkdir -p "$BACKUP_DIR"

# --- Секция: Проверка состояния Harbor ---
echo "--- Состояние Harbor перед резервным копированием ---"
if command -v docker &>/dev/null && docker compose -f "$HARBOR_DIR/docker-compose.yml" ps 2>/dev/null | grep -q 'running\|Up'; then
  ok "Harbor запущен — приступаем к резервному копированию"
  HARBOR_RUNNING=1
else
  warn "Harbor не запущен или docker-compose.yml не найден — продолжаем резервное копирование данных"
  HARBOR_RUNNING=0
fi

echo ""

# --- Секция: Harbor — резервная копия PostgreSQL ---
echo "--- PostgreSQL (база данных Harbor) ---"
PG_BACKUP="$BACKUP_DIR/harbor-db-$DATE.sql.gz"

# Находим контейнер PostgreSQL Harbor
pg_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E 'harbor-db|postgresql' | head -1 || true)

if [ -n "$pg_container" ]; then
  if docker exec "$pg_container" pg_dumpall -U postgres 2>/dev/null | gzip > "$PG_BACKUP"; then
    size=$(du -sh "$PG_BACKUP" | cut -f1)
    ok "PostgreSQL: дамп создан — $PG_BACKUP ($size)"
  else
    fail "PostgreSQL: ошибка при создании дампа"
  fi
else
  # Попытка через прямое подключение
  warn "Контейнер PostgreSQL не найден — попытка через docker exec с harbor-db"
  if docker exec harbor-db pg_dumpall -U postgres 2>/dev/null | gzip > "$PG_BACKUP"; then
    ok "PostgreSQL: дамп создан через harbor-db — $PG_BACKUP"
  else
    fail "PostgreSQL: резервную копию создать не удалось — проверьте имя контейнера"
  fi
fi

echo ""

# --- Секция: Harbor — blob storage ---
echo "--- Blob storage (данные образов) ---"
BLOB_BACKUP="$BACKUP_DIR/harbor-data-$DATE.tar.gz"

if [ -d "$HARBOR_DATA/registry" ]; then
  echo "  Архивирование $HARBOR_DATA/registry ..."
  if tar -czf "$BLOB_BACKUP" -C "$HARBOR_DATA" registry 2>/dev/null; then
    size=$(du -sh "$BLOB_BACKUP" | cut -f1)
    ok "Blob storage: архив создан — $BLOB_BACKUP ($size)"
  else
    fail "Blob storage: ошибка при архивировании"
  fi
elif [ -d "$HARBOR_DATA" ]; then
  warn "Директория $HARBOR_DATA/registry не найдена — архивируем весь $HARBOR_DATA"
  tar -czf "$BLOB_BACKUP" -C "$(dirname "$HARBOR_DATA")" "$(basename "$HARBOR_DATA")" 2>/dev/null && \
    ok "Blob storage: архив создан — $BLOB_BACKUP" || \
    fail "Blob storage: ошибка при архивировании"
else
  fail "Директория данных Harbor $HARBOR_DATA не найдена"
fi

echo ""

# --- Секция: Harbor — конфигурационные файлы ---
echo "--- Конфигурация Harbor ---"
CONF_BACKUP="$BACKUP_DIR/harbor-config-$DATE.tar.gz"

if [ -d "$HARBOR_DIR" ]; then
  tar -czf "$CONF_BACKUP" \
    --exclude='$HARBOR_DIR/common/config/core/app.conf' \
    -C "$(dirname "$HARBOR_DIR")" "$(basename "$HARBOR_DIR")" 2>/dev/null && \
    ok "Конфигурация: архив создан — $CONF_BACKUP" || \
    warn "Конфигурация: частичная резервная копия (проверьте права)"
else
  warn "Директория Harbor $HARBOR_DIR не найдена"
fi

echo ""

# --- Контрольные суммы ---
echo "--- Контрольные суммы ---"
LOG_FILE="$BACKUP_DIR/harbor-backup-$DATE.log"
{
  echo "Дата: $(date)"
  echo "Хост: $(hostname)"
  echo ""
  for f in "$PG_BACKUP" "$BLOB_BACKUP" "$CONF_BACKUP"; do
    [ -f "$f" ] && sha256sum "$f"
  done
} > "$LOG_FILE"
ok "Контрольные суммы записаны в $LOG_FILE"

echo ""

# --- Очистка старых резервных копий (старше 14 дней) ---
echo "--- Очистка резервных копий старше 14 дней ---"
deleted=$(find "$BACKUP_DIR" -name "harbor-*" -mtime +14 -type f -delete -print 2>/dev/null | wc -l || true)
[ "${deleted:-0}" -gt 0 ] && ok "Удалено старых файлов: $deleted" || ok "Старых резервных копий нет"

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  echo "КРИТИЧЕСКИЕ ОШИБКИ: резервное копирование выполнено не полностью"
  exit 1
fi
echo "Артефакт для аудита: $LOG_FILE"
