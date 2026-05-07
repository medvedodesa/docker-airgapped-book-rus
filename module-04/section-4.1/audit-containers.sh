#!/usr/bin/env bash
# Аудит безопасности всех запущенных контейнеров Docker.
# Проверяет ключевые параметры безопасности каждого контейнера.
#
# Использование: bash audit-containers.sh [--json]

set -euo pipefail

OUTPUT_FORMAT="${1:-text}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

CONTAINERS=$(docker ps -q 2>/dev/null)
if [ -z "$CONTAINERS" ]; then
    echo "Нет запущенных контейнеров"
    exit 0
fi

TOTAL=0; ISSUES=0

for cid in $CONTAINERS; do
    TOTAL=$((TOTAL + 1))
    NAME=$(docker inspect --format '{{.Name}}' "$cid" | tr -d '/')
    IMAGE=$(docker inspect --format '{{.Config.Image}}' "$cid")

    echo "--- Контейнер: $NAME ($IMAGE) ---"

    # Privileged mode
    PRIV=$(docker inspect --format '{{.HostConfig.Privileged}}' "$cid")
    if [ "$PRIV" = "true" ]; then
        echo -e "  ${RED}[RISK]${RESET} Privileged режим включён"
        ISSUES=$((ISSUES + 1))
    fi

    # User
    USER=$(docker inspect --format '{{.Config.User}}' "$cid")
    if [ -z "$USER" ] || [ "$USER" = "root" ] || [ "$USER" = "0" ]; then
        echo -e "  ${YELLOW}[WARN]${RESET} Запущен от root"
        ISSUES=$((ISSUES + 1))
    else
        echo -e "  ${GREEN}[OK]${RESET}   Пользователь: $USER"
    fi

    # Read-only filesystem
    READONLY=$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$cid")
    if [ "$READONLY" = "true" ]; then
        echo -e "  ${GREEN}[OK]${RESET}   Корневая ФС: только чтение"
    else
        echo -e "  ${YELLOW}[WARN]${RESET} Корневая ФС: запись разрешена"
    fi

    # Network mode
    NETMODE=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$cid")
    if [ "$NETMODE" = "host" ]; then
        echo -e "  ${RED}[RISK]${RESET} Сеть хоста (--network=host)"
        ISSUES=$((ISSUES + 1))
    else
        echo -e "  ${GREEN}[OK]${RESET}   Сетевой режим: $NETMODE"
    fi

    # PID mode
    PIDMODE=$(docker inspect --format '{{.HostConfig.PidMode}}' "$cid")
    if [ "$PIDMODE" = "host" ]; then
        echo -e "  ${RED}[RISK]${RESET} PID пространство имён хоста (--pid=host)"
        ISSUES=$((ISSUES + 1))
    fi

    # Memory limit
    MEM=$(docker inspect --format '{{.HostConfig.Memory}}' "$cid")
    if [ "$MEM" -eq 0 ] 2>/dev/null; then
        echo -e "  ${YELLOW}[WARN]${RESET} Ограничение памяти не задано"
    else
        MEM_MB=$((MEM / 1024 / 1024))
        echo -e "  ${GREEN}[OK]${RESET}   Ограничение памяти: ${MEM_MB} МБ"
    fi

    # Capabilities
    CAP_ADD=$(docker inspect --format '{{.HostConfig.CapAdd}}' "$cid")
    if echo "$CAP_ADD" | grep -qi "SYS_ADMIN\|ALL"; then
        echo -e "  ${RED}[RISK]${RESET} Опасные capabilities: $CAP_ADD"
        ISSUES=$((ISSUES + 1))
    fi

    echo
done

echo "=== Итог аудита ==="
echo "Проверено контейнеров: $TOTAL"
echo -e "Обнаружено проблем: ${RED}$ISSUES${RESET}"
[ "$ISSUES" -eq 0 ] && echo -e "${GREEN}Все контейнеры соответствуют базовым требованиям.${RESET}"
