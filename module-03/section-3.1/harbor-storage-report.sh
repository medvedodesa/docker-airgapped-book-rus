#!/usr/bin/env bash
# Отчёт об использовании хранилища Harbor по проектам
# Использование: bash harbor-storage-report.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
OUTPUT="${HARBOR_STORAGE_REPORT:-harbor-storage-$(date +%Y%m%d).txt}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 15 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

echo "=== Отчёт об использовании хранилища Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Отчёт об использовании хранилища Harbor"
  echo "# Реестр: $HARBOR_URL"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # Общая информация о системе
  info=$(api "systeminfo" || echo "{}")
  storage_total=$(echo "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_total',0))" 2>/dev/null || echo 0)
  storage_free=$(echo "$info"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_free',0))"  2>/dev/null || echo 0)
  storage_used=$((storage_total - storage_free))

  total_gb=$(( storage_total / 1073741824 ))
  used_gb=$(( storage_used / 1073741824 ))
  free_gb=$(( storage_free / 1073741824 ))
  [ "$storage_total" -gt 0 ] && used_pct=$(( storage_used * 100 / storage_total )) || used_pct=0

  echo "## Общее использование хранилища"
  printf "   %-20s %6s ГБ\n" "Всего:"    "$total_gb"
  printf "   %-20s %6s ГБ\n" "Использовано:" "$used_gb"
  printf "   %-20s %6s ГБ\n" "Свободно:"  "$free_gb"
  printf "   %-20s %6s%%\n"  "Заполнено:" "$used_pct"
  echo ""

  # По проектам
  echo "## Использование по проектам"
  printf "   %-40s %10s %10s %8s\n" "Проект" "Репоз." "Артефактов" "Размер МБ"
  printf "   %-40s %10s %10s %8s\n" "-------" "------" "----------" "---------"

  projects=$(api "projects?page_size=100" 2>/dev/null || echo "[]")
  echo "$projects" | python3 -c "
import json, sys
projects = json.load(sys.stdin)
for p in sorted(projects, key=lambda x: x.get('name','')):
    name = p.get('name','')
    repo_count = p.get('repo_count', 0)
    size_bytes = 0
    for stat in p.get('metadata', {}).values():
        pass
    size_mb = p.get('size', 0) // (1024*1024) if 'size' in p else 0
    # artifact_count approximated from repo_count
    print(f'   {name:<40} {repo_count:>10} {\"\":>10} {size_mb:>8}')
" 2>/dev/null || echo "   (данные недоступны)"
  echo ""

  # GC информация
  gc_info=$(api "system/gc/latest" 2>/dev/null || echo "{}")
  gc_status=$(echo "$gc_info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('job_status','неизвестен'))" 2>/dev/null || echo "неизвестен")
  gc_freed=$(echo "$gc_info" | python3 -c "import json,sys; d=json.get('freed_space', d.get('freed',0)) if (d:=json.load(sys.stdin)) else 0; print(d//1048576)" 2>/dev/null || echo 0)

  echo "## Последний Garbage Collection"
  echo "   Статус:         $gc_status"
  echo "   Освобождено:    ${gc_freed} МБ"
  echo ""

  # Рекомендации
  echo "## Рекомендации"
  if [ "$used_pct" -gt 90 ]; then
    echo "   КРИТИЧНО: Хранилище заполнено на ${used_pct}%. Требуется немедленный GC или расширение."
  elif [ "$used_pct" -gt 80 ]; then
    echo "   ПРЕДУПРЕЖДЕНИЕ: Хранилище заполнено на ${used_pct}%. Запустите harbor-gc.sh."
  else
    echo "   Использование хранилища в норме (${used_pct}%)."
  fi

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
