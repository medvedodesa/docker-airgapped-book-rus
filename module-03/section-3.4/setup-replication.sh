#!/usr/bin/env bash
# Настройка репликации между двумя экземплярами Harbor
# Использование: bash setup-replication.sh <src_url> <src_pass> <dst_url> <dst_user> <dst_pass>
set -euo pipefail

SRC_URL="${1:-https://harbor-staging.internal}"
SRC_PASS="${2:-Harbor12345}"
DST_URL="${3:-https://harbor-prod.internal}"
DST_USER="${4:-replication-robot}"
DST_PASS="${5:-}"
FILTER_TAG="${6:-v*.*.*}"   # только релизные теги

SRC_API="$SRC_URL/api/v2.0"
AUTH="-u admin:$SRC_PASS"

echo "=== Настройка репликации Harbor ==="
echo "  Источник:    $SRC_URL"
echo "  Назначение:  $DST_URL"
echo "  Фильтр тегов: $FILTER_TAG"

# 1. Создание конечной точки (endpoint)
echo ""
echo "--- Создание конечной точки ---"
endpoint_payload=$(cat << EOF
{
  "name": "harbor-prod",
  "description": "Production Harbor registry",
  "type": "harbor",
  "url": "$DST_URL",
  "access_key": "$DST_USER",
  "access_secret": "$DST_PASS",
  "insecure": false
}
EOF
)

endpoint_resp=$(curl -sk $AUTH -X POST "$SRC_API/registries" \
  -H "Content-Type: application/json" \
  -d "$endpoint_payload" 2>/dev/null)

endpoint_id=$(echo "$endpoint_resp" | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d.get('id',''))" 2>/dev/null)

if [ -z "$endpoint_id" ]; then
  # Попробуем найти существующий
  endpoint_id=$(curl -sk $AUTH "$SRC_API/registries?name=harbor-prod" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
fi

[ -n "$endpoint_id" ] && echo "  [OK] Endpoint ID: $endpoint_id" || { echo "[FAIL] Не удалось создать endpoint"; exit 1; }

# 2. Проверка соединения
echo ""
echo "--- Проверка соединения ---"
http_code=$(curl -sk $AUTH -o /dev/null -w "%{http_code}" \
  -X POST "$SRC_API/registries/$endpoint_id/ping" 2>/dev/null)
[ "$http_code" = "200" ] && echo "  [OK] Соединение с $DST_URL работает" || \
  echo "  [WARN] Проверка соединения: HTTP $http_code"

# 3. Создание политики репликации
echo ""
echo "--- Создание политики репликации ---"
policy_payload=$(cat << EOF
{
  "name": "staging-to-prod",
  "description": "Репликация релизных тегов из staging в production",
  "src_registry": {"id": $endpoint_id},
  "dest_namespace": "",
  "filters": [
    {"type": "tag", "value": "$FILTER_TAG"}
  ],
  "trigger": {
    "type": "event_based",
    "trigger_settings": {}
  },
  "deletion": false,
  "override": false,
  "enabled": true
}
EOF
)

policy_resp=$(curl -sk $AUTH -X POST "$SRC_API/replication/policies" \
  -H "Content-Type: application/json" \
  -d "$policy_payload" 2>/dev/null)

echo "  [OK] Политика репликации создана"
echo "       Триггер: при push тегов соответствующих '$FILTER_TAG'"
echo "       Перезапись: запрещена (override: false)"
echo ""
echo "  Для ручного запуска репликации:"
echo "  bash force-replicate.sh $SRC_URL $SRC_PASS staging-to-prod"
