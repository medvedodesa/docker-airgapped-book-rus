#!/usr/bin/env bash
# Сбор криминалистических данных при инциденте ИБ
# Использование: bash collect-forensics.sh [container_id_or_name]
set -euo pipefail

TARGET="${1:-}"   # имя/ID контейнера или пусто для хоста
OUTPUT_DIR="/opt/forensics/$(date +%Y%m%d_%H%M%S)"
CHAIN_OF_CUSTODY="$OUTPUT_DIR/chain-of-custody.txt"

mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

{
echo "ЦЕПОЧКА ХРАНЕНИЯ ДОКАЗАТЕЛЬСТВ"
echo "================================"
echo "Дата сбора: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "Хост: $(hostname)"
echo "Собрал: $(whoami)"
echo "Объект: ${TARGET:-хост}"
echo "Каталог: $OUTPUT_DIR"
echo ""
} > "$CHAIN_OF_CUSTODY"

echo "=== Сбор криминалистических данных ==="
echo "  Каталог: $OUTPUT_DIR"

# === Состояние системы (фиксируется первым — изменяется быстрее всего) ===
echo ""
echo "--- Моментальный снимок состояния ---"
date -u > "$OUTPUT_DIR/timestamp.txt"

# Запущенные процессы
ps auxf > "$OUTPUT_DIR/processes.txt" 2>/dev/null
echo "  [OK] processes.txt"

# Сетевые соединения
ss -antp > "$OUTPUT_DIR/network-connections.txt" 2>/dev/null
ip route > "$OUTPUT_DIR/routes.txt" 2>/dev/null
echo "  [OK] network-connections.txt, routes.txt"

# Пользователи в системе
who > "$OUTPUT_DIR/logged-users.txt" 2>/dev/null
last -50 > "$OUTPUT_DIR/last-logins.txt" 2>/dev/null
echo "  [OK] logged-users.txt, last-logins.txt"

# === Docker ===
echo ""
echo "--- Docker состояние ---"
docker ps -a --no-trunc > "$OUTPUT_DIR/docker-containers.txt" 2>/dev/null
docker images --no-trunc > "$OUTPUT_DIR/docker-images.txt" 2>/dev/null
docker network ls > "$OUTPUT_DIR/docker-networks.txt" 2>/dev/null
echo "  [OK] docker-containers.txt, docker-images.txt"

# Конкретный контейнер
if [ -n "$TARGET" ]; then
  echo ""
  echo "--- Контейнер: $TARGET ---"
  docker inspect "$TARGET" > "$OUTPUT_DIR/container-inspect.json" 2>/dev/null
  echo "  [OK] container-inspect.json"

  # Логи контейнера
  docker logs "$TARGET" --timestamps 2>&1 > "$OUTPUT_DIR/container-logs.txt" 2>/dev/null
  echo "  [OK] container-logs.txt ($(wc -l < "$OUTPUT_DIR/container-logs.txt") строк)"

  # Изменённые файлы
  docker diff "$TARGET" > "$OUTPUT_DIR/container-diff.txt" 2>/dev/null
  echo "  [OK] container-diff.txt"

  # Экспорт файловой системы контейнера
  docker export "$TARGET" | gzip > "$OUTPUT_DIR/container-fs.tar.gz" 2>/dev/null
  echo "  [OK] container-fs.tar.gz"
fi

# === Системные логи ===
echo ""
echo "--- Системные журналы ---"
journalctl --since "1 hour ago" --no-pager > "$OUTPUT_DIR/journal-1h.txt" 2>/dev/null || \
  tail -5000 /var/log/syslog > "$OUTPUT_DIR/journal-1h.txt" 2>/dev/null
echo "  [OK] journal-1h.txt"

# Аудит
if [ -f /var/log/audit/audit.log ]; then
  tail -10000 /var/log/audit/audit.log > "$OUTPUT_DIR/audit.log" 2>/dev/null
  echo "  [OK] audit.log (последние 10000 строк)"
fi

# Vault audit
[ -f /var/log/vault/audit.log ] && \
  tail -5000 /var/log/vault/audit.log > "$OUTPUT_DIR/vault-audit.log" 2>/dev/null && \
  echo "  [OK] vault-audit.log"

# === Хэши для цепочки доказательств ===
echo ""
echo "--- Контрольные суммы ---"
find "$OUTPUT_DIR" -type f ! -name "*.sha256" ! -name "chain-of-custody.txt" \
  -exec sha256sum {} \; >> "$CHAIN_OF_CUSTODY"
sha256sum "$OUTPUT_DIR"/*.txt "$OUTPUT_DIR"/*.json "$OUTPUT_DIR"/*.tar.gz 2>/dev/null \
  > "$OUTPUT_DIR/checksums.sha256" 2>/dev/null || true
echo "  [OK] checksums.sha256"

# Финализация цепочки
echo "" >> "$CHAIN_OF_CUSTODY"
echo "Завершение сбора: $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$CHAIN_OF_CUSTODY"
echo "Размер каталога: $(du -sh "$OUTPUT_DIR" | cut -f1)" >> "$CHAIN_OF_CUSTODY"

echo ""
echo "=== Сбор завершён ==="
echo "  Каталог: $OUTPUT_DIR"
echo "  Размер:  $(du -sh "$OUTPUT_DIR" | cut -f1)"
echo ""
echo "  Передайте в НКЦКИ: bash send-incident-notification.sh"
echo "  Архив для следователей: tar -czf forensics-$(date +%Y%m%d).tar.gz $OUTPUT_DIR"
