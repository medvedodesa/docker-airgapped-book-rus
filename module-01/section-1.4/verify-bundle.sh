#!/usr/bin/env bash
# Проверка целостности передаточного пакета по контрольным суммам SHA-256
# Использование: bash verify-bundle.sh [директория_пакета]
set -euo pipefail

BUNDLE_DIR="${1:-.}"

echo "=== Проверка целостности пакета ==="
echo "Директория: $BUNDLE_DIR"
echo ""

if [ ! -f "$BUNDLE_DIR/SHA256SUMS" ]; then
  echo "[FAIL] Файл SHA256SUMS не найден в $BUNDLE_DIR"
  exit 1
fi

total=$(wc -l < "$BUNDLE_DIR/SHA256SUMS")
echo "Файлов в манифесте: $total"
echo ""

cd "$BUNDLE_DIR"
if sha256sum -c SHA256SUMS 2>&1 | tee /tmp/sha256_result.txt; then
  failed=$(grep -c FAILED /tmp/sha256_result.txt || true)
  echo ""
  if [ "${failed:-0}" -eq 0 ]; then
    echo "[OK] Все $total файлов проверены — пакет целостен"
  else
    echo "[FAIL] Обнаружено повреждённых файлов: $failed"
    echo "Повреждённые файлы:"
    grep FAILED /tmp/sha256_result.txt
    exit 1
  fi
else
  echo "[FAIL] Проверка не прошла"
  exit 1
fi
