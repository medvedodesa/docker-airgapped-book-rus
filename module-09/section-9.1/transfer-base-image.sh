#!/usr/bin/env bash
# Перенос базового образа с внешнего носителя в Harbor
# Использование: bash transfer-base-image.sh <archive.tar> <harbor_host> <project/repo:tag>
set -euo pipefail

ARCHIVE="${1:-}"
HARBOR_HOST="${2:-harbor.internal.company.local}"
TARGET_REF="${3:-}"       # project/repo:tag в Harbor
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"

[ -n "$ARCHIVE" ] && [ -n "$TARGET_REF" ] || {
  echo "Использование: $0 <archive.tar> <harbor_host> <project/repo:tag>"
  exit 1
}
[ -f "$ARCHIVE" ] || { echo "[FAIL] Архив не найден: $ARCHIVE"; exit 1; }
[ -n "$HARBOR_PASS" ] || { echo "[FAIL] HARBOR_PASS не установлен"; exit 1; }

TARGET_IMAGE="${HARBOR_HOST}/${TARGET_REF}"

echo "=== Перенос образа в Harbor ==="
echo "  Архив:  $ARCHIVE"
echo "  Цель:   $TARGET_IMAGE"

# Проверка контрольной суммы
SHA_FILE="${ARCHIVE}.sha256"
echo ""
echo "--- Проверка целостности ---"
if [ -f "$SHA_FILE" ]; then
  if sha256sum -c "$SHA_FILE" &>/dev/null; then
    echo "  [OK] Контрольная сумма верна"
  else
    echo "  [FAIL] Контрольная сумма не совпадает — архив повреждён"
    exit 1
  fi
else
  echo "  [WARN] Файл .sha256 не найден — пропуск проверки"
fi

# Загрузка образа
echo ""
echo "--- Загрузка образа ---"
loaded=$(docker load < "$ARCHIVE" 2>/dev/null | grep "Loaded image" | head -1)
[ -n "$loaded" ] || { echo "  [FAIL] Не удалось загрузить образ"; exit 1; }
echo "  [OK] $loaded"

# Извлечение имени загруженного образа
source_image=$(echo "$loaded" | sed 's/Loaded image: //' | sed 's/Loaded image ID: //')

# Тег для Harbor
docker tag "$source_image" "$TARGET_IMAGE" 2>/dev/null
echo "  [OK] Тег: $TARGET_IMAGE"

# Пуш в Harbor
echo ""
echo "--- Push в Harbor ---"
echo "$HARBOR_PASS" | docker login "$HARBOR_HOST" \
  -u "$HARBOR_USER" --password-stdin 2>/dev/null

docker push "$TARGET_IMAGE" 2>/dev/null && \
  echo "  [OK] Образ загружен в Harbor" || {
  echo "  [FAIL] Ошибка push"
  exit 1
}

# Очистка локального образа
docker rmi "$source_image" "$TARGET_IMAGE" 2>/dev/null || true
echo "  [OK] Локальные копии удалены"

echo ""
echo "=== Перенос завершён: $TARGET_IMAGE ==="
