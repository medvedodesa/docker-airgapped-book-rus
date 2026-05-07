#!/usr/bin/env bash
# Проверка матрицы связности между всеми запущенными контейнерами
set -euo pipefail

echo "=== Аудит сетевой связности контейнеров ==="
echo "Дата: $(date '+%Y-%m-%d %H:%M')"
echo ""

containers=($(docker ps --format '{{.Names}}' 2>/dev/null))
[ ${#containers[@]} -eq 0 ] && { echo "Нет запущенных контейнеров"; exit 0; }

echo "--- Сетевые интерфейсы контейнеров ---"
for c in "${containers[@]}"; do
  nets=$(docker inspect "$c" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null | xargs)
  ip=$(docker inspect "$c" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null | xargs)
  printf "  %-30s сети: %-40s IP: %s\n" "$c" "$nets" "$ip"
done

echo ""
echo "--- Анализ DOCKER-USER цепочки iptables ---"
if iptables -L DOCKER-USER 2>/dev/null | grep -q "DOCKER-USER"; then
  rules=$(iptables -L DOCKER-USER --line-numbers 2>/dev/null | grep -v "^Chain\|^num\|^$")
  if [ -n "$rules" ]; then
    echo "  Правила в DOCKER-USER:"
    echo "$rules" | sed 's/^/    /'
  else
    echo "  DOCKER-USER пуста (нет дополнительных ограничений)"
  fi
fi

echo ""
echo "--- Мосты Docker ---"
ip link show type bridge 2>/dev/null | grep -E '^[0-9]+:' | awk '{print $2}' | tr -d ':' | while read br; do
  echo "  Мост: $br ($(ip addr show "$br" 2>/dev/null | grep 'inet ' | awk '{print $2}'))"
done
