#!/usr/bin/env bash
# Обновление базового образа в Harbor и пересборка зависимых образов
# Использование: bash update-base-image.sh <base_image_archive> <harbor_project/repo:tag>
set -euo pipefail

ARCHIVE="${1:-}"
TARGET_REF="${2:-}"
HARBOR_HOST="${HARBOR_HOST:-harbor.internal.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
NOTIFY_WEBHOOK="${NOTIFY_WEBHOOK:-}"

[ -n "$ARCHIVE" ] && [ -n "$TARGET_REF" ] || {
  echo "Использование: $0 <archive.tar> <project/repo:tag>"
  exit 1
}

TARGET_IMAGE="${HARBOR_HOST}/${TARGET_REF}"
PROJECT=$(echo "$TARGET_REF" | cut -d/ -f1)
REPO=$(echo "$TARGET_REF" | cut -d/ -f2 | cut -d: -f1)

echo "=== Обновление базового образа ==="
echo "  Архив: $ARCHIVE"
echo "  Образ: $TARGET_IMAGE"

[ -f "$ARCHIVE" ] || { echo "[FAIL] Архив не найден"; exit 1; }
[ -n "$HARBOR_PASS" ] || { echo "[FAIL] HARBOR_PASS не установлен"; exit 1; }

# Фиксация текущего digest
echo ""
echo "--- Текущая версия ---"
old_digest=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
  "https://$HARBOR_HOST/api/v2.0/projects/$PROJECT/repositories/$(echo "$REPO" | sed 's|/|%2F|g')/artifacts?page_size=1" \
  2>/dev/null | python3 -c "
import json, sys
try:
    arts = json.load(sys.stdin)
    if arts:
        print(arts[0].get('digest', '')[:20])
except:
    print('')
" 2>/dev/null || echo "")
[ -n "$old_digest" ] && echo "  Текущий digest: $old_digest..." || echo "  Образ не найден (первая загрузка)"

# Загрузка нового образа
echo ""
echo "--- Загрузка нового образа ---"
loaded=$(docker load < "$ARCHIVE" 2>/dev/null | grep "Loaded image" | head -1)
source_image=$(echo "$loaded" | sed 's/Loaded image: //' | sed 's/Loaded image ID: //')
echo "  [OK] Загружен: $source_image"

# Push в Harbor
echo ""
echo "--- Push в Harbor ---"
echo "$HARBOR_PASS" | docker login "$HARBOR_HOST" -u "$HARBOR_USER" --password-stdin 2>/dev/null
docker tag "$source_image" "$TARGET_IMAGE" 2>/dev/null
docker push "$TARGET_IMAGE" 2>/dev/null
echo "  [OK] $TARGET_IMAGE"

# Получение нового digest
new_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$TARGET_IMAGE" 2>/dev/null | cut -d@ -f2 | head -c 20 || echo "")
echo "  Новый digest: $new_digest..."

# Очистка
docker rmi "$source_image" "$TARGET_IMAGE" 2>/dev/null || true

# Уведомление (webhook)
if [ -n "$NOTIFY_WEBHOOK" ] && [ "$old_digest" != "$new_digest" ]; then
  curl -s -X POST "$NOTIFY_WEBHOOK" \
    -H "Content-Type: application/json" \
    -d "{\"image\":\"$TARGET_IMAGE\",\"old_digest\":\"$old_digest\",\"new_digest\":\"$new_digest\"}" \
    &>/dev/null || true
  echo "  [OK] Уведомление отправлено"
fi

echo ""
echo "=== Обновление завершено: $TARGET_IMAGE ==="
[ "$old_digest" != "$new_digest" ] && echo "  Образ изменился — требуется пересборка зависимых образов"
