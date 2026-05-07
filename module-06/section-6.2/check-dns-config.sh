#!/usr/bin/env bash
# Диагностика DNS: resolv.conf хоста, daemon.json, доступность резолверов
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Диагностика DNS ==="

echo ""
echo "--- resolv.conf хоста ---"
if [ -f /etc/resolv.conf ]; then
  while read -r line; do
    [[ "$line" =~ ^nameserver ]] || continue
    ip=$(echo "$line" | awk '{print $2}')
    echo "  Nameserver: $ip"
    if echo "$ip" | grep -qE '^(8\.8|1\.1|9\.9|77\.88)\.'; then
      fail "  $ip — публичный DNS, недоступен в закрытом контуре"
    else
      ok "  $ip — внутренний"
      ping -c1 -W2 "$ip" &>/dev/null && ok "  $ip доступен" || fail "  $ip НЕДОСТУПЕН"
    fi
  done < /etc/resolv.conf
fi

echo ""
echo "--- Docker daemon DNS ---"
if [ -f /etc/docker/daemon.json ]; then
  dns=$(python3 -c "import json; d=json.load(open('/etc/docker/daemon.json')); print(' '.join(d.get('dns',[])))" 2>/dev/null || echo "")
  [ -n "$dns" ] && ok "Docker DNS настроен: $dns" || warn "Docker DNS не настроен в daemon.json"
fi

echo ""
echo "--- DNS из контейнера ---"
if command -v docker &>/dev/null; then
  resolv_in_container=$(docker run --rm --network bridge alpine cat /etc/resolv.conf 2>/dev/null || echo "")
  echo "  /etc/resolv.conf в контейнере:"
  echo "$resolv_in_container" | head -5 | sed 's/^/    /'
  
  # Проверить 127.0.0.11
  if echo "$resolv_in_container" | grep -q "127.0.0.11"; then
    ok "Встроенный Docker DNS (127.0.0.11) активен"
  else
    warn "Встроенный Docker DNS 127.0.0.11 не обнаружен"
  fi
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
