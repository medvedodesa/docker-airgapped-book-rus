#!/usr/bin/env bash
# Еженедельное обслуживание Harbor: неиспользуемые образы, статус сканирования, GC
# Использование: bash harbor-maintenance.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-https://harbor.internal.company.local}}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
UNUSED_DAYS="${UNUSED_IMAGE_DAYS:-90}"
OUTPUT="${HARBOR_MAINT_REPORT:-harbor-maintenance-$(date +%Y%m%d).txt}"

if [ -z "$HARBOR_PASS" ]; then
  echo "Укажите пароль: HARBOR_PASSWORD=<pass> bash $0"
  exit 1
fi

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 20 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }
api_post() {
  curl -sf --max-time 30 -X POST \
    -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
    "$HARBOR_URL/api/v2.0/$1" ${2:+-d "$2"} 2>/dev/null
}

PASS=0; WARN=0; FAIL=0
ok()   { echo "[OK]   $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Еженедельное обслуживание Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Отчёт обслуживания Harbor"
  echo "# Реестр: $HARBOR_URL  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # ── 1. Состояние компонентов ─────────────────────────────────────────
  echo "## 1. Состояние компонентов"
  health=$(curl -sf --max-time 10 "$HARBOR_URL/api/v2.0/health" 2>/dev/null || echo "{}")
  echo "$health" | python3 -c "
import json,sys
d = json.load(sys.stdin)
for c in d.get('components',[]):
    status = c.get('status','?')
    marker = '[OK]  ' if status.lower()=='healthy' else '[FAIL]'
    print(f'  {marker} {c.get(\"name\",\"?\")}: {status}')
" 2>/dev/null || warn "Не удалось получить статус компонентов"
  echo ""

  # ── 2. Использование хранилища ───────────────────────────────────────
  echo "## 2. Хранилище"
  info=$(api "systeminfo" || echo "{}")
  total=$(echo "$info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('storage_total',0)//1073741824)" 2>/dev/null || echo 0)
  free=$(echo "$info"  | python3 -c "import json,sys; print(json.load(sys.stdin).get('storage_free',0)//1073741824)"  2>/dev/null || echo 0)
  used=$((total - free))
  pct=$([ "$total" -gt 0 ] && echo $((used * 100 / total)) || echo 0)
  echo "  Использовано: ${used} ГБ из ${total} ГБ (${pct}%)"
  [ "$pct" -gt 85 ] && warn "Хранилище >85% — запустите GC и проверьте политики хранения" || ok "Хранилище в норме (${pct}%)"
  echo ""

  # ── 3. Неиспользуемые образы ─────────────────────────────────────────
  echo "## 3. Неиспользуемые образы (не скачивались >${UNUSED_DAYS} дней)"
  projects=$(api "projects?page_size=100" 2>/dev/null | python3 -c "
import json,sys; [print(p['project_id'],p['name']) for p in json.load(sys.stdin)]
" 2>/dev/null || echo "")

  unused_count=0
  unused_size=0
  now_epoch=$(date +%s)
  cutoff_epoch=$((now_epoch - UNUSED_DAYS * 86400))

  while IFS=' ' read -r pid pname; do
    repos=$(api "projects/$pid/repositories?page_size=500" 2>/dev/null || echo "[]")
    echo "$repos" | python3 -c "
import json,sys
from datetime import datetime
repos = json.load(sys.stdin)
cutoff = $cutoff_epoch
for r in repos:
    pull_count = r.get('pull_count', 0)
    name = r.get('name','?')
    update_time = r.get('update_time','')
    try:
        epoch = int(datetime.fromisoformat(update_time.replace('Z','+00:00')).timestamp())
    except Exception:
        epoch = 0
    if pull_count == 0 and epoch < cutoff:
        size_mb = r.get('size', 0) // (1024*1024)
        print(f'  [WARN] $pname/{name} — 0 pulls, обновлялся: {update_time[:10]}, {size_mb} МБ')
" 2>/dev/null
  done <<< "$projects"
  echo ""

  # ── 4. Статус сканирования ────────────────────────────────────────────
  echo "## 4. Статус сканирования уязвимостей"
  scanner=$(api "scanners" 2>/dev/null | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s.get('is_default'):
        print(s.get('name','?'), '-', s.get('version','?'), 'updated:', s.get('properties',{}).get('harbor.scanner-adapter/database.updated.at','?')[:10])
" 2>/dev/null || echo "  Сканер не настроен")
  echo "  Сканер: $scanner"

  # Образы без результатов сканирования
  not_scanned=0
  while IFS=' ' read -r pid pname; do
    count=$(api "projects/$pid/repositories?page_size=500" 2>/dev/null | python3 -c "
import json,sys
repos = json.load(sys.stdin)
print(sum(1 for r in repos if r.get('artifact_count',0) > 0 and 'scan_overview' not in r.get('update_time','')))
" 2>/dev/null || echo 0)
    not_scanned=$((not_scanned + count))
  done <<< "$projects"
  [ "$not_scanned" -gt 0 ] && \
    warn "Образов без актуального сканирования: $not_scanned" || \
    ok "Все образы просканированы"
  echo ""

  # ── 5. Garbage Collection ─────────────────────────────────────────────
  echo "## 5. Garbage Collection"
  gc_last=$(api "system/gc/latest" 2>/dev/null || echo "{}")
  gc_status=$(echo "$gc_last" | python3 -c "import json,sys; print(json.load(sys.stdin).get('job_status','неизвестен'))" 2>/dev/null)
  echo "  Последний GC: $gc_status"

  echo "  Запуск планового GC..."
  gc_result=$(api_post "system/gc/schedule" '{"schedule":{"type":"Manual"}}' 2>/dev/null || echo "")
  if [ -n "$gc_result" ]; then
    ok "GC запущен"
  else
    warn "GC не запустился — запустите вручную через Harbor UI"
  fi
  echo ""

  # ── Итог ─────────────────────────────────────────────────────────────
  echo "## Итог"
  echo "  OK: $PASS  WARN: $WARN  FAIL: $FAIL"
  echo "  Следующее обслуживание: $(date -d "+7 days" '+%Y-%m-%d' 2>/dev/null || date -v+7d '+%Y-%m-%d')"

} | tee "$OUTPUT"

echo ""
echo "Отчёт: $OUTPUT"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
