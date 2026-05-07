#!/usr/bin/env bash
# Проверка доступности CRL-точки Vault PKI для всех клиентов в сети закрытого контура
# Использование: bash check-crl-distribution.sh [vault_addr] [pki_mount] [hosts_file]
set -euo pipefail

VAULT_ADDR="${1:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
PKI_MOUNT="${2:-pki_int}"
HOSTS_FILE="${3:-${HOSTS_FILE:-}}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
TIMEOUT="${CRL_CHECK_TIMEOUT:-5}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Собираем хосты для проверки
if [ -n "$HOSTS_FILE" ] && [ -f "$HOSTS_FILE" ]; then
  mapfile -t CHECK_HOSTS < "$HOSTS_FILE"
elif [ "$#" -gt 3 ]; then
  CHECK_HOSTS=("${@:4}")
else
  CHECK_HOSTS=("localhost")
fi

echo "=== Проверка доступности CRL-точки ==="
echo "Vault PKI:  $VAULT_ADDR / $PKI_MOUNT"
echo "Хосты:      ${CHECK_HOSTS[*]}"
echo "Дата:       $(date '+%Y-%m-%d %H:%M')"

# ── Получение CRL-URL из Vault ────────────────────────────────────────────
echo ""
echo "── CRL-конфигурация Vault ───────────────────────────────────────────────"
if [ -n "$VAULT_TOKEN" ]; then
  config=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/$PKI_MOUNT/config/urls" 2>/dev/null | \
    python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('data',{}), indent=2))" 2>/dev/null || echo "{}")

  crl_urls=$(echo "$config" | python3 -c "
import json,sys
d = json.load(sys.stdin)
crl = d.get('crl_distribution_points',[])
print('\n'.join(crl) if crl else '')
" 2>/dev/null || echo "")

  issuing_certs=$(echo "$config" | python3 -c "
import json,sys
d = json.load(sys.stdin)
ic = d.get('issuing_certificates',[])
print('\n'.join(ic) if ic else '')
" 2>/dev/null || echo "")

  if [ -n "$crl_urls" ]; then
    ok "CRL-точки настроены:"
    echo "$crl_urls" | sed 's/^/    /'
    # Проверяем что URL внутренний
    while IFS= read -r url; do
      if echo "$url" | grep -qE "^https?://[^/]*\.(com|net|org|io|dev)|pki\.g\.hostedtls"; then
        fail "CRL-URL указывает на внешний хост: $url — недопустимо в закрытом контуре"
      fi
    done <<< "$crl_urls"
  else
    fail "CRL-точки не настроены в PKI-механизме $PKI_MOUNT"
    echo "    Настройте: vault write $PKI_MOUNT/config/urls crl_distribution_points=http://vault.internal:8200/v1/$PKI_MOUNT/crl"
  fi

  if [ -n "$issuing_certs" ]; then
    ok "Issuing certificates URL настроен"
  else
    warn "Issuing certificates URL не настроен"
  fi
else
  warn "VAULT_TOKEN не задан — пропуск проверки конфигурации CRL"
  crl_urls="$VAULT_ADDR/v1/$PKI_MOUNT/crl"
fi

# ── Прямая проверка CRL-endpoint ─────────────────────────────────────────
echo ""
echo "── Доступность CRL-endpoint ─────────────────────────────────────────────"
CRL_ENDPOINT="$VAULT_ADDR/v1/$PKI_MOUNT/crl"

check_crl_endpoint() {
  local from_host="$1"
  local crl_url="${2:-$CRL_ENDPOINT}"

  if [ "$from_host" = "localhost" ] || [ "$from_host" = "$(hostname)" ]; then
    # Проверка локально
    response=$(curl -sf --max-time "$TIMEOUT" -o /tmp/crl_check.der "$crl_url" 2>/dev/null && echo "ok" || echo "fail")
    if [ "$response" = "ok" ] && [ -s /tmp/crl_check.der ]; then
      # Парсим CRL
      crl_info=$(openssl crl -inform DER -in /tmp/crl_check.der -noout -text 2>/dev/null | \
        grep -E "Last Update|Next Update|Number of revoked" | head -3 || echo "")
      ok "CRL доступен: $crl_url"
      [ -n "$crl_info" ] && echo "$crl_info" | sed 's/^/    /'
    else
      fail "CRL недоступен: $crl_url"
    fi
    rm -f /tmp/crl_check.der
  else
    # Проверка с удалённого хоста через SSH
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$from_host" \
        "curl -sf --max-time $TIMEOUT '$crl_url' > /dev/null 2>&1" 2>/dev/null; then
      ok "CRL доступен с $from_host: $crl_url"
    else
      fail "CRL недоступен с $from_host: $crl_url — проверьте маршрутизацию и правила firewall"
    fi
  fi
}

check_crl_endpoint "localhost" "$CRL_ENDPOINT"

# ── Проверка с других хостов ─────────────────────────────────────────────
echo ""
echo "── Проверка с клиентских хостов ─────────────────────────────────────────"
for host in "${CHECK_HOSTS[@]}"; do
  [ "$host" = "localhost" ] && continue
  check_crl_endpoint "$host" "$CRL_ENDPOINT"
done

# ── Проверка актуальности CRL ─────────────────────────────────────────────
echo ""
echo "── Актуальность CRL ─────────────────────────────────────────────────────"
crl_der=$(curl -sf --max-time "$TIMEOUT" "$CRL_ENDPOINT" 2>/dev/null || echo "")
if [ -n "$crl_der" ]; then
  crl_next=$(echo "$crl_der" | openssl crl -inform DER -noout -nextupdate 2>/dev/null | cut -d= -f2 || echo "")
  if [ -n "$crl_next" ]; then
    exp_epoch=$(date -d "$crl_next" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$crl_next" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    hours_left=$(( (exp_epoch - now_epoch) / 3600 ))
    if [ "$hours_left" -lt 0 ]; then
      fail "CRL просрочен! Next Update: $crl_next"
    elif [ "$hours_left" -lt 24 ]; then
      warn "CRL обновляется менее чем через $hours_left ч. (Next Update: $crl_next)"
    else
      ok "CRL актуален (Next Update: $crl_next, через $hours_left ч.)"
    fi
  fi
fi

# ── Итог ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
