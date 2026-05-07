#!/usr/bin/env bash
# Создание иерархии PKI в Vault: Root CA и Intermediate CA
# Использование: bash setup-pki-hierarchy.sh [домен]
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
BASE_DOMAIN="${1:-internal.company.local}"
ROOT_TTL="${ROOT_TTL:-87600h}"      # 10 лет
INT_TTL="${INT_TTL:-43800h}"        # 5 лет
CERT_TTL="${CERT_TTL:-8760h}"       # 1 год

export VAULT_ADDR

echo "=== Настройка PKI-иерархии в Vault ==="
echo "  Домен:    $BASE_DOMAIN"
echo "  Root TTL: $ROOT_TTL"

[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

# Root CA
echo ""
echo "--- Root CA ---"
vault secrets enable -path=pki pki 2>/dev/null || echo "  pki уже включён"
vault secrets tune -max-lease-ttl="$ROOT_TTL" pki

vault write -field=certificate pki/root/generate/internal \
  common_name="$BASE_DOMAIN Root CA" \
  ttl="$ROOT_TTL" \
  key_type=rsa \
  key_bits=4096 \
  > /etc/vault.d/root_ca.crt 2>/dev/null

vault write pki/config/urls \
  issuing_certificates="$VAULT_ADDR/v1/pki/ca" \
  crl_distribution_points="$VAULT_ADDR/v1/pki/crl" \
  2>/dev/null

echo "  [OK] Root CA создан"

# Intermediate CA
echo ""
echo "--- Intermediate CA ---"
vault secrets enable -path=pki_int pki 2>/dev/null || echo "  pki_int уже включён"
vault secrets tune -max-lease-ttl="$INT_TTL" pki_int

# CSR от Intermediate
vault write -format=json pki_int/intermediate/generate/internal \
  common_name="$BASE_DOMAIN Intermediate CA" \
  key_type=rsa \
  key_bits=4096 \
  2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['csr'])" \
  > /tmp/pki_int.csr

# Подпись CSR корневым CA
vault write -format=json pki/root/sign-intermediate \
  csr=@/tmp/pki_int.csr \
  common_name="$BASE_DOMAIN Intermediate CA" \
  ttl="$INT_TTL" \
  2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['certificate'])" \
  > /tmp/pki_int_signed.crt

# Импорт подписанного Intermediate CA
vault write pki_int/intermediate/set-signed \
  certificate=@/tmp/pki_int_signed.crt 2>/dev/null

vault write pki_int/config/urls \
  issuing_certificates="$VAULT_ADDR/v1/pki_int/ca" \
  crl_distribution_points="$VAULT_ADDR/v1/pki_int/crl" \
  2>/dev/null

echo "  [OK] Intermediate CA подписан и импортирован"

# Роль для выдачи сертификатов сервисам
echo ""
echo "--- Роль для сервисных сертификатов ---"
vault write pki_int/roles/service-certs \
  allowed_domains="$BASE_DOMAIN" \
  allow_subdomains=true \
  allow_bare_domains=false \
  max_ttl="$CERT_TTL" \
  key_type=rsa \
  key_bits=2048 \
  require_cn=true \
  server_flag=true \
  client_flag=true \
  2>/dev/null

echo "  [OK] Роль service-certs создана"
rm -f /tmp/pki_int.csr /tmp/pki_int_signed.crt

echo ""
echo "=== PKI-иерархия настроена ==="
echo ""
echo "Выдача сертификата:"
echo "  vault write pki_int/issue/service-certs common_name=api.$BASE_DOMAIN ttl=720h"
echo ""
echo "Root CA сохранён: /etc/vault.d/root_ca.crt"
