#!/usr/bin/env bash
# Проверка состояния всех компонентов Harbor через API
# Использование: bash harbor-health-check.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка состояния Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 10 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

# --- Базовая доступность ---
echo ""
echo "--- Доступность ---"
if curl -skf --max-time 10 "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
  ok "Harbor API отвечает на /api/v2.0/ping"
else
  fail "Harbor API недоступен: $HARBOR_URL/api/v2.0/ping"
  echo "=== ИТОГ: FAIL — Harbor недоступен ==="
  exit 1
fi

# --- Версия ---
info=$(api "systeminfo" || echo "{}")
version=$(echo "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('harbor_version','неизвестна'))" 2>/dev/null || echo "неизвестна")
ok "Версия Harbor: $version"

# --- Компоненты через /health ---
echo ""
echo "--- Компоненты ---"
health=$(curl -skf --max-time 10 "$HARBOR_URL/api/v2.0/health" 2>/dev/null || echo "{}")
echo "$health" | python3 -c "
import json, sys
data = json.load(sys.stdin)
components = data.get('components', [])
for c in components:
    name = c.get('name', '?')
    status = c.get('status', '?')
    if status.lower() == 'healthy':
        print(f'[PASS] {name}: {status}')
    else:
        print(f'[FAIL] {name}: {status}')
" 2>/dev/null || warn "Не удалось получить статус компонентов"

# --- Хранилище ---
echo ""
echo "--- Хранилище ---"
storage_total=$(echo "$info" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_total',0)//1073741824)" 2>/dev/null || echo 0)
storage_free=$(echo "$info"  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('storage_free',0)//1073741824)"  2>/dev/null || echo 0)
if [ "$storage_total" -gt 0 ] 2>/dev/null; then
  used_pct=$(( (storage_total - storage_free) * 100 / storage_total ))
  if [ "$used_pct" -gt 90 ]; then
    fail "Хранилище заполнено на ${used_pct}% (${storage_free} ГБ свободно из ${storage_total} ГБ)"
  elif [ "$used_pct" -gt 80 ]; then
    warn "Хранилище заполнено на ${used_pct}% — требует внимания"
  else
    ok "Хранилище: ${used_pct}% использовано, ${storage_free} ГБ свободно"
  fi
else
  warn "Данные о хранилище недоступны"
fi

# --- Аутентификация ---
echo ""
echo "--- Аутентификация ---"
if api "users/current" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('username',''))" 2>/dev/null | grep -q .; then
  ok "Аутентификация успешна (пользователь: $HARBOR_USER)"
else
  fail "Аутентификация не прошла — проверьте учётные данные"
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
