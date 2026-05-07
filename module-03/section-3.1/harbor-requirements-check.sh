#!/usr/bin/env bash
# Проверка соответствия хоста требованиям Harbor перед установкой
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка требований Harbor ==="
echo ""

echo "--- CPU и память ---"
cpu_cores=$(nproc)
[ "$cpu_cores" -ge 4 ] && ok "CPU: $cpu_cores ядер (минимум 4)" || fail "CPU: $cpu_cores ядер — нужно минимум 4"

mem_gb=$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)
[ "$mem_gb" -ge 8 ] && ok "RAM: $mem_gb ГБ (минимум 8)" || fail "RAM: $mem_gb ГБ — нужно минимум 8"

echo ""
echo "--- Дисковое пространство ---"
data_dir="/data"
if [ -d "$data_dir" ]; then
  free_gb=$(df -BG "$data_dir" | awk 'NR==2{gsub("G",""); print $4}')
  [ "${free_gb:-0}" -ge 50 ] && ok "$data_dir: $free_gb ГБ свободно" || warn "$data_dir: $free_gb ГБ (рекомендуется 200+ ГБ для production)"
else
  free_gb=$(df -BG / | awk 'NR==2{gsub("G",""); print $4}')
  [ "${free_gb:-0}" -ge 50 ] && ok "Корневой раздел: $free_gb ГБ свободно" || fail "Корневой раздел: $free_gb ГБ — недостаточно"
  warn "Директория /data не существует — рекомендуется отдельный раздел"
fi

echo ""
echo "--- Docker ---"
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
  ok "Docker $docker_ver установлен"
else
  fail "Docker не установлен или daemon не запущен"
fi

if docker compose version &>/dev/null 2>&1; then
  ok "Docker Compose доступен"
else
  fail "Docker Compose plugin не установлен"
fi

echo ""
echo "--- Сеть ---"
for port in 80 443 4443; do
  if ss -tlnp | grep -q ":$port "; then
    warn "Порт $port уже занят — Harbor не сможет его использовать"
  else
    ok "Порт $port свободен"
  fi
done

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
