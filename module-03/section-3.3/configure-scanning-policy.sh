#!/usr/bin/env bash
# Настройка политик сканирования и блокировки уязвимых образов в Harbor
# Использование: bash configure-scanning-policy.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
BLOCK_SEVERITY="${BLOCK_SEVERITY:-high}"   # critical, high, medium
AUTO_SCAN="${AUTO_SCAN:-true}"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() {
  local method="${1:-GET}" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sf --max-time 15 -X "$method" \
      -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
      "$HARBOR_URL/api/v2.0/$path" -d "$data"
  else
    curl -sf --max-time 15 -X "$method" \
      -H "Authorization: Basic $AUTH" \
      "$HARBOR_URL/api/v2.0/$path"
  fi
}

sev_to_int() {
  case "$1" in
    critical) echo 5 ;;
    high)     echo 4 ;;
    medium)   echo 3 ;;
    low)      echo 2 ;;
    *)        echo 4 ;;
  esac
}

echo "=== Настройка политик сканирования Harbor ==="
echo "Реестр:            $HARBOR_URL"
echo "Блокировать с:     $BLOCK_SEVERITY"
echo "Автосканирование:  $AUTO_SCAN"
echo "Дата:              $(date '+%Y-%m-%d %H:%M')"

# --- Системная политика сканирования ---
echo ""
echo "--- Системная политика (автосканирование при push) ---"
sys_config=$(python3 -c "import json; print(json.dumps({'scan_all_policy': {'type': 'daily', 'parameter': {'daily_time': 0}}}))")
if api PUT "system/scanAll/schedule" "$sys_config" >/dev/null 2>&1; then
  echo "[OK] Ежедневное автосканирование настроено (00:00)"
else
  echo "[WARN] Не удалось настроить расписание сканирования — возможно уже настроено"
fi

# --- Политика по каждому проекту ---
echo ""
echo "--- Политика блокировки по проектам ---"
projects=$(api GET "projects?page_size=100" 2>/dev/null || echo "[]")
project_count=$(echo "$projects" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
echo "Проектов для настройки: $project_count"

echo "$projects" | python3 -c "import json,sys; [print(p['project_id'],p['name']) for p in json.load(sys.stdin)]" 2>/dev/null | \
while read -r proj_id proj_name; do
  # Настройка автосканирования при push
  meta_payload=$(python3 -c "import json; print(json.dumps({'metadata': {'auto_scan': '$AUTO_SCAN', 'prevent_vul': 'true', 'severity': '$BLOCK_SEVERITY'}}))")
  if api PUT "projects/$proj_id" "$meta_payload" >/dev/null 2>&1; then
    echo "[OK] Проект $proj_name: автосканирование=$AUTO_SCAN, блокировка>=$BLOCK_SEVERITY"
  else
    echo "[WARN] Проект $proj_name: не удалось обновить метаданные"
  fi
done

# --- Проверка сканера по умолчанию ---
echo ""
echo "--- Сканер по умолчанию ---"
scanners=$(api GET "scanners" 2>/dev/null || echo "[]")
default_scanner=$(echo "$scanners" | python3 -c "
import json,sys
for s in json.load(sys.stdin):
    if s.get('is_default'):
        print(s.get('name','?'), '-', s.get('vendor','?'), s.get('version','?'))
" 2>/dev/null || echo "")
if [ -n "$default_scanner" ]; then
  echo "[OK] Сканер по умолчанию: $default_scanner"
else
  echo "[WARN] Сканер по умолчанию не настроен — добавьте Trivy через Harbor UI"
fi

# --- Итог ---
echo ""
echo "=== Настройка политик завершена ==="
echo ""
echo "Применённые настройки:"
echo "  Автосканирование при push: $AUTO_SCAN"
echo "  Блокировка образов с уязвимостями >= $BLOCK_SEVERITY"
echo "  Ежедневное повторное сканирование: 00:00"
echo ""
echo "Проверьте результат через Harbor UI → Системные настройки → Уязвимости"
