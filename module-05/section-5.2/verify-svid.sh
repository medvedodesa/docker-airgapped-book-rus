#!/usr/bin/env bash
# Проверка корректности SVID, выданного SPIRE Agent рабочей нагрузке
# Использование: bash verify-svid.sh [spire_agent_socket] [spiffe_id]
set -euo pipefail

AGENT_SOCKET="${1:-${SPIRE_AGENT_SOCKET:-/tmp/spire-agent/public/api.sock}}"
EXPECTED_SPIFFE_ID="${2:-${SPIFFE_ID:-}}"
TRUST_DOMAIN="${SPIRE_TRUST_DOMAIN:-internal.company.local}"
WARN_DAYS="${SVID_WARN_DAYS:-7}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка SVID (SPIFFE Verifiable Identity Document) ==="
echo "Сокет:       $AGENT_SOCKET"
echo "Trust domain: $TRUST_DOMAIN"
echo "Дата:        $(date '+%Y-%m-%d %H:%M')"

# --- Проверка доступности сокета ---
echo ""
echo "--- SPIRE Agent ---"
if [ ! -S "$AGENT_SOCKET" ]; then
  fail "Сокет SPIRE Agent не найден: $AGENT_SOCKET"
  echo "    Убедитесь что SPIRE Agent запущен: systemctl status spire-agent"
  exit 1
fi
ok "Сокет SPIRE Agent доступен: $AGENT_SOCKET"

# --- Проверка наличия spire-agent CLI ---
if ! command -v spire-agent &>/dev/null; then
  fail "spire-agent не найден в PATH"
  exit 1
fi
ok "spire-agent: $(spire-agent --version 2>/dev/null | head -1 || echo 'найден')"

# --- Получение SVID ---
echo ""
echo "--- Получение SVID ---"
svid_output=$(spire-agent api fetch x509 \
  -socketPath "$AGENT_SOCKET" \
  -write /tmp/svid-check 2>&1 || echo "ERROR")

if echo "$svid_output" | grep -qi "error\|failed"; then
  fail "Не удалось получить SVID: $svid_output"
  exit 1
fi

if [ ! -f /tmp/svid-check/svid.0.pem ]; then
  fail "Файл SVID не создан — возможно рабочая нагрузка не зарегистрирована"
  exit 1
fi
ok "SVID получен и сохранён в /tmp/svid-check/"

# --- Анализ сертификата SVID ---
echo ""
echo "--- Анализ SVID ---"
SVID_PEM="/tmp/svid-check/svid.0.pem"

# SPIFFE ID из SAN
spiffe_id=$(openssl x509 -in "$SVID_PEM" -text -noout 2>/dev/null | \
  grep -i "URI:" | grep spiffe | awk '{print $2}' | tr -d ' ' || echo "")
if [ -n "$spiffe_id" ]; then
  ok "SPIFFE ID: $spiffe_id"
  # Проверка trust domain
  if echo "$spiffe_id" | grep -q "spiffe://$TRUST_DOMAIN/"; then
    ok "Trust domain совпадает: $TRUST_DOMAIN"
  else
    fail "Trust domain не совпадает: ожидается $TRUST_DOMAIN, получен $spiffe_id"
  fi
  # Сравнение с ожидаемым ID
  if [ -n "$EXPECTED_SPIFFE_ID" ]; then
    if [ "$spiffe_id" = "$EXPECTED_SPIFFE_ID" ]; then
      ok "SPIFFE ID совпадает с ожидаемым: $EXPECTED_SPIFFE_ID"
    else
      fail "SPIFFE ID не совпадает: ожидается $EXPECTED_SPIFFE_ID, получен $spiffe_id"
    fi
  fi
else
  fail "SPIFFE ID не найден в сертификате SAN"
fi

# Срок действия
not_after=$(openssl x509 -in "$SVID_PEM" -noout -enddate 2>/dev/null | cut -d= -f2)
if [ -n "$not_after" ]; then
  exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || \
    date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (exp_epoch - now_epoch) / 86400 ))
  if [ "$days_left" -lt 0 ]; then
    fail "SVID истёк $days_left дней назад"
  elif [ "$days_left" -lt "$WARN_DAYS" ]; then
    warn "SVID истекает через $days_left дней: $not_after"
  else
    ok "SVID действителен до: $not_after ($days_left дней)"
  fi
fi

# Алгоритм подписи
key_alg=$(openssl x509 -in "$SVID_PEM" -text -noout 2>/dev/null | \
  grep "Public Key Algorithm" | awk '{print $NF}')
ok "Алгоритм ключа: $key_alg"

# --- Проверка цепочки CA ---
echo ""
echo "--- Цепочка сертификатов ---"
BUNDLE_PEM="/tmp/svid-check/bundle.0.pem"
if [ -f "$BUNDLE_PEM" ]; then
  if openssl verify -CAfile "$BUNDLE_PEM" "$SVID_PEM" 2>/dev/null | grep -q OK; then
    ok "SVID верифицирован по bundle CA"
  else
    fail "Верификация SVID по bundle CA не прошла"
  fi
else
  warn "Bundle CA не найден — пропуск верификации цепочки"
fi

# --- Проверка mTLS соединения (опционально) ---
echo ""
echo "--- Тест применения SVID ---"
if [ -f "$SVID_PEM" ] && [ -f "/tmp/svid-check/svid.0.key" ]; then
  ok "Пара ключей SVID готова к использованию в mTLS"
  echo "    Сертификат: /tmp/svid-check/svid.0.pem"
  echo "    Ключ:       /tmp/svid-check/svid.0.key"
  echo "    Bundle CA:  /tmp/svid-check/bundle.0.pem"
else
  warn "Ключ SVID не найден — проверьте права на сокет"
fi

# --- Очистка ---
rm -rf /tmp/svid-check 2>/dev/null || true

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
