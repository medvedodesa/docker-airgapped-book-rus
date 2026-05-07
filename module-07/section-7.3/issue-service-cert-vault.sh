#!/usr/bin/env bash
# Выдача TLS-сертификата сервису через Vault PKI и сохранение в файлы
# Использование: bash issue-service-cert-vault.sh <common_name> [ttl] [output_dir]
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
COMMON_NAME="${1:-}"
TTL="${2:-720h}"
OUTPUT_DIR="${3:-/etc/certs}"
PKI_ROLE="${VAULT_PKI_ROLE:-service-certs}"

[ -n "$COMMON_NAME" ] || { echo "Использование: $0 <common_name> [ttl] [output_dir]"; exit 1; }
[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

export VAULT_ADDR

echo "=== Выдача TLS-сертификата ==="
echo "  CN:     $COMMON_NAME"
echo "  TTL:    $TTL"
echo "  Каталог: $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"
chmod 755 "$OUTPUT_DIR"

# Выдача
echo ""
echo "--- Запрос сертификата ---"
CERT_JSON=$(vault write -format=json "pki_int/issue/$PKI_ROLE" \
  common_name="$COMMON_NAME" \
  ttl="$TTL" \
  alt_names="$COMMON_NAME" \
  2>/dev/null)

# Сохранение файлов
echo "$CERT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
base = '$OUTPUT_DIR/${COMMON_NAME%%.*}'

with open(base + '.crt', 'w') as f:
    f.write(d['certificate'] + '\n')
    for c in d.get('ca_chain', []):
        f.write(c + '\n')

with open(base + '.key', 'w') as f:
    f.write(d['private_key'])

with open('$OUTPUT_DIR/ca.crt', 'w') as f:
    f.write(d['issuing_ca'])

print('  [OK] ' + base + '.crt')
print('  [OK] ' + base + '.key')
print('  [OK] \$OUTPUT_DIR/ca.crt')
"

# Права доступа
CERT_BASE="$OUTPUT_DIR/${COMMON_NAME%%.*}"
chmod 644 "${CERT_BASE}.crt" "$OUTPUT_DIR/ca.crt"
chmod 600 "${CERT_BASE}.key"

# Срок действия
echo ""
echo "--- Информация о сертификате ---"
openssl x509 -in "${CERT_BASE}.crt" -noout \
  -subject -issuer \
  -dates 2>/dev/null | sed 's/^/  /'

serial=$(openssl x509 -in "${CERT_BASE}.crt" -noout -serial 2>/dev/null | cut -d= -f2)
echo "  Серийный номер: $serial"

echo ""
echo "=== Сертификат выдан ==="
echo ""
echo "Проверка:"
echo "  openssl verify -CAfile $OUTPUT_DIR/ca.crt ${CERT_BASE}.crt"
