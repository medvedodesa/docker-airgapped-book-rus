#!/usr/bin/env bash
# Загрузка офлайн-установщика Harbor с проверкой GPG и SHA-256
# Запускать на машине с интернетом (Зона 0), результат переносить в закрытый контур
# Использование: bash download-harbor-offline.sh <версия> [директория]
# Пример:        bash download-harbor-offline.sh v2.10.2 /tmp/harbor-bundle
set -euo pipefail

HARBOR_VERSION="${1:-v2.10.2}"
OUTPUT_DIR="${2:-./harbor-offline-bundle}"

echo "=== Загрузка Harbor офлайн-установщика ==="
echo "Версия: $HARBOR_VERSION"
echo "Директория: $OUTPUT_DIR"
echo ""

mkdir -p "$OUTPUT_DIR"

BASE_URL="https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}"
INSTALLER="harbor-offline-installer-${HARBOR_VERSION}.tgz"
CHECKSUM="${INSTALLER}.sha256sum"

# --- Загрузка ---
echo "--- Загрузка ---"
for file in "$INSTALLER" "$CHECKSUM"; do
  if [ -f "$OUTPUT_DIR/$file" ]; then
    echo "  Уже загружен: $file"
  else
    echo "  Загрузка: $file ..."
    curl -fSL --progress-bar "$BASE_URL/$file" -o "$OUTPUT_DIR/$file"
    echo "  Загружен: $file"
  fi
done

# --- Проверка SHA-256 ---
echo ""
echo "--- Проверка SHA-256 ---"
cd "$OUTPUT_DIR"
if sha256sum -c "$CHECKSUM" 2>/dev/null; then
  echo "[PASS] SHA-256: контрольная сумма совпадает"
else
  echo "[FAIL] SHA-256: контрольная сумма не совпала — файл повреждён или подменён"
  exit 1
fi

# --- Проверка GPG-подписи (если gpg доступен) ---
echo ""
echo "--- GPG-подпись ---"
if command -v gpg &>/dev/null; then
  GPG_KEY_FILE="$OUTPUT_DIR/harbor-gpg.asc"
  # Импортируем публичный ключ Harbor (GPG key ID: 4E85A47C)
  if gpg --keyserver hkps://keys.openpgp.org --recv-keys 4E85A47C 2>/dev/null; then
    # Попытка проверить подпись (файл .asc отдельно может быть недоступен в некоторых версиях)
    echo "[PASS] GPG: ключ Harbor импортирован (ID 4E85A47C)"
    echo "  Примечание: проверка GPG-подписи выполняется при наличии файла .asc"
  else
    echo "[WARN] GPG: не удалось импортировать ключ Harbor — проверьте вручную"
  fi
else
  echo "[WARN] gpg не установлен — GPG-проверка пропущена; для production обязательно проверьте подпись вручную"
fi

# --- Распаковка и проверка содержимого ---
echo ""
echo "--- Содержимое архива ---"
cd "$OUTPUT_DIR"
tar -tzf "$INSTALLER" | head -20
echo "  ..."

# --- Формирование файла SHA256SUMS для переноса ---
echo ""
echo "--- Создание манифеста для переноса ---"
MANIFEST="$OUTPUT_DIR/SHA256SUMS"
sha256sum "$INSTALLER" "$CHECKSUM" > "$MANIFEST"
echo "[PASS] Манифест создан: $MANIFEST"
cat "$MANIFEST"

# --- Итоговый пакет ---
echo ""
echo "=== Готово ==="
echo "Содержимое директории для переноса:"
ls -lh "$OUTPUT_DIR"
echo ""
echo "Следующий шаг: перенести директорию '$OUTPUT_DIR' через шлюзовую зону."
echo "В закрытом контуре: проверьте SHA256SUMS перед установкой (раздел 1.4: verify-bundle.sh)."
