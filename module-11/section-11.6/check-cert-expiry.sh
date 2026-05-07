#!/usr/bin/env bash
# Проверка срока действия всех сертификатов с созданием задач при приближении даты истечения
# Использование: bash check-cert-expiry.sh [warn_days] [critical_days]
set -euo pipefail

WARN_DAYS="${1:-30}"
CRITICAL_DAYS="${2:-7}"
CERT_DIRS="${CERT_DIRS:-/etc/ssl/services /etc/docker/certs.d /opt/harbor/data/cert /etc/gitlab/ssl}"
HARBOR_URL="${HARBOR_URL:-https://harbor.internal.company.local}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.internal.company.local}"
OUTPUT="${CERT_REPORT:-cert-expiry-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0

ok()   { echo "[OK]   $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
crit() { echo "[CRIT] $1"; ((FAIL++)); }

check_cert_file() {
  local file="$1" label="${2:-$1}"
  [ -f "$file" ] || return

  not_after=$(openssl x509 -in "$file" -noout -enddate 2>/dev/null | cut -d= -f2)
  [ -z "$not_after" ] && return

  exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || \
    date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
  days_left=$(( (exp_epoch - $(date +%s)) / 86400 ))

  cn=$(openssl x509 -in "$file" -noout -subject 2>/dev/null | \
    grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo "?")

  if [ "$days_left" -lt 0 ]; then
    crit "ИСТЁК ${days_left#-} дней назад: $label (CN=$cn)"
  elif [ "$days_left" -le "$CRITICAL_DAYS" ]; then
    crit "Критично: $days_left дней — $label (CN=$cn)"
  elif [ "$days_left" -le "$WARN_DAYS" ]; then
    warn "$days_left дней — $label (CN=$cn)"
  else
    ok "$days_left дней — $label"
  fi
}

check_tls_endpoint() {
  local host="$1" port="$2" label="${3:-$1:$2}"
  local cert_pem
  cert_pem=$(echo | openssl s_client -connect "$host:$port" -servername "$host" \
    2>/dev/null | openssl x509 2>/dev/null || echo "")
  [ -z "$cert_pem" ] && { warn "Недоступен: $label"; return; }

  not_after=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || \
    date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
  days_left=$(( (exp_epoch - $(date +%s)) / 86400 ))
  cn=$(echo "$cert_pem" | openssl x509 -noout -subject 2>/dev/null | \
    grep -oP 'CN\s*=\s*\K[^,/]+' | head -1 || echo "?")

  if [ "$days_left" -lt 0 ]; then
    crit "ИСТЁК: $label (CN=$cn)"
  elif [ "$days_left" -le "$CRITICAL_DAYS" ]; then
    crit "Критично: $days_left дней — $label"
  elif [ "$days_left" -le "$WARN_DAYS" ]; then
    warn "$days_left дней — $label"
  else
    ok "$days_left дней — $label"
  fi
}

{
  echo "=== Проверка сертификатов ==="
  echo "Предупреждение: <${WARN_DAYS} дней  |  Критично: <${CRITICAL_DAYS} дней"
  echo "Дата: $(date '+%Y-%m-%d %H:%M')"

  # --- Файлы сертификатов ---
  echo ""
  echo "── Файлы сертификатов ──────────────────────────────────────────────"
  for cert_dir in $CERT_DIRS; do
    [ -d "$cert_dir" ] || continue
    while IFS= read -r cert_file; do
      check_cert_file "$cert_file" "${cert_dir}/$(basename "$cert_file")"
    done < <(find "$cert_dir" -name "*.crt" -o -name "*.pem" -o -name "*.cer" 2>/dev/null | grep -v chain)
  done

  # --- TLS-эндпоинты ---
  echo ""
  echo "── TLS-эндпоинты ───────────────────────────────────────────────────"
  harbor_host=$(echo "$HARBOR_URL" | sed 's|https://||' | cut -d/ -f1)
  vault_host=$(echo "$VAULT_ADDR" | sed 's|https://||' | cut -d: -f1)
  vault_port=$(echo "$VAULT_ADDR" | awk -F: '{print $NF}' | cut -d/ -f1)
  gitlab_host=$(echo "$GITLAB_URL" | sed 's|https://||' | cut -d/ -f1)

  check_tls_endpoint "$harbor_host" 443      "Harbor"
  check_tls_endpoint "$vault_host"  "${vault_port:-8200}" "Vault"
  check_tls_endpoint "$gitlab_host" 443      "GitLab"

  # Docker daemon TLS (если настроен)
  check_tls_endpoint "$(hostname)" 2376 "Docker daemon TLS" 2>/dev/null || true

  # --- Vault PKI ---
  echo ""
  echo "── Vault PKI (CA-сертификаты) ──────────────────────────────────────"
  for pki_path in pki pki_int; do
    ca_cert=$(curl -sf --max-time 5 "$VAULT_ADDR/v1/$pki_path/ca/pem" 2>/dev/null || echo "")
    if [ -n "$ca_cert" ]; then
      tmpf=$(mktemp)
      echo "$ca_cert" > "$tmpf"
      check_cert_file "$tmpf" "Vault PKI CA ($pki_path)"
      rm -f "$tmpf"
    fi
  done

  # --- Итог ---
  echo ""
  echo "=== Итог ==="
  echo "OK: $PASS  WARN: $WARN  CRIT: $FAIL"
  echo ""
  if [ "$FAIL" -gt 0 ]; then
    echo "КРИТИЧЕСКИЕ СЕРТИФИКАТЫ: немедленно обновите через Vault PKI (раздел 7.3)"
    echo "  bash issue-service-cert-vault.sh <сервис>"
  fi
  if [ "$WARN" -gt 0 ]; then
    echo "ПРЕДУПРЕЖДЕНИЯ: обновите в ближайшие дни или убедитесь что Vault-агент работает"
  fi

} | tee "$OUTPUT"

echo ""
echo "Отчёт: $OUTPUT"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
