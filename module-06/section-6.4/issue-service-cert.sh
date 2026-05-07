#!/usr/bin/env bash
# Выдача сертификата для сервиса от внутреннего CA
# Использование: bash issue-service-cert.sh <имя_сервиса> <san1,san2> [ca_dir] [days]
set -euo pipefail

SERVICE="${1:-harbor}"
SANS="${2:-harbor.internal.company.local,192.168.1.20}"
CA_DIR="${3:-/etc/ssl/internal-ca}"
DAYS="${4:-365}"
CERT_DIR="/etc/ssl/services/$SERVICE"

echo "=== Выдача сертификата для: $SERVICE ==="
echo "  SAN: $SANS | Срок: $DAYS дней"

mkdir -p "$CERT_DIR"
openssl genrsa -out "$CERT_DIR/$SERVICE.key" 2048 2>/dev/null
chmod 600 "$CERT_DIR/$SERVICE.key"

# Формируем SAN
san_string=""
i=1
for san in $(echo "$SANS" | tr ',' ' '); do
  if echo "$san" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    san_string+="IP:$san,"
  else
    san_string+="DNS:$san,"
  fi
  ((i++))
done
san_string="${san_string%,}"

openssl req -new -key "$CERT_DIR/$SERVICE.key" \
  -out "$CERT_DIR/$SERVICE.csr" \
  -subj "/C=RU/O=Company/CN=$SERVICE" 2>/dev/null

openssl x509 -req \
  -in "$CERT_DIR/$SERVICE.csr" \
  -CA "$CA_DIR/intermediate/certs/intermediate-ca.crt" \
  -CAkey "$CA_DIR/intermediate/private/intermediate-ca.key" \
  -CAcreateserial \
  -out "$CERT_DIR/$SERVICE.crt" \
  -days "$DAYS" \
  -extfile <(echo -e "subjectAltName=$san_string\nextendedKeyUsage=serverAuth,clientAuth") 2>/dev/null

rm -f "$CERT_DIR/$SERVICE.csr"
cp "$CA_DIR/ca-bundle.crt" "$CERT_DIR/ca-bundle.crt"

echo ""
echo "[OK] Сертификат выдан:"
echo "  Ключ:   $CERT_DIR/$SERVICE.key"
echo "  Сертификат: $CERT_DIR/$SERVICE.crt"
openssl x509 -in "$CERT_DIR/$SERVICE.crt" -noout -dates 2>/dev/null
