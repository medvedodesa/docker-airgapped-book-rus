#!/usr/bin/env bash
# Сборка мусора в Harbor: удаление неиспользуемых слоёв и тегов
# Использование: bash harbor-gc.sh [harbor_host]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
DRY_RUN="${DRY_RUN:-0}"

echo "=== Harbor Garbage Collection ==="
echo "  Harbor:  $HARBOR_HOST"
echo "  Dry run: $DRY_RUN"

[ -n "$HARBOR_PASS" ] || { echo "[FAIL] HARBOR_PASS не установлен"; exit 1; }

API="https://$HARBOR_HOST/api/v2.0"

# Запрос места до GC
echo ""
echo "--- Объём данных до GC ---"
storage_before=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
  "$API/systeminfo" 2>/dev/null | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d.get('storage', {})
total = s.get('total', 0)
free = s.get('free', 0)
used = total - free
print(f'Использовано: {used//1024//1024//1024} ГБ из {total//1024//1024//1024} ГБ')
" 2>/dev/null || echo "  Данные недоступны")
echo "  $storage_before"

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "  [DRY RUN] GC не запущен"
  exit 0
fi

# Запуск GC через API
echo ""
echo "--- Запуск GC ---"
gc_response=$(curl -s -X POST \
  -u "$HARBOR_USER:$HARBOR_PASS" \
  -H "Content-Type: application/json" \
  -d '{"schedule":{"type":"Manual"}}' \
  "$API/system/gc/schedule" \
  -w "\n%{http_code}" \
  2>/dev/null)

http_code=$(echo "$gc_response" | tail -1)

if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
  echo "  [OK] GC запущен"
else
  echo "  [FAIL] GC не запущен (HTTP $http_code)"
  exit 1
fi

# Ожидание завершения
echo ""
echo "--- Ожидание завершения ---"
for i in $(seq 1 30); do
  gc_status=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
    "$API/system/gc/latest" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('job_status',''))" \
    2>/dev/null || echo "")

  case "$gc_status" in
    Success) echo "  [OK] GC завершён успешно"; break ;;
    Error)   echo "  [FAIL] GC завершился с ошибкой"; exit 1 ;;
    *)       echo "  Статус: ${gc_status:-running} ($i/30)..."; sleep 10 ;;
  esac
done

# Объём после GC
echo ""
echo "--- Объём данных после GC ---"
storage_after=$(curl -s -u "$HARBOR_USER:$HARBOR_PASS" \
  "$API/systeminfo" 2>/dev/null | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
s = d.get('storage', {})
total = s.get('total', 0)
free = s.get('free', 0)
used = total - free
print(f'Использовано: {used//1024//1024//1024} ГБ из {total//1024//1024//1024} ГБ')
" 2>/dev/null || echo "  Данные недоступны")
echo "  $storage_after"

echo ""
echo "=== Harbor GC завершён ==="
