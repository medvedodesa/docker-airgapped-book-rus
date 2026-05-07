#!/usr/bin/env bash
# Полный аудит сетевой конфигурации Docker: сети, контейнеры, отклонения
set -euo pipefail

echo "=== Полный сетевой аудит Docker ==="
echo "Хост: $(hostname) | Дата: $(date)"
echo ""

echo "--- Docker-сети ---"
docker network ls --format 'table {{.ID}}\t{{.Name}}\t{{.Driver}}\t{{.Scope}}'

echo ""
echo "--- Подозрительные конфигурации ---"
# Контейнеры в дефолтной сети
b=$(docker network inspect bridge --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)
[ -n "$b" ] && echo "[WARN] В docker0: $b"

# Контейнеры с host network
h=$(docker ps --filter network=host --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
[ -n "$h" ] && echo "[WARN] --network=host: $h"

# Privileged
docker ps -q | while read cid; do
  priv=$(docker inspect "$cid" --format '{{.HostConfig.Privileged}}')
  name=$(docker inspect "$cid" --format '{{.Name}}' | tr -d '/')
  [ "$priv" = "true" ] && echo "[WARN] Privileged: $name"
done

echo ""
echo "--- Порты, опубликованные наружу ---"
docker ps --format '{{.Names}}: {{.Ports}}' | grep -v "^[^:]*: $" | head -20

echo ""
echo "--- Активные соединения контейнеров ---"
docker ps -q | while read cid; do
  name=$(docker inspect "$cid" --format '{{.Name}}' | tr -d '/')
  pid=$(docker inspect "$cid" --format '{{.State.Pid}}')
  [ "${pid:-0}" -gt 0 ] && \
    nsenter -t "$pid" -n ss -tn state established 2>/dev/null | awk 'NR>1{print "  " name": "$5}' name="$name" | head -3 || true
done
