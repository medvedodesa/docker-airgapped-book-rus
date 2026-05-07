#!/usr/bin/env bash
# Создание временного самоподписанного TLS-сертификата для Harbor
# ВНИМАНИЕ: только для первоначального развёртывания до подключения Vault PKI
# Использование: bash generate-harbor-certs.sh <hostname> [директория]
# Пример:        bash generate-harbor-certs.sh harbor.internal /opt/harbor/certs
set -euo pipefail

HARBOR_HOST="${1:?Укажите DNS-имя Harbor: bash $0 harbor.internal}"
CERT_DIR="${2:-/opt/harbor/certs}"
DAYS=825  # максимум 825 дней для совместимости с современными браузерами

echo "=== Создание TLS-сертификата для Harbor ==="
echo "Хост:      $HARBOR_HOST"
echo "Директория: $CERT_DIR"
echo "Срок:      $DAYS дней (замените через Vault PKI после его развёртывания)"
echo ""

if ! command -v openssl &>/dev/null; then
  echo "[FAIL] openssl не найден — установите пакет openssl"
  exit 1
fi

mkdir -p "$CERT_DIR"

CA_KEY="$CERT_DIR/ca.key"
CA_CERT="$CERT_DIR/ca.crt"
SRV_KEY="$CERT_DIR/${HARBOR_HOST}.key"
SRV_CSR="$CERT_DIR/${HARBOR_HOST}.csr"
SRV_CERT="$CERT_DIR/${HARBOR_HOST}.cert"
EXT_FILE="$CERT_DIR/v3.ext"

# --- Корневой CA ---
echo "--- Корневой CA ---"
if [ ! -f "$CA_KEY" ]; then
  openssl genrsa -out "$CA_KEY" 4096
  echo "  CA ключ создан: $CA_KEY"
else
  echo "  CA ключ уже существует: $CA_KEY"
fi

if [ ! -f "$CA_CERT" ]; then
  openssl req -x509 -new -nodes \
    -key "$CA_KEY" \
    -sha256 \
    -days "$DAYS" \
    -out "$CA_CERT" \
    -subj "/C=RU/ST=Moscow/O=AirGap-Temp-CA/CN=Harbor-CA-${HARBOR_HOST}"
  echo "  CA сертификат создан: $CA_CERT"
else
  echo "  CA сертификат уже существует: $CA_CERT"
fi

# --- Ключ и CSR сервера ---
echo ""
echo "--- Сертификат сервера ---"
openssl genrsa -out "$SRV_KEY" 4096
echo "  Ключ сервера создан: $SRV_KEY"

openssl req -new \
  -key "$SRV_KEY" \
  -out "$SRV_CSR" \
  -subj "/C=RU/ST=Moscow/O=Harbor/CN=${HARBOR_HOST}"
echo "  CSR создан: $SRV_CSR"

# --- X.509 v3 расширения (SAN) ---
cat > "$EXT_FILE" << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${HARBOR_HOST}
DNS.2 = localhost
IP.1 = 127.0.0.1
EOF

# --- Подписываем сертификат сервера ---
openssl x509 -req \
  -in "$SRV_CSR" \
  -CA "$CA_CERT" \
  -CAkey "$CA_KEY" \
  -CAcreateserial \
  -out "$SRV_CERT" \
  -days "$DAYS" \
  -sha256 \
  -extfile "$EXT_FILE"
echo "  Сертификат сервера создан: $SRV_CERT"

# --- Проверка ---
echo ""
echo "--- Проверка сертификата ---"
openssl verify -CAfile "$CA_CERT" "$SRV_CERT" && \
  echo "[PASS] Цепочка сертификатов корректна" || \
  echo "[FAIL] Цепочка сертификатов не прошла проверку"

echo ""
echo "--- Срок действия ---"
openssl x509 -in "$SRV_CERT" -noout -dates

echo ""
echo "--- SAN (Subject Alternative Names) ---"
openssl x509 -in "$SRV_CERT" -noout -ext subjectAltName

# --- Инструкции по использованию ---
echo ""
echo "=== Готово ==="
echo ""
echo "1. Скопируйте в harbor.yml:"
echo "   certificate: $SRV_CERT"
echo "   private_key: $SRV_KEY"
echo ""
echo "2. Добавьте CA на Docker-хосты (пример для Ubuntu):"
echo "   sudo cp $CA_CERT /usr/local/share/ca-certificates/harbor-ca.crt"
echo "   sudo update-ca-certificates"
echo ""
echo "3. Добавьте CA в Docker конфигурацию:"
echo "   sudo mkdir -p /etc/docker/certs.d/${HARBOR_HOST}"
echo "   sudo cp $CA_CERT /etc/docker/certs.d/${HARBOR_HOST}/ca.crt"
echo ""
echo "⚠  ВРЕМЕННОЕ РЕШЕНИЕ: замените на сертификат от Vault PKI (раздел 7) после развёртывания Vault."
echo "   Файл для отслеживания: $CERT_DIR/REPLACE_WITH_VAULT.txt"
echo "$(date): Временный сертификат для $HARBOR_HOST — заменить через Vault PKI" > "$CERT_DIR/REPLACE_WITH_VAULT.txt"
