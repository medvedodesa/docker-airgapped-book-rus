#!/usr/bin/env bash
# Создание Robot Account в Harbor с заданным сроком действия
# Использование: bash create-robot-account.sh <harbor_url> <admin_pass> <project> <robot_name> [срок_дней]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
ADMIN_PASS="${2:-Harbor12345}"
PROJECT="${3:-apps}"
ROBOT_NAME="${4:-ci-robot}"
EXPIRE_DAYS="${5:-90}"
PERMISSIONS="${6:-pull,push}"

API="$HARBOR_URL/api/v2.0"
AUTH="-u admin:$ADMIN_PASS"

echo "=== Создание Robot Account ==="
echo "  Проект: $PROJECT | Имя: robot\$${ROBOT_NAME} | Срок: $EXPIRE_DAYS дней"

# Получить ID проекта
project_id=$(curl -sk $AUTH "$API/projects?name=$PROJECT" 2>/dev/null | \
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')" 2>/dev/null)
[ -n "$project_id" ] || { echo "Проект '$PROJECT' не найден"; exit 1; }

# Сформировать разрешения
access_list=""
for perm in $(echo "$PERMISSIONS" | tr ',' ' '); do
  case "$perm" in
    pull) access_list+='{"action":"pull","resource":"repository"},' ;;
    push) access_list+='{"action":"push","resource":"repository"},' ;;
    scan) access_list+='{"action":"create","resource":"scan"},' ;;
  esac
done
access_list="${access_list%,}"

# Дата истечения (unix timestamp)
expire_ts=$(date -d "+${EXPIRE_DAYS} days" +%s 2>/dev/null || \
            python3 -c "import time; print(int(time.time()) + $EXPIRE_DAYS * 86400)")

payload=$(cat << EOF
{
  "name": "$ROBOT_NAME",
  "description": "CI/CD robot account, expires $(date -d "+${EXPIRE_DAYS} days" +%Y-%m-%d 2>/dev/null || echo "in $EXPIRE_DAYS days")",
  "duration": $EXPIRE_DAYS,
  "permissions": [
    {
      "kind": "project",
      "namespace": "$PROJECT",
      "access": [$access_list]
    }
  ]
}
EOF
)

response=$(curl -sk $AUTH -X POST "$API/robots" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>/dev/null)

secret=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('secret',''))" 2>/dev/null)
name=$(echo "$response" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null)

if [ -n "$secret" ]; then
  echo ""
  echo "=== Robot Account создан ==="
  echo "  Имя:    $name"
  echo "  Пароль: $secret"
  echo "  Срок:   $EXPIRE_DAYS дней"
  echo ""
  echo "  ВАЖНО: сохраните пароль в Vault немедленно!"
  echo "  Команда: vault kv put secret/harbor/${PROJECT}/${ROBOT_NAME} username='$name' password='$secret'"
else
  echo "[FAIL] Ошибка создания Robot Account"
  echo "$response"
  exit 1
fi
