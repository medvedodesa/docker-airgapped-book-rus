#!/usr/bin/env bash
# Инвентаризация всех Docker-сетей: подсети, драйверы, подключённые контейнеры
set -euo pipefail

echo "=== Инвентаризация Docker-сетей ==="
echo "Хост: $(hostname) | Дата: $(date '+%Y-%m-%d %H:%M')"
echo ""
printf "%-20s %-10s %-20s %-8s %s\n" "СЕТЬ" "ДРАЙВЕР" "ПОДСЕТЬ" "INTERNAL" "КОНТЕЙНЕРЫ"
echo "$(printf '%.0s-' {1..80})"

docker network ls --format '{{.ID}} {{.Name}} {{.Driver}}' | while read id name driver; do
  subnet=$(docker network inspect "$id" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)
  internal=$(docker network inspect "$id" --format '{{.Internal}}' 2>/dev/null)
  containers=$(docker network inspect "$id" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)
  [ -z "$containers" ] && containers="-"
  printf "%-20s %-10s %-20s %-8s %s\n" "$name" "$driver" "${subnet:--}" "$internal" "$containers"
done

echo ""
echo "--- Контейнеры в дефолтной сети docker0 (рекомендуется пустой список) ---"
bridge_containers=$(docker network inspect bridge --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)
[ -n "$bridge_containers" ] && echo "[WARN] В docker0: $bridge_containers" || echo "[OK] Пусто"

echo ""
echo "--- Контейнеры с --network=host ---"
host_containers=$(docker ps --filter network=host --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
[ -n "$host_containers" ] && echo "[WARN] С host network: $host_containers" || echo "[OK] Нет"
