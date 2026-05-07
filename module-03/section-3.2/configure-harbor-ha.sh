#!/usr/bin/env bash
# Настройка двух экземпляров Harbor в конфигурации active-standby через репликацию
# Использование: bash configure-harbor-ha.sh [primary_url] [standby_url] [admin_user] [admin_pass]
set -euo pipefail

PRIMARY_URL="${1:-https://harbor-primary.internal.company.local}"
STANDBY_URL="${2:-https://harbor-standby.internal.company.local}"
HARBOR_USER="${3:-admin}"
HARBOR_PASS="${4:-${HARBOR_PASSWORD:-}}"
REPLICATION_INTERVAL="${HARBOR_REPL_INTERVAL:-0 * * * *}"  # каждый час по умолчанию

if [ -z "$HARBOR_PASS" ]; then
  echo "Укажите пароль Harbor: переменная HARBOR_PASSWORD или четвёртый аргумент"
  exit 1
fi

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)

api_primary() {
  curl -sf -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
    "$PRIMARY_URL/api/v2.0/$1" "${@:2}"
}
api_standby() {
  curl -sf -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
    "$STANDBY_URL/api/v2.0/$1" "${@:2}"
}

echo "=== Настройка Harbor active-standby ==="
echo "Primary:  $PRIMARY_URL"
echo "Standby:  $STANDBY_URL"
echo "Дата:     $(date '+%Y-%m-%d %H:%M')"

# --- Проверка доступности обоих экземпляров ---
echo ""
echo "--- Проверка доступности ---"
for url in "$PRIMARY_URL" "$STANDBY_URL"; do
  if curl -skf --max-time 10 "$url/api/v2.0/ping" >/dev/null 2>&1; then
    echo "[OK] Доступен: $url"
  else
    echo "[FAIL] Недоступен: $url"
    exit 1
  fi
done

# --- Создание endpoint для standby на primary ---
echo ""
echo "--- Регистрация standby как endpoint на primary ---"
ENDPOINT_NAME="standby-$(echo "$STANDBY_URL" | sed 's|https\?://||' | tr '.' '-')"

ENDPOINT_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'name': '$ENDPOINT_NAME',
  'type': 'harbor',
  'url': '$STANDBY_URL',
  'credential': {
    'type': 'basic',
    'access_key': '$HARBOR_USER',
    'access_secret': '$HARBOR_PASS'
  },
  'insecure': False,
  'description': 'Standby Harbor для active-standby конфигурации'
}))
")

endpoint_id=$(api_primary "registries" -X POST -d "$ENDPOINT_PAYLOAD" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null || echo "")

if [ -z "$endpoint_id" ]; then
  # Возможно endpoint уже существует
  endpoint_id=$(api_primary "registries?name=$ENDPOINT_NAME" 2>/dev/null | \
    python3 -c "import json,sys; lst=json.load(sys.stdin); print(lst[0].get('id','') if lst else '')" 2>/dev/null || echo "")
fi

if [ -n "$endpoint_id" ]; then
  echo "[OK] Endpoint зарегистрирован, ID: $endpoint_id"
else
  echo "[WARN] Не удалось создать или найти endpoint — создайте вручную через Harbor UI"
fi

# --- Создание политики репликации всех проектов ---
echo ""
echo "--- Создание политики репликации ---"
if [ -n "$endpoint_id" ]; then
  POLICY_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'name': 'ha-full-sync',
  'description': 'Полная синхронизация всех образов на standby',
  'src_registry': None,
  'dest_registry': {'id': int('$endpoint_id')},
  'dest_namespace': '',
  'dest_namespace_replace_count': 1,
  'trigger': {
    'type': 'scheduled',
    'trigger_settings': {'cron': '$REPLICATION_INTERVAL'}
  },
  'filters': [],
  'deletion': False,
  'override': True,
  'enabled': True,
  'speed': -1
}))
")

  policy_result=$(api_primary "replication/policies" -X POST -d "$POLICY_PAYLOAD" 2>/dev/null || echo "")
  if [ -n "$policy_result" ]; then
    echo "[OK] Политика репликации 'ha-full-sync' создана (расписание: $REPLICATION_INTERVAL)"
  else
    echo "[WARN] Не удалось создать политику — возможно уже существует. Проверьте Harbor UI."
  fi
fi

# --- Немедленная первичная синхронизация ---
echo ""
echo "--- Запуск первичной синхронизации ---"
if [ -n "$endpoint_id" ]; then
  policy_id=$(api_primary "replication/policies?name=ha-full-sync" 2>/dev/null | \
    python3 -c "import json,sys; lst=json.load(sys.stdin); print(lst[0].get('id','') if lst else '')" 2>/dev/null || echo "")

  if [ -n "$policy_id" ]; then
    api_primary "replication/executions" -X POST \
      -d "{\"policy_id\": $policy_id}" >/dev/null 2>&1 && \
      echo "[OK] Первичная синхронизация запущена (policy_id=$policy_id)" || \
      echo "[WARN] Не удалось запустить синхронизацию вручную"
  fi
fi

echo ""
echo "=== Настройка active-standby завершена ==="
echo ""
echo "Следующие шаги:"
echo "1. Проверьте статус репликации: Harbor Primary UI → Репликация → ha-full-sync"
echo "2. Настройте балансировщик (Nginx/HAProxy) для переключения на standby при недоступности primary"
echo "3. Проверьте резервирование: check-replication-status.sh $PRIMARY_URL $HARBOR_USER"
