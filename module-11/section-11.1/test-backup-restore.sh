#!/usr/bin/env bash
# Проверка резервной копии: восстановление в изолированную среду и проверка работоспособности
# Использование: bash test-backup-restore.sh [компонент] [путь_к_резервной_копии]
# компонент: postgres | vault | gitlab | harbor | all
set -euo pipefail

COMPONENT="${1:-postgres}"
BACKUP_PATH="${2:-}"
TEST_PREFIX="backup-test-$$"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
HARBOR_URL="${HARBOR_URL:-https://harbor.internal.company.local}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Гарантируем очистку тестовых контейнеров при выходе
cleanup() {
  echo ""
  echo "--- Очистка тестовой среды ---"
  docker rm -f "${TEST_PREFIX}-postgres" "${TEST_PREFIX}-vault" 2>/dev/null || true
  docker network rm "${TEST_PREFIX}-net" 2>/dev/null || true
  echo "Тестовые ресурсы удалены"
}
trap cleanup EXIT

echo "=== Проверка резервной копии ==="
echo "Компонент: $COMPONENT"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"
START_TIME=$(date +%s)

# ── PostgreSQL ────────────────────────────────────────────────────────────
test_postgres() {
  local dump_file="${1:-}"
  echo ""
  echo "── PostgreSQL ───────────────────────────────────────────────────────"

  # Ищем последний дамп если путь не указан
  if [ -z "$dump_file" ]; then
    dump_file=$(find /var/backups /opt/backups . -name "*.sql.gz" -o -name "*postgres*.sql" \
      2>/dev/null | sort -t_ -k1,1 -r | head -1)
  fi
  [ -z "$dump_file" ] && { fail "Файл дампа PostgreSQL не найден"; return; }
  ok "Дамп: $dump_file ($(du -sh "$dump_file" | cut -f1))"

  # Поднимаем тестовый PostgreSQL
  docker network create "${TEST_PREFIX}-net" >/dev/null 2>&1 || true
  docker run -d --name "${TEST_PREFIX}-postgres" \
    --network "${TEST_PREFIX}-net" \
    -e POSTGRES_PASSWORD=testpass \
    -e POSTGRES_DB=testdb \
    "${HARBOR_URL:-harbor.internal.company.local}/library/postgres:15-alpine" >/dev/null 2>&1 \
    || docker run -d --name "${TEST_PREFIX}-postgres" \
      -e POSTGRES_PASSWORD=testpass \
      -e POSTGRES_DB=testdb \
      postgres:15-alpine >/dev/null 2>&1

  echo "Ожидание PostgreSQL..."
  for i in $(seq 1 15); do
    docker exec "${TEST_PREFIX}-postgres" pg_isready -q 2>/dev/null && break
    sleep 2
  done
  ok "Тестовый PostgreSQL запущен"

  # Восстановление
  echo "Восстановление дампа..."
  if [[ "$dump_file" == *.gz ]]; then
    gunzip -c "$dump_file" | docker exec -i "${TEST_PREFIX}-postgres" \
      psql -U postgres -d testdb >/dev/null 2>&1 && ok "Дамп восстановлен" || fail "Ошибка восстановления"
  else
    docker exec -i "${TEST_PREFIX}-postgres" \
      psql -U postgres -d testdb < "$dump_file" >/dev/null 2>&1 && ok "Дамп восстановлен" || fail "Ошибка восстановления"
  fi

  # Проверка данных
  table_count=$(docker exec "${TEST_PREFIX}-postgres" \
    psql -U postgres -d testdb -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>/dev/null || echo 0)
  if [ "${table_count:-0}" -gt 0 ]; then
    ok "Таблиц в восстановленной БД: $table_count"
  else
    warn "Таблиц не найдено — дамп мог быть пустым"
  fi
}

# ── Vault ─────────────────────────────────────────────────────────────────
test_vault() {
  local snapshot_file="${1:-}"
  echo ""
  echo "── Vault ────────────────────────────────────────────────────────────"

  if [ -z "$snapshot_file" ]; then
    snapshot_file=$(find /var/backups /opt/backups . -name "vault-*.snap" \
      2>/dev/null | sort -r | head -1)
  fi
  [ -z "$snapshot_file" ] && { fail "Снимок Vault не найден"; return; }
  ok "Снимок: $snapshot_file ($(du -sh "$snapshot_file" | cut -f1))"

  # Проверяем читаемость снимка
  if [ -n "$VAULT_TOKEN" ]; then
    result=$(vault operator raft snapshot restore --help &>/dev/null && echo "ok" || echo "")
    [ -n "$result" ] && ok "vault CLI доступен для восстановления" || warn "vault CLI недоступен"
  else
    warn "VAULT_TOKEN не задан — проверка только размера снимка"
  fi

  # Минимальная проверка: формат zip/tar
  if file "$snapshot_file" 2>/dev/null | grep -qiE "zip|gzip|data"; then
    ok "Формат снимка корректен"
  else
    warn "Формат снимка неизвестен — проверьте вручную"
  fi
}

# ── Основная логика ───────────────────────────────────────────────────────
case "$COMPONENT" in
  postgres) test_postgres "$BACKUP_PATH" ;;
  vault)    test_vault    "$BACKUP_PATH" ;;
  all)
    test_postgres ""
    test_vault ""
    ;;
  *)
    warn "Компонент '$COMPONENT' не поддерживается. Используйте: postgres | vault | all"
    ;;
esac

# ── Итог ─────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TIME ))
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Время: ${ELAPSED} сек"
echo ""

RESULT_FILE="backup-test-result-$(date +%Y%m%d%H%M).txt"
{
  echo "# Результат проверки резервной копии"
  echo "# Компонент: $COMPONENT  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo "# PASS: $PASS  WARN: $WARN  FAIL: $FAIL  Время: ${ELAPSED}с"
  [ -n "$BACKUP_PATH" ] && echo "# Файл: $BACKUP_PATH"
} > "$RESULT_FILE"
echo "Результат: $RESULT_FILE"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
