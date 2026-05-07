#!/usr/bin/env bash
# Создание структуры проектов Harbor и базовых политик через API
# Использование: bash setup-harbor-projects.sh <harbor_url> <admin_password>
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_PASS="${2:-Harbor12345}"
HARBOR_USER="admin"

API="$HARBOR_URL/api/v2.0"
AUTH="-u $HARBOR_USER:$HARBOR_PASS"

echo "=== Настройка проектов Harbor ==="
echo "  URL: $HARBOR_URL"

# Функция создания проекта
create_project() {
  local name="$1" public="${2:-false}" quota_gb="${3:-0}"
  local quota_bytes=$(( quota_gb * 1073741824 ))

  payload=$(cat << EOF
{
  "project_name": "$name",
  "public": $public,
  "storage_limit": $([ "$quota_gb" -gt 0 ] && echo "$quota_bytes" || echo "-1")
}
EOF
)
  local http_code
  http_code=$(curl -sk $AUTH -o /dev/null -w "%{http_code}" \
    -X POST "$API/projects" \
    -H "Content-Type: application/json" \
    -d "$payload")
  case "$http_code" in
    201) echo "  [OK] Проект '$name' создан" ;;
    409) echo "  [INFO] Проект '$name' уже существует" ;;
    *)   echo "  [WARN] Проект '$name': HTTP $http_code" ;;
  esac
}

# Создание базовой структуры проектов
echo ""
echo "--- Создание проектов ---"
create_project "base"   "false" 0    # базовые образы ОС — без квоты, только для инфраструктуры
create_project "infra"  "false" 0    # Harbor, GitLab, Vault и другие компоненты
create_project "apps"   "false" 200  # образы приложений, квота 200 ГБ
create_project "dev"    "false" 50   # образы разработки, квота 50 ГБ
create_project "tools"  "false" 20   # инструменты CI/CD (Trivy, Kaniko и др.)

# Политики сканирования
echo ""
echo "--- Политики сканирования ---"
for project in base infra apps; do
  project_id=$(curl -sk $AUTH "$API/projects?name=$project" | \
    python3 -c "import json,sys; data=json.load(sys.stdin); print(data[0]['id'] if data else '')" 2>/dev/null || echo "")
  [ -z "$project_id" ] && continue

  # Включить автосканирование
  curl -sk $AUTH -o /dev/null -X PUT "$API/projects/$project_id" \
    -H "Content-Type: application/json" \
    -d '{"metadata":{"auto_scan":"true","prevent_vul":"true","severity":"critical"}}' && \
    echo "  [OK] Политика сканирования для '$project': auto-scan + блокировка Critical"
done

echo ""
echo "=== Структура проектов создана ==="
echo "  base  — базовые образы ОС и рантаймов"
echo "  infra — инфраструктурные компоненты"
echo "  apps  — образы приложений (квота 200 ГБ)"
echo "  dev   — образы разработки (квота 50 ГБ)"
echo "  tools — инструменты CI/CD (квота 20 ГБ)"
