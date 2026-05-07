#!/usr/bin/env bash
# Аварийная генерация корневого токена Vault с кворумом фрагментов ключа
# ВАЖНО: Использовать ТОЛЬКО в аварийных ситуациях. Токен отзывается немедленно после использования.
# Использование: bash generate-root-token.sh [vault_addr]
set -euo pipefail

VAULT_ADDR="${1:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"

echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║          АВАРИЙНАЯ ГЕНЕРАЦИЯ КОРНЕВОГО ТОКЕНА VAULT                     ║"
echo "║                                                                          ║"
echo "║  Используйте ТОЛЬКО при подтверждённой аварии.                          ║"
echo "║  Корневой токен должен быть НЕМЕДЛЕННО отозван после завершения работ.  ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Vault: $VAULT_ADDR"
echo "Дата:  $(date '+%Y-%m-%d %H:%M:%S')"
echo ""

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

api() {
  curl -sf --max-time 15 -X "$1" \
    -H "Content-Type: application/json" \
    "$VAULT_ADDR/v1/$2" ${3:+-d "$3"} 2>/dev/null
}

api_token() {
  curl -sf --max-time 15 -X "$1" \
    -H "X-Vault-Token: $2" \
    -H "Content-Type: application/json" \
    "$VAULT_ADDR/v1/$3" ${4:+-d "$4"} 2>/dev/null
}

# ── Подтверждение ─────────────────────────────────────────────────────────
echo "ВНИМАНИЕ: Данная процедура требует кворума держателей ключей."
echo "Продолжить? Введите 'CONFIRM' для подтверждения:"
read -r confirmation
if [ "$confirmation" != "CONFIRM" ]; then
  echo "Отменено."
  exit 0
fi

echo ""
echo "Причина генерации (для аудита):"
read -r REASON
REASON="${REASON:-не указана}"

# Фиксируем начало процедуры
echo ""
echo "── Начало процедуры: $(date '+%Y-%m-%d %H:%M:%S') ──────────────────────────"
echo "   Исполнитель: ${USER:-unknown}"
echo "   Причина:     $REASON"

# ── Проверка статуса Vault ────────────────────────────────────────────────
echo ""
echo "── Статус Vault ─────────────────────────────────────────────────────────"
health=$(curl -sf --max-time 10 "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo "{}")
sealed=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
[ "$sealed" = "True" ] && warn "Vault запечатан — сначала распечатайте" || ok "Vault распечатан"

seal_info=$(api GET "sys/seal-status" 2>/dev/null || echo "{}")
threshold=$(echo "$seal_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('t','?'))" 2>/dev/null || echo "?")
shares=$(echo "$seal_info"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('n','?'))" 2>/dev/null || echo "?")
ok "Порог кворума: $threshold из $shares фрагментов"

# ── Инициализация генерации ────────────────────────────────────────────────
echo ""
echo "── Инициализация генерации корневого токена ─────────────────────────────"
OTP=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || \
      openssl rand -base64 24 | tr -d '\n')
ok "OTP сгенерирован (хранится только в памяти)"

init_result=$(api PUT "sys/generate-root/attempt" "{\"otp\": \"$OTP\"}" 2>/dev/null || echo "{}")
nonce=$(echo "$init_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nonce',''))" 2>/dev/null || echo "")
complete=$(echo "$init_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('complete',False))" 2>/dev/null || echo "False")

if [ -z "$nonce" ]; then
  # Возможно уже инициализирована
  existing=$(api GET "sys/generate-root/attempt" 2>/dev/null || echo "{}")
  nonce=$(echo "$existing" | python3 -c "import json,sys; print(json.load(sys.stdin).get('nonce',''))" 2>/dev/null || echo "")
fi

[ -z "$nonce" ] && { fail "Не удалось инициализировать генерацию"; exit 1; }
ok "Генерация инициализирована (nonce=$nonce)"

# ── Сбор фрагментов ───────────────────────────────────────────────────────
echo ""
echo "── Ввод фрагментов ключа ────────────────────────────────────────────────"
echo "   Требуется $threshold фрагментов из $shares держателей."
echo ""

encoded_token=""
keys_provided=0

while [ "$complete" != "True" ] && [ "$keys_provided" -lt "$threshold" ]; do
  ((keys_provided++))
  echo "   Фрагмент $keys_provided из $threshold:"
  echo -n "   Имя держателя: "
  read -r key_holder
  echo -n "   Фрагмент ключа (Base64): "
  read -rs key_fragment
  echo ""

  update_result=$(api PUT "sys/generate-root/update" \
    "{\"key\": \"$key_fragment\", \"nonce\": \"$nonce\"}" 2>/dev/null || echo "{}")

  complete=$(echo "$update_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('complete',False))" 2>/dev/null || echo "False")
  progress=$(echo "$update_result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d.get('progress',0)}/{d.get('required',threshold)}\")" 2>/dev/null || echo "?")
  encoded_token=$(echo "$update_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('encoded_token',''))" 2>/dev/null || echo "")

  errors=$(echo "$update_result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('errors',[]))" 2>/dev/null || echo "[]")
  if [ "$errors" != "[]" ] && [ "$errors" != "" ]; then
    fail "Ошибка при обработке фрагмента от $key_holder: $errors"
  else
    ok "Фрагмент от $key_holder принят (прогресс: $progress)"
  fi
done

# ── Декодирование токена ───────────────────────────────────────────────────
echo ""
echo "── Декодирование токена ─────────────────────────────────────────────────"
if [ -z "$encoded_token" ]; then
  fail "Encoded token не получен — возможно кворум не собран"
  exit 1
fi

root_token=$(python3 -c "
import base64, hashlib
otp = '$OTP'
encoded = '$encoded_token'

# XOR декодирование
otp_bytes     = base64.b64decode(otp + '==')
encoded_bytes = base64.b64decode(encoded + '==')

# Vault использует XOR токена и OTP
token_bytes = bytes(a ^ b for a, b in zip(encoded_bytes, otp_bytes))
print(token_bytes.decode('utf-8').strip('\x00'))
" 2>/dev/null || echo "")

if [ -z "$root_token" ]; then
  fail "Не удалось декодировать токен — проверьте OTP"
  exit 1
fi
ok "Корневой токен декодирован"

# ── Верификация токена ────────────────────────────────────────────────────
echo ""
echo "── Верификация ──────────────────────────────────────────────────────────"
verify=$(api_token GET "$root_token" "auth/token/lookup-self" 2>/dev/null || echo "{}")
policies=$(echo "$verify" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('policies',[]))" 2>/dev/null || echo "[]")
if echo "$policies" | grep -q '"root"'; then
  ok "Корневой токен действителен — политики: $policies"
else
  fail "Токен не имеет root-политики — что-то пошло не так"
  exit 1
fi

# ── Вывод токена ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║  КОРНЕВОЙ ТОКЕН VAULT:                                                  ║"
echo "║  $root_token"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""
echo "ВЫПОЛНИТЕ НЕОБХОДИМЫЕ ОПЕРАЦИИ СЕЙЧАС."
echo "Нажмите Enter после завершения работ для НЕМЕДЛЕННОГО ОТЗЫВА токена:"
read -r _

# ── Немедленный отзыв ─────────────────────────────────────────────────────
echo ""
echo "── Отзыв корневого токена ───────────────────────────────────────────────"
revoke_result=$(api_token POST "$root_token" "auth/token/revoke-self" 2>/dev/null || echo "error")
if [ "$revoke_result" != "error" ] || [ -z "$revoke_result" ]; then
  ok "Корневой токен отозван"
else
  fail "Не удалось отозвать токен автоматически — выполните вручную: vault token revoke <token>"
fi

# Очистка попытки генерации
api DELETE "sys/generate-root/attempt" >/dev/null 2>&1 || true

# ── Протокол ─────────────────────────────────────────────────────────────
AUDIT_FILE="root-token-$(date +%Y%m%d%H%M%S).txt"
{
  echo "# Протокол генерации корневого токена"
  echo "# ХРАНИТЬ БЕССРОЧНО"
  echo "# Дата начала: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Vault: $VAULT_ADDR"
  echo "# Исполнитель: ${USER:-unknown}"
  echo "# Причина: $REASON"
  echo "# Фрагментов предоставлено: $keys_provided из $threshold"
  echo "# PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
  echo "# Токен ОТОЗВАН: $(date '+%Y-%m-%d %H:%M:%S')"
} > "$AUDIT_FILE"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Протокол (хранить бессрочно): $AUDIT_FILE"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
