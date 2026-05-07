#!/usr/bin/env bash
# Проверка срока действия всех сертификатов в директории
# Использование: bash check-cert-expiry.sh [директория] [дней_до_предупреждения]
set -euo pipefail

CERT_DIR="${1:-/etc/ssl/services}"
WARN_DAYS="${2:-30}"

echo "=== Проверка срока действия сертификатов ==="
echo "  Директория: $CERT_DIR | Предупреждение за: $WARN_DAYS дней"
echo ""

found=0
expire_soon=0

find "$CERT_DIR" -name "*.crt" -o -name "*.pem" 2>/dev/null | while read cert; do
  [ -f "$cert" ] || continue
  expiry=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2) || continue
  cn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -oP 'CN=\K[^,]+' || echo "?")
  
  expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %e %H:%M:%S %Y %Z" "$expiry" +%s 2>/dev/null)
  now_epoch=$(date +%s)
  days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

  if [ "$days_left" -le 0 ]; then
    printf "  [FAIL] %-50s ИСТЁК (%s)\n" "$cn" "$expiry"
  elif [ "$days_left" -le "$WARN_DAYS" ]; then
    printf "  [WARN] %-50s %d дней (%s)\n" "$cn" "$days_left" "$expiry"
  else
    printf "  [OK]   %-50s %d дней\n" "$cn" "$days_left"
  fi
done

echo ""
echo "Для автообновления через Vault PKI — см. раздел 7.3"
