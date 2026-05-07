#!/usr/bin/env bash
# Вывод активных сетевых соединений для указанного контейнера через nsenter
# Использование: bash show-container-connections.sh <имя_или_id_контейнера>
set -euo pipefail

CONTAINER="${1:-}"
[ -n "$CONTAINER" ] || { echo "Использование: $0 <имя_контейнера>"; exit 1; }

pid=$(docker inspect "$CONTAINER" --format '{{.State.Pid}}' 2>/dev/null)
[ "${pid:-0}" -gt 0 ] || { echo "Контейнер $CONTAINER не найден или не запущен"; exit 1; }

echo "=== Сетевые соединения контейнера: $CONTAINER (PID=$pid) ==="
echo ""
echo "--- Интерфейсы ---"
nsenter -t "$pid" -n ip addr show 2>/dev/null

echo ""
echo "--- Маршруты ---"
nsenter -t "$pid" -n ip route show 2>/dev/null

echo ""
echo "--- Активные соединения (TCP ESTABLISHED) ---"
nsenter -t "$pid" -n ss -tnp state established 2>/dev/null || \
nsenter -t "$pid" -n netstat -tnp 2>/dev/null | grep ESTABLISHED

echo ""
echo "--- DNS (/etc/resolv.conf) ---"
nsenter -t "$pid" -m cat /etc/resolv.conf 2>/dev/null || \
docker exec "$CONTAINER" cat /etc/resolv.conf 2>/dev/null
