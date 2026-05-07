#!/usr/bin/env bash
# Инвентаризация всех образов в Harbor через API
# Использование: bash image-inventory.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
OUTPUT="${IMAGE_INVENTORY_OUTPUT:-image-inventory-$(date +%Y%m%d).txt}"

if [ -z "$HARBOR_PASS" ]; then
  echo "Укажите пароль Harbor: переменная HARBOR_PASSWORD или третий аргумент"
  exit 1
fi

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)

api() { curl -sf -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1"; }

echo "=== Инвентаризация образов Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"
echo ""

{
  echo "# Инвентаризация образов Harbor"
  echo "# Реестр: $HARBOR_URL"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  total_repos=0
  total_tags=0
  total_size=0

  # Получаем список проектов
  projects=$(api "projects?page_size=100" | python3 -c "
import json,sys
for p in json.load(sys.stdin):
    print(p['name'])
" 2>/dev/null)

  for project in $projects; do
    echo "## Проект: $project"
    repos=$(api "projects/$project/repositories?page_size=500" 2>/dev/null || echo "[]")
    repo_count=$(echo "$repos" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    echo "   Репозиториев: $repo_count"

    echo "$repos" | python3 -c "
import json,sys
repos = json.load(sys.stdin)
for r in repos:
    name = r.get('name','')
    artifact_count = r.get('artifact_count', 0)
    size_bytes = r.get('size', 0)
    size_mb = size_bytes // (1024*1024)
    print(f'   {name}  ({artifact_count} тегов, {size_mb} МБ)')
" 2>/dev/null || true

    total_repos=$((total_repos + repo_count))
    echo ""
  done

  echo ""
  echo "## Сводка"
  echo "   Проектов:       $(echo "$projects" | wc -w | tr -d ' ')"
  echo "   Репозиториев:   $total_repos"

  # Общая статистика через системный API
  sys_info=$(api "systeminfo" 2>/dev/null || echo "{}")
  storage_total=$(echo "$sys_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_total',0)//1073741824)" 2>/dev/null || echo "N/A")
  storage_free=$(echo "$sys_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_free',0)//1073741824)" 2>/dev/null || echo "N/A")
  echo "   Хранилище:      ${storage_total} ГБ всего, ${storage_free} ГБ свободно"

} | tee "$OUTPUT"

echo ""
echo "Инвентарь сохранён: $OUTPUT"
