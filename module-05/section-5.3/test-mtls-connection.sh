#!/usr/bin/env bash
# Тестирование mTLS соединения между двумя сервисами с диагностикой ошибок
# Использование: bash test-mtls-connection.sh <url> <client_cert> <client_key> <ca_cert>
set -euo pipefail

TARGET_URL="${1:-https://service.internal:8443/health}"
CLIENT_CERT="${2:-/etc/certs/client.crt}"
CLIENT_KEY="${3:-/etc/certs/client.key}"
CA_CERT="${4:-/etc/certs/ca.crt}"
VERBOSE="${MTLS_VERBOSE:-0}"

echo "=== Тест mTLS соединения ==="
echo "  Цель:           $TARGET_URL"
echo "  Сертификат:     $CLIENT_CERT"
echo "  CA:             $CA_CERT"

# Проверка файлов
echo ""
echo "--- Проверка сертификатов ---"
for f in "$CLIENT_CERT" "$CLIENT_KEY" "$CA_CERT"; do
  [ -f "$f" ] && echo "  [OK] $f существует" || { echo "  [FAIL] $f не найден"; exit 1; }
done

# Проверка срока действия
cert_expiry=$(openssl x509 -in "$CLIENT_CERT" -noout -dates 2>/dev/null | grep notAfter | cut -d= -f2)
echo "  Срок действия клиентского сертификата до: $cert_expiry"

# Проверка SubjectAltName
san=$(openssl x509 -in "$CLIENT_CERT" -noout -ext subjectAltName 2>/dev/null | grep -v "X509v3" || true)
[ -n "$san" ] && echo "  SAN: $san"

# Проверка подписи CA
echo ""
echo "--- Проверка цепочки доверия ---"
if openssl verify -CAfile "$CA_CERT" "$CLIENT_CERT" &>/dev/null 2>&1; then
  echo "  [OK] Сертификат подписан доверенным CA"
else
  echo "  [FAIL] Сертификат не верифицирован CA"
  exit 1
fi

# Тест соединения
echo ""
echo "--- Тест mTLS соединения ---"
curl_args=("-s" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "10"
           "--cert" "$CLIENT_CERT" "--key" "$CLIENT_KEY" "--cacert" "$CA_CERT")
[ "$VERBOSE" = "1" ] && curl_args+=("-v")

http_code=$(curl "${curl_args[@]}" "$TARGET_URL" 2>/dev/null)

case "$http_code" in
  200|201|204)
    echo "  [OK] mTLS соединение успешно (HTTP $http_code)"
    ;;
  401|403)
    echo "  [FAIL] Отказ авторизации (HTTP $http_code) — SVID/сертификат не авторизован"
    ;;
  000)
    echo "  [FAIL] Соединение не установлено — проверьте сеть и сертификаты"
    echo ""
    echo "  Диагностика:"
    echo "    openssl s_client -connect <host>:<port> -cert $CLIENT_CERT -key $CLIENT_KEY -CAfile $CA_CERT"
    exit 1
    ;;
  *)
    echo "  [WARN] HTTP $http_code"
    ;;
esac
