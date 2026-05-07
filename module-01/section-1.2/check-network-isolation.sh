#!/usr/bin/env bash
# Проверка сетевой изоляции Docker-хоста: внешние маршруты, DNS, NTP
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка сетевой изоляции: $(hostname) | $(date '+%Y-%m-%d %H:%M') ==="

echo ""
echo "--- Связность с внешними адресами ---"
for addr in 8.8.8.8 1.1.1.1 77.88.8.8; do
  if ping -c1 -W2 "$addr" &>/dev/null 2>&1; then
    fail "Внешний адрес $addr ДОСТУПЕН — изоляция нарушена"
  else
    ok "Внешний адрес $addr недоступен"
  fi
done

echo ""
echo "--- Маршрут по умолчанию ---"
default_gw=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
if [ -z "$default_gw" ]; then
  ok "Маршрут по умолчанию отсутствует"
else
  warn "Маршрут по умолчанию через $default_gw — проверьте, ведёт ли он наружу"
fi

echo ""
echo "--- DNS-конфигурация ---"
if [ -f /etc/resolv.conf ]; then
  while read -r line; do
    [[ "$line" =~ ^nameserver ]] || continue
    dns_ip=$(echo "$line" | awk '{print $2}')
    if echo "$dns_ip" | grep -qE '^(8\.8|1\.1|9\.9|77\.88)\.'; then
      fail "DNS-сервер $dns_ip — публичный, будет недоступен в закрытом контуре"
    else
      ok "DNS-сервер $dns_ip — внутренний"
    fi
  done < /etc/resolv.conf
fi

echo ""
echo "--- Docker-сети ---"
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  bridge_containers=$(docker network inspect bridge \
    --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null | xargs)
  if [ -n "$bridge_containers" ]; then
    warn "Контейнеры в дефолтной сети docker0: $bridge_containers"
  else
    ok "Дефолтная сеть docker0 пуста"
  fi

  host_containers=$(docker ps --filter network=host --format '{{.Names}}' 2>/dev/null | xargs)
  if [ -n "$host_containers" ]; then
    warn "Контейнеры с --network=host: $host_containers"
  else
    ok "Контейнеров с --network=host нет"
  fi
fi

echo ""
echo "--- Синхронизация времени ---"
if command -v timedatectl &>/dev/null; then
  synced=$(timedatectl show --property=NTPSynchronized --value 2>/dev/null || echo "no")
  [ "$synced" = "yes" ] && ok "Время синхронизировано по NTP" || \
    warn "Время НЕ синхронизировано — это вызовет проблемы с TLS и Vault"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || { echo "КРИТИЧЕСКИЕ ПРОБЛЕМЫ: устраните FAIL перед развёртыванием"; exit 1; }
