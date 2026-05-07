#!/usr/bin/env bash
# Инвентаризация базовых образов в локальном реестре Harbor
# Использование: bash inventory-base-images.sh [harbor_host]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
OUTPUT="${2:-/tmp/base-images-inventory.csv}"

echo "=== Инвентаризация базовых образов ==="
echo "  Harbor: $HARBOR_HOST"

[ -n "$HARBOR_PASS" ] || { echo "[FAIL] HARBOR_PASS не установлен"; exit 1; }

# Заголовок CSV
echo "project,repository,tag,digest,created,size_mb,os,arch" > "$OUTPUT"

# Получение проектов
echo ""
echo "--- Получение списка проектов ---"
projects=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
  "https://$HARBOR_HOST/api/v2.0/projects?page_size=100" \
  2>/dev/null | python3 -c "
import json, sys
projects = json.load(sys.stdin)
for p in projects:
    print(p['name'])
" 2>/dev/null || echo "library base")

for project in $projects; do
  echo "  Проект: $project"

  # Получение репозиториев
  repos=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "https://$HARBOR_HOST/api/v2.0/projects/$project/repositories?page_size=100" \
    2>/dev/null | python3 -c "
import json, sys
try:
    repos = json.load(sys.stdin)
    for r in repos:
        print(r['name'].split('/', 1)[-1])
except:
    pass
" 2>/dev/null || true)

  for repo in $repos; do
    # Получение тегов
    tags=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
      "https://$HARBOR_HOST/api/v2.0/projects/$project/repositories/$(echo "$repo" | sed 's|/|%2F|g')/artifacts?page_size=50" \
      2>/dev/null | python3 -c "
import json, sys
try:
    artifacts = json.load(sys.stdin)
    for a in artifacts:
        digest = a.get('digest', '')[:20]
        created = a.get('push_time', '')[:10]
        size_mb = round(a.get('size', 0) / 1024 / 1024, 1)
        os_arch = a.get('platform', {})
        os_ = os_arch.get('os', '?')
        arch = os_arch.get('architecture', '?')
        for tag in a.get('tags', []):
            print(f\"{tag['name']}|{digest}|{created}|{size_mb}|{os_}|{arch}\")
except:
    pass
" 2>/dev/null || true)

    for tag_info in $tags; do
      IFS='|' read -r tag digest created size_mb os arch <<< "$tag_info"
      echo "$project,$repo,$tag,$digest,$created,$size_mb,$os,$arch" >> "$OUTPUT"
    done
  done
done

echo ""
count=$(wc -l < "$OUTPUT")
echo "  Всего записей: $((count - 1))"
echo "  Файл: $OUTPUT"

# Поиск устаревших образов (старше 90 дней)
echo ""
echo "--- Образы старше 90 дней ---"
cutoff=$(date -d "90 days ago" +%Y-%m-%d 2>/dev/null || date -v-90d +%Y-%m-%d 2>/dev/null || echo "")
if [ -n "$cutoff" ]; then
  old_count=$(awk -F, -v d="$cutoff" 'NR>1 && $5 < d && $5 != "" {print $1"/"$2":"$3}' "$OUTPUT" | wc -l)
  echo "  Устаревших: $old_count"
  [ "$old_count" -gt 0 ] && \
    awk -F, -v d="$cutoff" 'NR>1 && $5 < d && $5 != "" {print "  "$1"/"$2":"$3" ("$5")"}' "$OUTPUT" | head -10
fi

echo ""
echo "=== Инвентаризация завершена: $OUTPUT ==="
