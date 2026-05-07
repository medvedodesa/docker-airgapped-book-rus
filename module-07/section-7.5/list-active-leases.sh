#!/usr/bin/env bash
# Вывод всех активных аренд Vault с временем истечения и идентификаторами для аудита
# Использование: bash list-active-leases.sh [prefix] [vault_addr] [vault_token]
set -euo pipefail

LEASE_PREFIX="${1:-}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${3:-${VAULT_TOKEN:-}}"
WARN_HOURS="${LEASE_WARN_HOURS:-24}"
OUTPUT="${LEASES_OUTPUT:-}"

if [ -z "$VAULT_TOKEN" ]; then
  echo "Укажите VAULT_TOKEN или передайте как третий аргумент"
  exit 1
fi

api() {
  curl -sf --max-time 15 -X "$1" \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    -H "Content-Type: application/json" \
    "$VAULT_ADDR/v1/$2" ${3:+-d "$3"} 2>/dev/null
}

echo "=== Активные аренды Vault ==="
echo "Vault:    $VAULT_ADDR"
echo "Префикс: ${LEASE_PREFIX:-(все)}"
echo "Дата:    $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Активные аренды Vault"
  echo "# Vault: $VAULT_ADDR  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # Получаем список аренд
  list_path="sys/leases/lookup"
  if [ -n "$LEASE_PREFIX" ]; then
    leases_raw=$(api PUT "sys/leases/lookup" "{\"prefix\": \"$LEASE_PREFIX\"}" 2>/dev/null || echo "{}")
  else
    # Без префикса — список по известным путям Database и SSH
    leases_raw="{}"
  fi

  # Аренды Database
  echo "## Database-аренды"
  db_leases=$(api PUT "sys/leases/lookup" '{"prefix": "database/creds/"}' 2>/dev/null || echo "{}")
  db_keys=$(echo "$db_leases" | python3 -c "
import json,sys
d = json.load(sys.stdin)
keys = d.get('data',{}).get('keys',[])
print('\n'.join(keys))
" 2>/dev/null || echo "")

  if [ -n "$db_keys" ]; then
    printf "   %-50s %-25s %-12s %s\n" "Lease ID" "Истекает" "Обновляема" "Осталось"
    printf "   %-50s %-25s %-12s %s\n" "--------" "--------" "----------" "--------"
    now_epoch=$(date +%s)
    while IFS= read -r lease_id; do
      [ -z "$lease_id" ] && continue
      info=$(api PUT "sys/leases/lookup" "{\"lease_id\": \"$lease_id\"}" 2>/dev/null || echo "{}")
      expire=$(echo "$info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('expire_time','?'))" 2>/dev/null || echo "?")
      renewable=$(echo "$info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('renewable','?'))" 2>/dev/null || echo "?")

      if [ "$expire" != "?" ] && [ "$expire" != "null" ]; then
        exp_epoch=$(date -d "$expire" +%s 2>/dev/null || echo 0)
        hours_left=$(( (exp_epoch - now_epoch) / 3600 ))
        if   [ "$hours_left" -lt 0 ];            then status="ИСТЕКЛА"
        elif [ "$hours_left" -lt "$WARN_HOURS" ]; then status="${hours_left}ч [WARN]"
        else                                           status="${hours_left}ч"
        fi
      else
        status="?"
      fi

      short_id=$(echo "$lease_id" | sed 's|database/creds/||' | cut -c1-40)
      expire_short=$(echo "$expire" | cut -c1-19 | tr 'T' ' ')
      printf "   %-50s %-25s %-12s %s\n" "$short_id" "$expire_short" "$renewable" "$status"
    done <<< "$db_keys"
  else
    echo "   Database-аренд не найдено"
  fi
  echo ""

  # Аренды SSH
  echo "## SSH-аренды"
  ssh_leases=$(api PUT "sys/leases/lookup" '{"prefix": "ssh/creds/"}' 2>/dev/null || echo "{}")
  ssh_keys=$(echo "$ssh_leases" | python3 -c "
import json,sys
d = json.load(sys.stdin)
keys = d.get('data',{}).get('keys',[])
print('\n'.join(keys))
" 2>/dev/null || echo "")

  if [ -n "$ssh_keys" ]; then
    echo "   $(echo "$ssh_keys" | wc -l | tr -d ' ') активных SSH-аренд"
    echo "$ssh_keys" | head -10 | sed 's/^/   /'
  else
    echo "   SSH-аренд не найдено"
  fi
  echo ""

  # Аренды PKI
  echo "## PKI-аренды (сертификаты)"
  pki_leases=$(api PUT "sys/leases/lookup" '{"prefix": "pki"}' 2>/dev/null || echo "{}")
  pki_count=$(echo "$pki_leases" | python3 -c "
import json,sys
d = json.load(sys.stdin)
keys = d.get('data',{}).get('keys',[])
print(len(keys))
" 2>/dev/null || echo 0)
  echo "   Активных PKI-аренд: $pki_count"
  echo ""

  # Произвольный префикс
  if [ -n "$LEASE_PREFIX" ] && ! echo "$LEASE_PREFIX" | grep -qE "^(database|ssh|pki)"; then
    echo "## Аренды по префиксу: $LEASE_PREFIX"
    custom=$(api PUT "sys/leases/lookup" "{\"prefix\": \"$LEASE_PREFIX\"}" 2>/dev/null || echo "{}")
    custom_keys=$(echo "$custom" | python3 -c "
import json,sys
keys = json.load(sys.stdin).get('data',{}).get('keys',[])
print('\n'.join(keys))
" 2>/dev/null || echo "")
    [ -n "$custom_keys" ] && echo "$custom_keys" | sed 's/^/   /' || echo "   Аренд не найдено"
    echo ""
  fi

  # Итог
  echo "## Действия"
  echo "   Отзыв конкретной аренды: bash revoke-lease.sh <lease_id>"
  echo "   Массовый отзыв:          vault lease revoke -prefix <prefix>"
  echo "   Просмотр деталей:        vault lease lookup <lease_id>"

} | tee "${OUTPUT:--}"

[ -n "$OUTPUT" ] && echo "" && echo "Отчёт сохранён: $OUTPUT"
