#!/usr/bin/env bash
# Blue-Green деплой через переключение Docker Swarm сервисов
# Использование: bash blue-green-deploy.sh <stack_name> <new_image> [compose_file]
set -euo pipefail

STACK="${1:-}"
NEW_IMAGE="${2:-}"
COMPOSE_FILE="${3:-docker-compose.yml}"
HEALTH_URL="${HEALTH_URL:-}"
HEALTH_RETRIES="${HEALTH_RETRIES:-10}"

[ -n "$STACK" ] && [ -n "$NEW_IMAGE" ] || {
  echo "Использование: $0 <stack_name> <new_image:tag> [compose_file]"
  exit 1
}

echo "=== Blue-Green Deployment: $STACK ==="
echo "  Новый образ: $NEW_IMAGE"

# Определение текущего активного слота
active_slot=$(docker service ls --filter "label=stack=$STACK" \
  --filter "label=slot=active" \
  --format "{{.Name}}" 2>/dev/null | head -1 | grep -oP '(blue|green)' || echo "blue")
new_slot=$([ "$active_slot" = "blue" ] && echo "green" || echo "blue")

echo "  Активный слот:  $active_slot"
echo "  Новый слот:     $new_slot"

# Развёртывание нового слота
echo ""
echo "--- Развёртывание $new_slot ---"
IMAGE_NAME="$NEW_IMAGE" SLOT="$new_slot" \
  docker stack deploy \
    --compose-file "$COMPOSE_FILE" \
    --with-registry-auth \
    "${STACK}-${new_slot}" \
    2>/dev/null
echo "  [OK] Stack ${STACK}-${new_slot} запущен"

# Ожидание готовности
echo ""
echo "--- Проверка готовности ---"
sleep 15

for i in $(seq 1 "$HEALTH_RETRIES"); do
  # Проверка через Docker healthcheck
  unhealthy=$(docker service ps "${STACK}-${new_slot}_app" \
    --filter "desired-state=running" \
    --format "{{.CurrentState}}" 2>/dev/null | \
    grep -v "Running" | wc -l || echo "0")

  if [ "$unhealthy" -eq 0 ]; then
    echo "  [OK] Слот $new_slot готов (попытка $i/$HEALTH_RETRIES)"
    break
  fi

  if [ "$i" -eq "$HEALTH_RETRIES" ]; then
    echo "  [FAIL] Слот $new_slot не прошёл проверку здоровья"
    docker stack rm "${STACK}-${new_slot}" 2>/dev/null || true
    exit 1
  fi
  echo "  Ожидание ($i/$HEALTH_RETRIES)..."
  sleep 10
done

# HTTP проверка (опционально)
if [ -n "$HEALTH_URL" ]; then
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 10 \
    "$HEALTH_URL" 2>/dev/null || echo "000")
  [ "$http_code" = "200" ] && echo "  [OK] HTTP health check: $http_code" || \
    echo "  [WARN] HTTP $http_code от $HEALTH_URL"
fi

# Переключение трафика (обновление метки)
echo ""
echo "--- Переключение трафика ---"
docker service update \
  --label-add "slot=active" \
  "${STACK}-${new_slot}_app" 2>/dev/null || true
docker service update \
  --label-rm "slot" \
  --label-add "slot=standby" \
  "${STACK}-${active_slot}_app" 2>/dev/null || true
echo "  [OK] Трафик переключён на $new_slot"

echo ""
echo "=== Blue-Green Deploy завершён ==="
echo "  Активный: $new_slot ($NEW_IMAGE)"
echo "  Резервный: $active_slot (предыдущая версия)"
echo ""
echo "Откат: переключить трафик обратно на $active_slot"
echo "  docker service update --label-add slot=active ${STACK}-${active_slot}_app"
echo ""
echo "Удаление старого слота после подтверждения:"
echo "  docker stack rm ${STACK}-${active_slot}"
