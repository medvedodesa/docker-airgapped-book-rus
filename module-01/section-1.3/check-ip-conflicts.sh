#!/usr/bin/env bash
# Проверка пересечений IP-диапазонов Docker с существующими сетями хоста
# Использование: bash check-ip-conflicts.sh
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка IP-диапазонов Docker ==="
echo "Хост: $(hostname)  |  Дата: $(date)"
echo ""

DAEMON_JSON="/etc/docker/daemon.json"

# --- daemon.json ---
echo "--- Конфигурация daemon.json ---"
if [ ! -f "$DAEMON_JSON" ]; then
  fail "daemon.json не найден — Docker будет использовать 172.17.0.0/16 по умолчанию"
  DOCKER_BIP="172.17.0.0/16"
else
  custom_bip=$(python3 -c "
import json, sys
try:
  d = json.load(open('$DAEMON_JSON'))
  print(d.get('bip', ''))
except: pass
" 2>/dev/null || true)

  has_pools=$(python3 -c "
import json, sys
try:
  d = json.load(open('$DAEMON_JSON'))
  pools = d.get('default-address-pools', [])
  print('yes' if pools else '')
except: pass
" 2>/dev/null || true)

  if [ -n "$custom_bip" ]; then
    ok "daemon.json: bip задан явно — $custom_bip"
    DOCKER_BIP="$custom_bip"
  elif [ -n "$has_pools" ]; then
    ok "daemon.json: default-address-pools настроены явно"
    DOCKER_BIP=""
  else
    warn "daemon.json существует, но bip не задан — Docker использует 172.17.0.0/16"
    DOCKER_BIP="172.17.0.0/16"
  fi
fi

echo ""

# --- Системные маршруты ---
echo "--- Системные маршруты (ip route) ---"
system_routes=$(ip route show | awk '{print $1}' | grep -vE '^(default|via|dev|src|metric)' | grep -E '^[0-9]' || true)
if [ -z "$system_routes" ]; then
  warn "Таблица маршрутов пуста или не читается"
else
  echo "  Активные подсети:"
  echo "$system_routes" | sed 's/^/    /'
fi

echo ""

# --- Проверка 172.17.0.0/16 (Docker bridge по умолчанию) ---
echo "--- Диапазон Docker по умолчанию (172.17.0.0/16) ---"
default_conflict=$(ip route show | awk '{print $1}' | grep -E '^172\.17\.' || true)
if [ -n "$default_conflict" ]; then
  fail "Маршрут в 172.17.x.x уже существует: $default_conflict — Docker bridge по умолчанию создаст конфликт"
else
  ok "Диапазон 172.17.0.0/16 свободен"
fi

# --- Проверка заданного bip ---
echo ""
echo "--- Проверка заданного диапазона ---"
if [ -n "${DOCKER_BIP:-}" ] && [ "$DOCKER_BIP" != "172.17.0.0/16" ]; then
  bip_prefix=$(echo "$DOCKER_BIP" | cut -d/ -f1 | cut -d. -f1-3)
  bip_conflict=$(ip route show | awk '{print $1}' | grep -E "^$(echo "$bip_prefix" | sed 's/\./\\./g')\." || true)
  if [ -n "$bip_conflict" ]; then
    fail "Заданный диапазон $DOCKER_BIP конфликтует с маршрутом: $bip_conflict"
  else
    ok "Заданный диапазон $DOCKER_BIP не пересекается с существующими маршрутами"
  fi
fi

# --- Сети Docker (если Docker уже установлен) ---
echo ""
echo "--- Сети Docker (если Docker запущен) ---"
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  docker network ls --format '{{.Name}}' 2>/dev/null | while read -r net; do
    subnet=$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | xargs || true)
    [ -z "$subnet" ] && continue
    echo "  Сеть «$net»: $subnet"
  done
  ok "Сети Docker перечислены выше — сверьте с таблицей корпоративной адресации"
else
  ok "Docker не запущен — проверка выполнена по daemon.json и таблице маршрутов"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Устраните конфликты в daemon.json перед запуском Docker."
  exit 1
fi
