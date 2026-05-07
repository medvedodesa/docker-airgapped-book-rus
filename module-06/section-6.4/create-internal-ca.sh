#!/usr/bin/env bash
# Генерация внутреннего CA (корневой + промежуточный) для закрытого контура
set -euo pipefail

CA_DIR="${1:-/etc/ssl/internal-ca}"
DOMAIN="${2:-internal.company.local}"
DAYS_ROOT="${3:-3650}"
DAYS_INT="${4:-1825}"

echo "=== Создание внутреннего CA для $DOMAIN ==="
mkdir -p "$CA_DIR"/{root,intermediate}/{certs,private,crl,newcerts}
chmod 700 "$CA_DIR"/{root,intermediate}/private

# --- Корневой CA ---
echo ""
echo "--- Корневой CA ---"
openssl genrsa -out "$CA_DIR/root/private/root-ca.key" 4096 2>/dev/null
chmod 400 "$CA_DIR/root/private/root-ca.key"

openssl req -new -x509 \
  -key "$CA_DIR/root/private/root-ca.key" \
  -out "$CA_DIR/root/certs/root-ca.crt" \
  -days "$DAYS_ROOT" \
  -subj "/C=RU/O=Company/CN=Root CA $DOMAIN" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

echo "[OK] Корневой CA: $CA_DIR/root/certs/root-ca.crt"

# --- Промежуточный CA ---
echo ""
echo "--- Промежуточный CA ---"
openssl genrsa -out "$CA_DIR/intermediate/private/intermediate-ca.key" 4096 2>/dev/null
chmod 400 "$CA_DIR/intermediate/private/intermediate-ca.key"

openssl req -new \
  -key "$CA_DIR/intermediate/private/intermediate-ca.key" \
  -out "$CA_DIR/intermediate/intermediate-ca.csr" \
  -subj "/C=RU/O=Company/CN=Intermediate CA $DOMAIN" 2>/dev/null

openssl x509 -req \
  -in "$CA_DIR/intermediate/intermediate-ca.csr" \
  -CA "$CA_DIR/root/certs/root-ca.crt" \
  -CAkey "$CA_DIR/root/private/root-ca.key" \
  -CAcreateserial \
  -out "$CA_DIR/intermediate/certs/intermediate-ca.crt" \
  -days "$DAYS_INT" \
  -extfile <(echo -e "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign") 2>/dev/null

echo "[OK] Промежуточный CA: $CA_DIR/intermediate/certs/intermediate-ca.crt"

# CA bundle
cat "$CA_DIR/intermediate/certs/intermediate-ca.crt" \
    "$CA_DIR/root/certs/root-ca.crt" > "$CA_DIR/ca-bundle.crt"

echo ""
echo "=== Итог ==="
echo "  Корневой CA:       $CA_DIR/root/certs/root-ca.crt"
echo "  Промежуточный CA:  $CA_DIR/intermediate/certs/intermediate-ca.crt"
echo "  CA Bundle:         $CA_DIR/ca-bundle.crt"
echo ""
echo "  Установка на хосты: cp $CA_DIR/root/certs/root-ca.crt /usr/local/share/ca-certificates/ && update-ca-certificates"
echo "  ВАЖНО: храните корневой ключ ($CA_DIR/root/private/root-ca.key) ОФЛАЙН!"
