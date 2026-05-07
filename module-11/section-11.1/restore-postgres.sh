#!/usr/bin/env bash
# Восстановление PostgreSQL из резервной копии с проверкой целостности
# Использование: bash restore-postgres.sh <dump_file> <db_name> [container_name]
set -euo pipefail

DUMP_FILE="${1:-}"
DB_NAME="${2:-}"
PG_CONTAINER="${3:-postgres}"
PG_USER="${POSTGRES_USER:-postgres}"

[ -n "$DUMP_FILE" ] && [ -n "$DB_NAME" ] || {
  echo "Использование: $0 <dump.sql.gz> <db_name> [container]"
  exit 1
}
[ -f "$DUMP_FILE" ] || { echo "[FAIL] Файл не найден: $DUMP_FILE"; exit 1; }

echo "=== Восстановление PostgreSQL ==="
echo "  Файл:      $DUMP_FILE"
echo "  База:      $DB_NAME"
echo "  Контейнер: $PG_CONTAINER"

# Проверка контейнера
docker exec "$PG_CONTAINER" psql -U "$PG_USER" -c "SELECT 1" &>/dev/null || {
  echo "[FAIL] PostgreSQL контейнер $PG_CONTAINER недоступен"
  exit 1
}

# Проверка контрольной суммы
SHA_FILE="${DUMP_FILE}.sha256"
echo ""
echo "--- Проверка целостности ---"
if [ -f "$SHA_FILE" ]; then
  sha256sum -c "$SHA_FILE" &>/dev/null && echo "  [OK] Контрольная сумма верна" || {
    echo "  [FAIL] Контрольная сумма не совпадает"
    exit 1
  }
else
  echo "  [WARN] Файл .sha256 не найден"
fi

# Создание целевой БД (если не существует)
echo ""
echo "--- Подготовка базы данных ---"
if docker exec "$PG_CONTAINER" psql -U "$PG_USER" -lqt 2>/dev/null | cut -d\| -f1 | grep -qw "$DB_NAME"; then
  echo "  [WARN] База $DB_NAME уже существует"
  read -r -p "  Удалить и восстановить? [y/N] " confirm
  [ "$confirm" = "y" ] || { echo "Отмена"; exit 0; }
  docker exec "$PG_CONTAINER" dropdb -U "$PG_USER" "$DB_NAME" 2>/dev/null
fi
docker exec "$PG_CONTAINER" createdb -U "$PG_USER" "$DB_NAME" 2>/dev/null
echo "  [OK] База $DB_NAME создана"

# Восстановление
echo ""
echo "--- Восстановление ---"
case "$DUMP_FILE" in
  *.sql.gz)
    gunzip -c "$DUMP_FILE" | docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$DB_NAME" 2>/dev/null
    ;;
  *.sql)
    docker exec -i "$PG_CONTAINER" psql -U "$PG_USER" "$DB_NAME" < "$DUMP_FILE" 2>/dev/null
    ;;
  *.dump)
    gunzip -c "$DUMP_FILE" 2>/dev/null | \
      docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$DB_NAME" -v 2>/dev/null || \
    docker exec -i "$PG_CONTAINER" pg_restore -U "$PG_USER" -d "$DB_NAME" "$DUMP_FILE" 2>/dev/null
    ;;
  *)
    echo "[FAIL] Неизвестный формат файла"
    exit 1
    ;;
esac
echo "  [OK] Данные восстановлены"

# Проверка
echo ""
echo "--- Проверка ---"
table_count=$(docker exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$DB_NAME" \
  -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'" \
  -t 2>/dev/null | tr -d ' ')
echo "  Таблиц в $DB_NAME: $table_count"

echo ""
echo "=== Восстановление завершено: $DB_NAME ==="
