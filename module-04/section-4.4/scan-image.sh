#!/usr/bin/env bash
# Сканирование образа Trivy с завершением конвейера при критических CVE
# Использование: bash scan-image.sh <образ> [--severity CRITICAL,HIGH] [--exit-code 1]
set -euo pipefail

IMAGE="${1:-}"
SEVERITY="${2:-CRITICAL,HIGH}"
EXIT_ON_VULN="${3:-1}"      # 0 — только отчёт, 1 — завершить с ошибкой при CVE
DB_DIR="${TRIVY_DB_DIR:-/var/lib/trivy}"
IGNOREFILE="${TRIVY_IGNOREFILE:-.trivyignore}"
OUTPUT_FORMAT="${TRIVY_FORMAT:-table}"

[ -n "$IMAGE" ] || { echo "Использование: $0 <образ>"; exit 1; }

echo "=== Сканирование Trivy: $IMAGE ==="
echo "  Серьёзность: $SEVERITY | Выход при CVE: $EXIT_ON_VULN"

# Проверка актуальности базы
echo ""
if [ -d "$DB_DIR" ]; then
  db_age=$(find "$DB_DIR" -name "metadata.json" -mtime +7 2>/dev/null | wc -l)
  [ "$db_age" -gt 0 ] && echo "[WARN] База уязвимостей старше 7 дней!"
  db_date=$(stat -c %y "$DB_DIR/metadata.json" 2>/dev/null | cut -d' ' -f1 || echo "неизвестно")
  echo "  База уязвимостей: $db_date"
fi

# Запуск сканирования
echo ""
echo "--- Результаты сканирования ---"

trivy_args=(
  "image"
  "--severity" "$SEVERITY"
  "--exit-code" "$EXIT_ON_VULN"
  "--format" "$OUTPUT_FORMAT"
  "--quiet"
)

[ -d "$DB_DIR" ] && trivy_args+=("--db-repository" "file://$DB_DIR")
[ -f "$IGNOREFILE" ] && trivy_args+=("--ignorefile" "$IGNOREFILE")

if trivy "${trivy_args[@]}" "$IMAGE" 2>/dev/null; then
  echo ""
  echo "[PASS] Уязвимостей уровня $SEVERITY не обнаружено"
  exit 0
else
  exit_code=$?
  echo ""
  echo "[FAIL] Обнаружены уязвимости уровня $SEVERITY"
  echo "  Добавьте в .trivyignore принятые риски с обоснованием"
  exit $exit_code
fi
