#!/usr/bin/env bash
# Регистрация нагрузки в SPIRE с Docker-отборами и проверкой выдачи SVID
# Использование: bash register-workload.sh <spiffe_id> <docker_image> [агент_spiffe_id]
set -euo pipefail

SPIFFE_ID="${1:-spiffe://internal.company.local/prod/api}"
DOCKER_IMAGE="${2:-harbor.internal/prod/api:latest}"
AGENT_SPIFFE_ID="${3:-spiffe://internal.company.local/agent/docker-host-01}"
SPIRE_SERVER_SOCKET="${SPIRE_SERVER_SOCKET:-/tmp/spire-server/private/api.sock}"

echo "=== Регистрация нагрузки в SPIRE ==="
echo "  SPIFFE ID:    $SPIFFE_ID"
echo "  Docker image: $DOCKER_IMAGE"
echo "  Agent ID:     $AGENT_SPIFFE_ID"

# Проверка доступности SPIRE Server
if ! spire-server api show -socketPath "$SPIRE_SERVER_SOCKET" &>/dev/null 2>&1; then
  echo "[FAIL] SPIRE Server недоступен по сокету $SPIRE_SERVER_SOCKET"
  exit 1
fi

# Регистрация
echo ""
echo "--- Создание записи регистрации ---"
spire-server entry create \
  -socketPath "$SPIRE_SERVER_SOCKET" \
  -parentID "$AGENT_SPIFFE_ID" \
  -spiffeID "$SPIFFE_ID" \
  -selector "docker:image=$DOCKER_IMAGE" \
  -ttl 3600 \
  2>&1

entry_id=$(spire-server entry show \
  -socketPath "$SPIRE_SERVER_SOCKET" \
  -spiffeID "$SPIFFE_ID" 2>/dev/null | \
  grep "Entry ID" | awk '{print $NF}' | head -1)

echo ""
if [ -n "$entry_id" ]; then
  echo "[OK] Запись создана: $entry_id"
  echo ""
  echo "Детали:"
  spire-server entry show -socketPath "$SPIRE_SERVER_SOCKET" -entryID "$entry_id"
else
  echo "[WARN] Проверьте список записей: spire-server entry show"
fi

echo ""
echo "Проверить выдачу SVID в контейнере:"
echo "  docker exec <container> /opt/spire/bin/spire-agent api fetch x509 -socketPath /run/spire/sockets/agent.sock"
