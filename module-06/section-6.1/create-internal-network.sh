#!/usr/bin/env bash
# Создание изолированной bridge-сети с проверкой отсутствия маршрута наружу
# Использование: bash create-internal-network.sh <имя> <подсеть> [mtu]
set -euo pipefail

NET_NAME="${1:-backend-net}"
SUBNET="${2:-172.20.0.0/24}"
MTU="${3:-1500}"

echo "=== Создание внутренней Docker-сети ==="
echo "  Имя: $NET_NAME | Подсеть: $SUBNET | MTU: $MTU"

docker network create \
  --driver bridge \
  --internal \
  --subnet "$SUBNET" \
  --opt "com.docker.network.driver.mtu=$MTU" \
  "$NET_NAME"

echo ""
echo "[OK] Сеть $NET_NAME создана (internal=true)"

# Проверка — запустить тест-контейнер и убедиться нет выхода наружу
echo ""
echo "--- Проверка изоляции ---"
if docker run --rm --network "$NET_NAME" alpine ping -c1 -W2 8.8.8.8 &>/dev/null 2>&1; then
  echo "[FAIL] Внешний адрес 8.8.8.8 ДОСТУПЕН — изоляция не работает!"
  exit 1
else
  echo "[OK] Внешние адреса недоступны — изоляция работает"
fi

docker network inspect "$NET_NAME" --format \
  'Сеть: {{.Name}} | Подсеть: {{range .IPAM.Config}}{{.Subnet}}{{end}} | Internal: {{.Internal}}'
