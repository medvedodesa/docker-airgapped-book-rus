#!/usr/bin/env bash
# Принудительный отзыв аренды Vault с проверкой удаления пользователя из целевой системы
# Использование: bash revoke-lease.sh [lease_id] [vault_addr] [vault_token]
set -euo pipefail

LEASE_ID="${1:-${VAULT_LEASE_ID:-}}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${3:-${VAULT_TOKEN:-}}"
VERIFY_DB="${VERIFY_DB:-}"          # host:port для проверки psql
VERIFY_DB_ADMIN="${VERIFY_DB_ADMIN:-}" # admin user для проверки

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

if [ -z "$LEASE_ID" ] || [ -z "$VAULT_TOKEN" ]; then
  echo "Использование: bash $0 <lease_id> [vault_addr] [vault_token]"
  echo "Или: VAULT_LEASE_ID=<id> VAULT_TOKEN=<token> bash $0"
  echo ""
  echo "Посмотреть активные аренды: bash list-active-leases.sh"
  exit 1
fi

api() {
  curl -sf --max-time 15 -X "$1" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    "$VAULT_ADDR/v1/$2" ${3:+-d "$3"} 2>/dev/null
}

echo "=== Отзыв аренды Vault ==="
echo "Lease ID:  $LEASE_ID"
echo "Vault:     $VAULT_ADDR"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"

# ── Проверка аренды до отзыва ─────────────────────────────────────────────
echo ""
echo "── Информация об аренде ─────────────────────────────────────────────────"
lease_info=$(api GET "sys/leases/lookup" "{\"lease_id\": \"$LEASE_ID\"}" 2>/dev/null || echo "{}")
if echo "$lease_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}))" 2>/dev/null | grep -q "expire_time"; then
  lease_data=$(echo "$lease_info" | python3 -c "
import json,sys
d = json.load(sys.stdin).get('data',{})
print(f\"  ID:          {d.get('id','?')}\")
print(f\"  Путь:        {d.get('path','?')}\")
print(f\"  Истекает:    {d.get('expire_time','?')}\")
print(f\"  Обновляема:  {d.get('renewable','?')}\")
" 2>/dev/null)
  ok "Аренда найдена"
  echo "$lease_data"
else
  warn "Информация об аренде недоступна (возможно уже истекла или не существует)"
fi

# ── Извлечение имени пользователя БД (если Database-аренда) ──────────────
db_username=""
if echo "$LEASE_ID" | grep -q "database/creds/"; then
  # Пытаемся получить имя пользователя из пути аренды
  db_username=$(echo "$lease_info" | python3 -c "
import json,sys
d = json.load(sys.stdin).get('data',{})
# Имя пользователя обычно кодируется в lease_id
lid = d.get('id','')
# vault-myapp-XXXXXXXX
import re
match = re.search(r'vault-[a-zA-Z0-9_-]+', lid)
print(match.group(0) if match else '')
" 2>/dev/null || echo "")
fi

# ── Отзыв аренды ─────────────────────────────────────────────────────────
echo ""
echo "── Отзыв ───────────────────────────────────────────────────────────────"
start_time=$(date +%s)
revoke_result=$(api PUT "sys/leases/revoke" "{\"lease_id\": \"$LEASE_ID\", \"sync\": true}" 2>/dev/null || echo "error")

if [ "$revoke_result" != "error" ] && [ -z "$(echo "$revoke_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('errors',''))" 2>/dev/null)" ]; then
  elapsed=$(( $(date +%s) - start_time ))
  ok "Аренда отозвана (${elapsed}с): $LEASE_ID"
else
  # Пробуем force-revoke
  warn "Обычный отзыв не сработал — попытка принудительного отзыва"
  force_result=$(api PUT "sys/leases/revoke-force" "{\"prefix\": \"$LEASE_ID\"}" 2>/dev/null || echo "error")
  if [ "$force_result" != "error" ]; then
    ok "Принудительный отзыв выполнен"
  else
    fail "Не удалось отозвать аренду: $LEASE_ID"
  fi
fi

# ── Проверка через Vault: аренда исчезла ─────────────────────────────────
echo ""
echo "── Верификация через Vault ──────────────────────────────────────────────"
sleep 1  # небольшая пауза для синхронизации
verify_result=$(api GET "sys/leases/lookup" "{\"lease_id\": \"$LEASE_ID\"}" 2>/dev/null || echo "not_found")
if echo "$verify_result" | grep -q "invalid lease"; then
  ok "Аренда подтверждённо удалена из Vault"
elif [ "$verify_result" = "not_found" ] || [ -z "$verify_result" ]; then
  ok "Аренда не найдена в Vault (отозвана)"
else
  warn "Аренда всё ещё присутствует в Vault — проверьте вручную"
fi

# ── Проверка удаления пользователя из PostgreSQL ─────────────────────────
if [ -n "$VERIFY_DB" ] && [ -n "$db_username" ]; then
  echo ""
  echo "── Верификация в PostgreSQL ─────────────────────────────────────────────"
  db_host=$(echo "$VERIFY_DB" | cut -d: -f1)
  db_port=$(echo "$VERIFY_DB" | cut -d: -f2)
  db_port="${db_port:-5432}"
  admin="${VERIFY_DB_ADMIN:-postgres}"

  if command -v psql &>/dev/null; then
    exists=$(PGPASSWORD="${PGPASSWORD:-}" psql -h "$db_host" -p "$db_port" -U "$admin" \
      -tAc "SELECT 1 FROM pg_roles WHERE rolname='$db_username';" 2>/dev/null || echo "error")
    if [ "$exists" = "1" ]; then
      fail "Пользователь $db_username всё ещё существует в PostgreSQL — ждите синхронизации или проверьте подключение Vault к БД"
    elif [ "$exists" = "error" ]; then
      warn "Не удалось проверить PostgreSQL — проверьте вручную: SELECT rolname FROM pg_roles WHERE rolname LIKE 'vault-%';"
    else
      ok "Пользователь $db_username удалён из PostgreSQL"
    fi
  else
    warn "psql не найден — проверьте вручную: psql -c \"SELECT rolname FROM pg_roles WHERE rolname='$db_username';\""
  fi
elif [ -n "$db_username" ]; then
  echo ""
  warn "Database-аренда обнаружена ($db_username), но VERIFY_DB не задан"
  echo "    Проверьте вручную: psql -c \"\\\\du\" | grep vault-"
fi

# ── Протокол ─────────────────────────────────────────────────────────────
AUDIT_FILE="lease-revoke-$(date +%Y%m%d%H%M%S).txt"
{
  echo "# Протокол отзыва аренды"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Lease ID: $LEASE_ID"
  echo "# Исполнитель: $(vault token lookup -format=json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('display_name','?'))" 2>/dev/null || echo '?')"
  echo "# PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
} > "$AUDIT_FILE"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Протокол: $AUDIT_FILE"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
