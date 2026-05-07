#!/usr/bin/env bash
# Диагностика mTLS handshake — пять шагов от TLS до pg_hba.conf
set -euo pipefail

HOST="${1:-postgres}"
PORT="${2:-5432}"
CA_CERT="${3:-/app/certs/ca.crt}"
CLIENT_CERT="${4:-/app/certs/client.crt}"
CLIENT_KEY="${5:-/app/certs/client.key}"

echo "=== mTLS диагностика: $HOST:$PORT ==="

echo
echo "--- Шаг 1: TLS-соединение и верификация CA ---"
result=$(openssl s_client -connect "$HOST:$PORT" -starttls postgres \
  -CAfile "$CA_CERT" 2>&1 | grep "Verify return code")
echo "$result"
if echo "$result" | grep -q "Verify return code: 0"; then
  echo "PASS: TLS установлен, CA доверенный"
else
  echo "FAIL: проблема с CA или TLS"
fi

echo
echo "--- Шаг 2: цепочка клиентского сертификата ---"
if openssl verify -CAfile "$CA_CERT" "$CLIENT_CERT" 2>&1; then
  echo "PASS: цепочка клиентского сертификата корректна"
else
  echo "FAIL: клиентский сертификат не проходит верификацию по CA"
fi

echo
echo "--- Шаг 3: срок действия клиентского сертификата ---"
openssl x509 -in "$CLIENT_CERT" -noout -dates
not_after=$(openssl x509 -in "$CLIENT_CERT" -noout -enddate | cut -d= -f2)
expiry_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s)
now_epoch=$(date +%s)
days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
if [ "$days_left" -gt 7 ]; then
  echo "PASS: сертификат действителен ещё $days_left дней"
elif [ "$days_left" -gt 0 ]; then
  echo "WARN: сертификат истекает через $days_left дней — проверьте автоматическую ротацию"
else
  echo "FAIL: сертификат истёк $days_left дней назад"
fi

echo
echo "--- Шаг 4: CN клиентского сертификата ---"
cn=$(openssl x509 -in "$CLIENT_CERT" -noout -subject | grep -o 'CN=.*' | cut -d/ -f1 | cut -d, -f1)
echo "CN клиентского сертификата: $cn"
echo "Убедитесь что этот CN присутствует в pg_ident.conf как SYSTEM-USERNAME"

echo
echo "--- Шаг 5: pg_hba.conf на сервере ---"
if command -v docker &>/dev/null; then
  container=$(docker ps --format '{{.Names}}' | grep -i postgres | head -1)
  if [ -n "$container" ]; then
    echo "Контейнер PostgreSQL: $container"
    docker exec "$container" cat /etc/postgresql/pg_hba.conf 2>/dev/null | grep -v "^#" | grep -v "^$" || \
      echo "(pg_hba.conf недоступен или путь отличается)"
  else
    echo "Контейнер PostgreSQL не найден — проверьте pg_hba.conf вручную"
  fi
else
  echo "docker недоступен — проверьте pg_hba.conf на сервере вручную"
fi

echo
echo "=== Диагностика завершена ==="
