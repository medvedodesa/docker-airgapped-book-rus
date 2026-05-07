#!/usr/bin/env bash
# Проверка сетевой изоляции между контейнерами в разных сетях
set -euo pipefail

echo "=== Тест сетевой изоляции ==="

# Создать тестовые сети
docker network create test-net-a --subnet 172.30.0.0/24 --internal -q 2>/dev/null || true
docker network create test-net-b --subnet 172.31.0.0/24 --internal -q 2>/dev/null || true

# Запустить тест-контейнеры
docker run -d --name test-container-a --network test-net-a alpine sleep 60 &>/dev/null 2>&1 || true
docker run -d --name test-container-b --network test-net-b alpine sleep 60 &>/dev/null 2>&1 || true

ip_b=$(docker inspect test-container-b --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

echo "Контейнер A (test-net-a) → Контейнер B (test-net-b, $ip_b):"
if docker exec test-container-a ping -c1 -W2 "$ip_b" &>/dev/null 2>&1; then
  echo "  [FAIL] Контейнеры в разных сетях ВИДЯТ друг друга!"
else
  echo "  [OK] Контейнеры в разных сетях изолированы"
fi

# Очистка
docker rm -f test-container-a test-container-b &>/dev/null 2>&1 || true
docker network rm test-net-a test-net-b &>/dev/null 2>&1 || true
