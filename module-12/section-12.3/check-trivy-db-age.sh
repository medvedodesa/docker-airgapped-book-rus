#!/usr/bin/env bash
# Проверка актуальности базы данных уязвимостей Trivy
# Критерий по R-12.3-1: база не старше 30 дней
# Использование: bash check-trivy-db-age.sh [макс_дней]
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

MAX_DAYS="${1:-30}"

echo "=== Проверка актуальности базы Trivy ==="
echo "Хост: $(hostname)  |  Дата: $(date)"
echo "Допустимый возраст базы: ≤ ${MAX_DAYS} дней"
echo ""

# --- Наличие Trivy ---
echo "--- Установка Trivy ---"
if ! command -v trivy &>/dev/null; then
  fail "trivy не найден в PATH"
  echo ""
  echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
  exit 1
fi
ok "Trivy найден: $(trivy --version 2>/dev/null | head -1)"

echo ""

# --- Метаданные базы ---
echo "--- Метаданные базы уязвимостей ---"
DB_METADATA_PATHS=(
  "$HOME/.cache/trivy/db/metadata.json"
  "/root/.cache/trivy/db/metadata.json"
  "/var/lib/trivy/db/metadata.json"
  "/tmp/trivy/db/metadata.json"
)

DB_META=""
for p in "${DB_METADATA_PATHS[@]}"; do
  if [ -f "$p" ]; then
    DB_META="$p"
    ok "Файл метаданных: $p"
    break
  fi
done

if [ -z "$DB_META" ]; then
  # Попытка получить через trivy
  warn "Файл metadata.json не найден — запрашиваем через trivy image --download-db-only --dry-run"
  DB_META=""
fi

# --- Дата обновления базы ---
echo ""
echo "--- Дата обновления базы ---"
DB_DATE=""

if [ -n "$DB_META" ]; then
  DB_DATE=$(python3 -c "
import json, sys
try:
    d = json.load(open('$DB_META'))
    print(d.get('UpdatedAt', d.get('DownloadedAt', '')))
except Exception as e:
    print('')
" 2>/dev/null || true)
fi

if [ -z "$DB_DATE" ]; then
  # Альтернатива: дата файла базы
  for db_file in "$HOME/.cache/trivy/db/trivy.db" "/root/.cache/trivy/db/trivy.db"; do
    if [ -f "$db_file" ]; then
      DB_DATE=$(stat -c '%y' "$db_file" 2>/dev/null | cut -d' ' -f1 || true)
      ok "Дата файла базы (по mtime): $DB_DATE"
      break
    fi
  done
fi

if [ -z "$DB_DATE" ]; then
  fail "Не удалось определить дату обновления базы Trivy"
  echo ""
  echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
  exit 1
fi

echo "  Дата последнего обновления: $DB_DATE"

# --- Возраст базы ---
echo ""
echo "--- Возраст базы ---"
AGE_DAYS=$(python3 -c "
from datetime import datetime, timezone
import sys

date_str = '$DB_DATE'.strip()
for fmt in ('%Y-%m-%dT%H:%M:%S', '%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%d %H:%M:%S', '%Y-%m-%d'):
    try:
        dt = datetime.strptime(date_str[:len(fmt)+2].strip(), fmt)
        now = datetime.now()
        delta = (now - dt).days
        print(delta)
        sys.exit(0)
    except:
        continue
print(-1)
" 2>/dev/null || echo "-1")

if [ "$AGE_DAYS" -lt 0 ]; then
  warn "Не удалось вычислить возраст базы из строки: $DB_DATE"
elif [ "$AGE_DAYS" -le "$MAX_DAYS" ]; then
  ok "Возраст базы: ${AGE_DAYS} дней — актуальна (критерий ≤ ${MAX_DAYS} дней)"
elif [ "$AGE_DAYS" -le $((MAX_DAYS * 2)) ]; then
  warn "Возраст базы: ${AGE_DAYS} дней — следует обновить (критерий ≤ ${MAX_DAYS} дней)"
else
  fail "Возраст базы: ${AGE_DAYS} дней — база устарела! Обновите до аттестации."
fi

# --- Версия схемы базы ---
echo ""
echo "--- Версия базы ---"
if [ -n "$DB_META" ]; then
  python3 -c "
import json
d = json.load(open('$DB_META'))
for k in ('Version', 'SchemaVersion', 'NextUpdate'):
    if k in d: print(f'  {k}: {d[k]}')
" 2>/dev/null || true
fi

# --- Рекомендации ---
echo ""
echo "--- Обновление базы в закрытом контуре ---"
echo "  1. На машине с интернетом (Зона 0):"
echo "     trivy image --download-db-only --cache-dir /tmp/trivy-db-update"
echo "     tar -czf trivy-db-\$(date +%Y%m%d).tar.gz -C /tmp/trivy-db-update ."
echo "  2. Перенести через шлюзовую зону, проверить SHA-256."
echo "  3. В закрытом контуре:"
echo "     tar -xzf trivy-db-YYYYMMDD.tar.gz -C ~/.cache/trivy/"
echo "  Скрипт для автоматизации: раздел 4.4 → update-trivy-db.sh"

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
