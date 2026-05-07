#!/usr/bin/env bash
# Импорт Docker-образов из архивов с проверкой SHA-256
# Использование: bash import-images.sh [директория_с_архивами] [--push-to-harbor harbor.internal]
set -euo pipefail

IMG_DIR="${1:-./}"
HARBOR=""
HARBOR_PROJECT="base"

# Парсинг аргументов
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --push-to-harbor) HARBOR="$2"; shift 2 ;;
    --project) HARBOR_PROJECT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "=== Импорт Docker-образов ==="
echo "  Директория: $IMG_DIR"
[ -n "$HARBOR" ] && echo "  Загрузка в Harbor: $HARBOR (проект: $HARBOR_PROJECT)"

# Проверка контрольных сумм
echo ""
echo "--- Проверка целостности ---"
sha_file=$(ls "$IMG_DIR"/SHA256SUMS* 2>/dev/null | head -1 || true)
if [ -n "$sha_file" ]; then
  cd "$IMG_DIR"
  if sha256sum -c "$(basename "$sha_file")" 2>&1 | grep -v OK; then
    echo "[FAIL] Обнаружены повреждённые файлы!"
    exit 1
  fi
  echo "[PASS] Все файлы проверены"
  cd - >/dev/null
else
  echo "[WARN] SHA256SUMS не найден, пропускаем проверку"
fi

# Импорт архивов
echo ""
echo "--- Загрузка образов ---"
loaded=0
failed=0

for archive in "$IMG_DIR"/*.tar.gz "$IMG_DIR"/*.tar; do
  [ -f "$archive" ] || continue
  echo "  <- $(basename "$archive")"
  if loaded_images=$(docker load -i "$archive" 2>/dev/null); then
    echo "$loaded_images" | while read line; do echo "     $line"; done
    ((loaded++)) || true

    # Загружаем в Harbor если указан
    if [ -n "$HARBOR" ]; then
      while IFS= read -r loaded_line; do
        img=$(echo "$loaded_line" | grep "Loaded image:" | awk '{print $3}')
        [ -z "$img" ] && continue
        img_name=$(echo "$img" | cut -d/ -f2- 2>/dev/null || echo "$img" | cut -d: -f1 | tr '/' '_')
        tag=$(echo "$img" | cut -d: -f2)
        harbor_tag="$HARBOR/$HARBOR_PROJECT/$img_name:$tag"
        docker tag "$img" "$harbor_tag" 2>/dev/null && \
          docker push "$harbor_tag" 2>/dev/null && \
          echo "     -> $harbor_tag" || \
          echo "     [WARN] Не удалось загрузить в Harbor: $harbor_tag"
      done <<< "$loaded_images"
    fi
  else
    echo "  [FAIL] Не удалось загрузить $(basename "$archive")"
    ((failed++)) || true
  fi
done

echo ""
echo "=== Итог: загружено=$loaded ошибок=$failed ==="
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}'
[ "$failed" -eq 0 ] || exit 1
