#!/usr/bin/env bash
# Поочерёдное обновление сервиса через Docker Swarm с проверкой здоровья
# Использование: bash rolling-update.sh <service_name> <new_image>
set -euo pipefail

SERVICE="${1:-}"
NEW_IMAGE="${2:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"
PARALLELISM="${PARALLELISM:-1}"
DELAY="${UPDATE_DELAY:-30s}"

[ -n "$SERVICE" ] && [ -n "$NEW_IMAGE" ] || {
  echo "Использование: $0 <service_name> <new_image:tag>"
  exit 1
}

echo "=== Rolling Update: $SERVICE ==="
echo "  Новый образ: $NEW_IMAGE"
echo "  Parallelism: $PARALLELISM"
echo "  Delay:       $DELAY"

# Проверка сервиса
current_image=$(docker service inspect "$SERVICE" \
  --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' 2>/dev/null || true)
[ -n "$current_image" ] || { echo "[FAIL] Сервис $SERVICE не найден"; exit 1; }
echo "  Текущий образ: $current_image"

# Запоминаем текущую версию для возможного отката
current_version=$(echo "$current_image" | cut -d: -f2)
echo "  Версия для отката: $current_version"

# Обновление
echo ""
echo "--- Запуск обновления ---"
docker service update \
  --image "$NEW_IMAGE" \
  --update-parallelism "$PARALLELISM" \
  --update-delay "$DELAY" \
  --update-failure-action rollback \
  --update-monitor 30s \
  --update-max-failure-ratio 0.3 \
  --rollback-parallelism 1 \
  --rollback-delay 10s \
  "$SERVICE" \
  2>/dev/null
echo "  [OK] Обновление запущено"

# Мониторинг
echo ""
echo "--- Ожидание завершения ---"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while true; do
  state=$(docker service inspect "$SERVICE" \
    --format '{{.UpdateStatus.State}}' 2>/dev/null || echo "unknown")

  case "$state" in
    completed)
      echo "  [OK] Обновление завершено успешно"
      break
      ;;
    rollback_completed)
      echo "  [FAIL] Произошёл откат — обновление не прошло проверку здоровья"
      exit 1
      ;;
    paused)
      echo "  [WARN] Обновление приостановлено"
      docker service update --update-resume "$SERVICE" 2>/dev/null || true
      ;;
  esac

  if [ "$(date +%s)" -gt "$deadline" ]; then
    echo "  [FAIL] Таймаут ожидания ($HEALTH_TIMEOUT сек)"
    exit 1
  fi
  echo "  Статус: $state ..."
  sleep 5
done

# Проверка реплик
echo ""
echo "--- Состояние реплик ---"
docker service ps "$SERVICE" \
  --filter "desired-state=running" \
  --format "{{.Name}}\t{{.Image}}\t{{.CurrentState}}" 2>/dev/null | head -10

echo ""
echo "=== Rolling Update завершён: $SERVICE → $NEW_IMAGE ==="
echo ""
echo "Откат при необходимости:"
echo "  docker service update --rollback $SERVICE"
