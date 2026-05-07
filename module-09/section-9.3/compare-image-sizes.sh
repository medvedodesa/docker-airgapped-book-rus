#!/usr/bin/env bash
# Сравнение размеров образов до и после перехода на многоэтапную сборку
# Показывает разбивку по слоям и выигрыш в размере
# Использование: bash compare-image-sizes.sh [образ_до] [образ_после]
set -euo pipefail

IMAGE_BEFORE="${1:-}"
IMAGE_AFTER="${2:-}"
HARBOR_URL="${HARBOR_URL:-harbor.internal.company.local}"

echo "=== Сравнение размеров образов ==="
echo "Дата: $(date '+%Y-%m-%d %H:%M')"

# ── Вспомогательная функция анализа образа ────────────────────────────────
analyze_image() {
  local img="$1"
  local label="${2:-$img}"

  echo ""
  echo "── $label ──────────────────────────────────────────────────────────"

  if ! docker image inspect "$img" &>/dev/null 2>&1; then
    echo "  [SKIP] Образ не найден локально: $img"
    return
  fi

  # Общий размер
  size_bytes=$(docker image inspect "$img" --format '{{.Size}}' 2>/dev/null || echo 0)
  size_mb=$(( size_bytes / 1048576 ))
  size_human=$(docker images --format '{{.Size}}' "$img" 2>/dev/null | head -1)

  echo "  Общий размер: $size_human ($size_bytes байт)"

  # Слои
  echo ""
  echo "  Слои (от верхнего к нижнему):"
  docker history --no-trunc --format 'table {{.Size}}\t{{.CreatedBy}}' "$img" 2>/dev/null | \
    head -20 | awk 'NR>1 {
      size=$1; rest=$0
      sub(/^[^\t]+\t/, "", rest)
      cmd=rest
      gsub(/\/bin\/sh -c #\(nop\) /, "", cmd)
      if (length(cmd) > 70) cmd = substr(cmd, 1, 67) "..."
      printf "  %8s  %s\n", size, cmd
    }'

  # Базовый образ
  base=$(docker history --format '{{.CreatedBy}}' "$img" 2>/dev/null | \
    grep "FROM\|scratch" | tail -1 | sed 's/.*FROM //' | awk '{print $1}')
  echo ""
  echo "  Базовый образ: ${base:-(определить не удалось)}"

  # Компилятор в образе?
  has_compiler=false
  for tool in javac mvn gradle go gcc g++ cc; do
    if docker run --rm --entrypoint="" "$img" which "$tool" &>/dev/null 2>&1; then
      echo "  [WARN] Найден инструмент сборки: $tool"
      has_compiler=true
    fi
  done
  $has_compiler || echo "  [OK] Инструменты сборки отсутствуют"

  # Shell в образе?
  if docker run --rm --entrypoint="" "$img" sh -c "echo ok" &>/dev/null 2>&1; then
    echo "  [INFO] Шелл присутствует (/bin/sh)"
  elif docker run --rm --entrypoint="" "$img" bash -c "echo ok" &>/dev/null 2>&1; then
    echo "  [INFO] Шелл присутствует (/bin/bash)"
  else
    echo "  [OK] Шелл отсутствует (distroless/scratch)"
  fi

  echo "$size_bytes"
}

# ── Сканирование всех образов проекта ─────────────────────────────────────
if [ -z "$IMAGE_BEFORE" ] && [ -z "$IMAGE_AFTER" ]; then
  echo ""
  echo "Аргументы не переданы — анализ всех локальных образов с Harbor"
  echo ""

  docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}' 2>/dev/null | \
    grep "$HARBOR_URL" | \
    awk '{printf "%-70s %10s  %s\n", $1, $2, $3}' | \
    sort -k2 -h -r | head -30

  echo ""
  echo "Образов в Harbor (локально): $(docker images --format '{{.Repository}}' 2>/dev/null | grep -c "$HARBOR_URL" || echo 0)"
  exit 0
fi

# ── Сравнение двух образов ────────────────────────────────────────────────
size_before=$(analyze_image "$IMAGE_BEFORE" "ДО (однослойный)")
size_after=$(analyze_image  "$IMAGE_AFTER"  "ПОСЛЕ (многоэтапный)")

# ── Итог ─────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════════════"
echo "=== СРАВНЕНИЕ ==="
if [ -n "$size_before" ] && [ -n "$size_after" ] && \
   [ "$size_before" -gt 0 ] && [ "$size_after" -gt 0 ] 2>/dev/null; then
  before_mb=$(( size_before / 1048576 ))
  after_mb=$(( size_after  / 1048576 ))
  saved_mb=$(( before_mb - after_mb ))
  pct=$(( (before_mb - after_mb) * 100 / before_mb ))

  echo "  До:       ${before_mb} МБ  ($IMAGE_BEFORE)"
  echo "  После:    ${after_mb} МБ  ($IMAGE_AFTER)"
  echo "  Экономия: ${saved_mb} МБ (${pct}%)"
  echo ""

  if [ "$pct" -ge 60 ]; then
    echo "  Отличный результат — многоэтапная сборка даёт >60% выигрыша"
  elif [ "$pct" -ge 30 ]; then
    echo "  Хороший результат — попробуйте distroless-образ вместо slim"
  elif [ "$pct" -gt 0 ]; then
    echo "  Есть выигрыш — проверьте что компилятор не попал в финальный образ"
  else
    echo "  Выигрыша нет — убедитесь что используется многоэтапная сборка"
  fi
fi

echo ""
echo "Для дальнейшего уменьшения размера:"
echo "  1. Используйте distroless или scratch как базовый образ (раздел 9.4)"
echo "  2. Добавьте .dockerignore для исключения лишних файлов из контекста"
echo "  3. Объединяйте команды RUN в один слой (apt-get install && rm -rf /var/lib/apt/lists/*)"
