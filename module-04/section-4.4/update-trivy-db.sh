#!/usr/bin/env bash
# Обновление базы данных уязвимостей Trivy в Harbor (закрытый контур).
# Запускать после получения новой базы через защищённый шлюз.
#
# Использование: sudo bash update-trivy-db.sh <каталог_с_базой>
# Пример: sudo bash update-trivy-db.sh /tmp/trivy-db-20260427

set -euo pipefail

DB_SOURCE="${1:-}"
TRIVY_CONTAINER="${TRIVY_CONTAINER:-trivy-adapter}"
TRIVY_DB_PATH="/home/scanner/.cache/trivy/db"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET} $1"; }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Требуются права root"
[ -n "$DB_SOURCE" ] || fail "Укажите каталог с базой: $0 /path/to/trivy-db"
[ -d "$DB_SOURCE" ] || fail "Каталог не найден: $DB_SOURCE"

log "Источник: $DB_SOURCE"

# Проверка контрольных сумм
if [ -f "$DB_SOURCE/SHA256SUMS" ]; then
    log "Проверка контрольных сумм..."
    (cd "$DB_SOURCE" && sha256sum -c SHA256SUMS) || fail "Контрольные суммы не совпадают"
    log "Контрольные суммы корректны"
else
    echo "[WARN] SHA256SUMS не найден, пропускаем проверку"
fi

# Проверка наличия контейнера Trivy
docker inspect "$TRIVY_CONTAINER" &>/dev/null || \
    fail "Контейнер $TRIVY_CONTAINER не найден. Harbor запущен?"

# Резервная копия текущей базы
BACKUP_DIR="/tmp/trivy-db-backup-$(date +%Y%m%d-%H%M%S)"
log "Резервная копия текущей базы → $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"
docker cp "${TRIVY_CONTAINER}:${TRIVY_DB_PATH}/." "$BACKUP_DIR/" 2>/dev/null || \
    log "Резервная копия не создана (база отсутствует)"

# Остановка Trivy adapter
log "Остановка $TRIVY_CONTAINER..."
docker stop "$TRIVY_CONTAINER"

# Обновление базы
log "Копирование новой базы..."
# Создать каталог в контейнере если не существует
docker start "$TRIVY_CONTAINER" &>/dev/null
sleep 2
docker exec "$TRIVY_CONTAINER" mkdir -p "$TRIVY_DB_PATH" 2>/dev/null || true
docker stop "$TRIVY_CONTAINER" &>/dev/null

for db_file in "$DB_SOURCE"/*.db "$DB_SOURCE"/metadata.json; do
    [ -f "$db_file" ] || continue
    docker cp "$db_file" "${TRIVY_CONTAINER}:${TRIVY_DB_PATH}/"
    log "  Скопирован: $(basename "$db_file")"
done

# Запуск Trivy adapter
log "Запуск $TRIVY_CONTAINER..."
docker start "$TRIVY_CONTAINER"

# Ожидание готовности
MAX_WAIT=30
for i in $(seq 1 $MAX_WAIT); do
    if docker exec "$TRIVY_CONTAINER" trivy --version &>/dev/null; then
        break
    fi
    sleep 1
done

# Проверка версии базы
log "Версия новой базы:"
docker exec "$TRIVY_CONTAINER" trivy --version 2>/dev/null | grep -A3 "Vulnerability DB" || \
    log "Информация о версии недоступна"

log "База данных уязвимостей обновлена"
log "Резервная копия предыдущей версии: $BACKUP_DIR"
