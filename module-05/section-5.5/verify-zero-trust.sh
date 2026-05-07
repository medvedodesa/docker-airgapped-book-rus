#!/usr/bin/env bash
# Проверка работоспособности сквозного сценария Zero Trust
# Запускайте после старта docker-compose.payment-api.yml
set -euo pipefail

SPIRE_SOCKET="/spire-agent-socket/api.sock"
PG_HOST="${PG_HOST:-postgres}"
PG_DB="${PG_DB:-payments}"
PG_USER="${PG_USER:-payment_api_user}"

PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Верификация Zero Trust: payment-api → PostgreSQL ==="

# ── Уровень 1: SVID выдаётся ─────────────────────────────────────────────
echo ""
echo "── 1. SVID от SPIRE ─────────────────────────────────────────────────"
docker exec payment-api \
  /opt/spire/bin/spire-agent api fetch x509 \
  -socketPath "$SPIRE_SOCKET" \
  -write /tmp/svid-check 2>/dev/null

spiffe_id=$(docker exec payment-api \
  openssl x509 -in /tmp/svid-check/svid.0.pem -text -noout 2>/dev/null | \
  grep "URI:" | grep spiffe | awk '{print $2}')

if echo "$spiffe_id" | grep -q "payment-api"; then
  ok "SPIFFE ID: $spiffe_id"
else
  fail "SVID не получен или SPIFFE ID некорректен"
fi

# ── Уровень 2: mTLS соединение с PostgreSQL ───────────────────────────────
echo ""
echo "── 2. mTLS к PostgreSQL ─────────────────────────────────────────────"
mtls_ok=$(docker exec payment-api psql \
  "host=$PG_HOST dbname=$PG_DB user=$PG_USER \
   sslmode=verify-full \
   sslcert=/tmp/svid-check/svid.0.pem \
   sslkey=/tmp/svid-check/svid.0.key \
   sslrootcert=/tmp/svid-check/bundle.0.pem" \
  -tAc "SELECT 1;" 2>/dev/null || echo "fail")

[ "$mtls_ok" = "1" ] && ok "mTLS соединение с PostgreSQL: успешно" || fail "mTLS соединение с PostgreSQL: неудача"

# Негативный тест: без сертификата должен быть отказ
no_cert_result=$(docker exec payment-api psql \
  "host=$PG_HOST dbname=$PG_DB user=$PG_USER sslmode=disable" \
  -tAc "SELECT 1;" 2>&1 || echo "rejected")

if echo "$no_cert_result" | grep -qi "no pg_hba\|rejected\|FATAL"; then
  ok "Соединение без сертификата: правильно отклонено"
else
  fail "Соединение без сертификата: принято — pg_hba.conf настроен неверно"
fi

# ── Уровень 3: Falco фиксирует события ───────────────────────────────────
echo ""
echo "── 3. Falco ─────────────────────────────────────────────────────────"
falco_running=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c falco || echo 0)
if [ "$falco_running" -gt 0 ]; then
  ok "Falco запущен"
  # Тест обнаружения: соединение от неавторизованного контейнера
  docker run --rm --network app-net \
    harbor.internal/library/alpine:3.19 \
    nc -z "$PG_HOST" 5432 2>/dev/null || true
  sleep 2
  falco_event=$(docker logs falco 2>&1 | grep -c "Unauthorized connection" || echo 0)
  [ "$falco_event" -gt 0 ] && ok "Falco: обнаружил несанкционированное соединение" || \
    fail "Falco: событие не зафиксировано"
else
  fail "Falco не запущен"
fi

# ── Уровень 4: аудитный след ─────────────────────────────────────────────
echo ""
echo "── 4. Аудитный след ─────────────────────────────────────────────────"
vault_audit=$(docker exec vault vault audit list 2>/dev/null | grep -c "file\|syslog" || echo 0)
[ "$vault_audit" -gt 0 ] && ok "Vault audit включён" || fail "Vault audit не настроен"

# Очистка
docker exec payment-api rm -rf /tmp/svid-check 2>/dev/null || true

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
