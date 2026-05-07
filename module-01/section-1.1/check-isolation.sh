#!/usr/bin/env bash
# Проверка сетевой изоляции хоста: маршруты, соединения, DNS
set -euo pipefail

PASS=0; WARN=0; FAIL=0
log() { echo "[$1] $2"; }
ok()   { log "PASS" "$1"; ((PASS++)); }
warn() { log "WARN" "$1"; ((WARN++)); }
fail() { log "FAIL" "$1"; ((FAIL++)); }

echo "=== Проверка сетевой изоляции ==="
echo "Хост: $(hostname)  |  Дата: $(date)"
echo ""

# 1. Маршрут по умолчанию
echo "--- Маршруты ---"
default_gw=$(ip route show default 2>/dev/null | awk '/default/{print $3}' | head -1)
if [ -z "$default_gw" ]; then
  ok "Маршрут по умолчанию отсутствует"
else
  warn "Маршрут по умолчанию: $default_gw — проверьте, ведёт ли он во внешнюю сеть"
fi

# 2. Доступность внешних адресов
echo ""
echo "--- Доступность внешних адресов ---"
for host in 8.8.8.8 1.1.1.1 google.com; do
  if ping -c 1 -W 2 "$host" &>/dev/null; then
    fail "Внешний адрес $host доступен — нет изоляции!"
  else
    ok "Внешний адрес $host недоступен"
  fi
done

# 3. Активные соединения наружу
echo ""
echo "--- Активные соединения ---"
ext_conns=$(ss -tnp state established 2>/dev/null | awk 'NR>1{print $4}' | grep -Ev '^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' || true)
if [ -z "$ext_conns" ]; then
  ok "Активных соединений с внешними адресами не обнаружено"
else
  fail "Обнаружены соединения с внешними адресами:"
  echo "$ext_conns"
fi

# 4. DNS-серверы
echo ""
echo "--- DNS-конфигурация ---"
if [ -f /etc/resolv.conf ]; then
  dns_servers=$(grep '^nameserver' /etc/resolv.conf | awk '{print $2}')
  for dns in $dns_servers; do
    if echo "$dns" | grep -qE '^(8\.8\.|1\.1\.1\.|9\.9\.9\.)'; then
      fail "DNS-сервер $dns — публичный, недоступен в закрытом контуре"
    else
      ok "DNS-сервер $dns — внутренний"
    fi
  done
fi

# 5. VLAN vs воздушный зазор
echo ""
echo "--- Тип изоляции ---"
if ip link show | grep -qiE 'vlan|802\.1q'; then
  warn "Обнаружен VLAN-интерфейс — это логическая изоляция, не физический воздушный зазор"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
