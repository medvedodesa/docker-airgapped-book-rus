#!/usr/bin/env bash
# Отчёт о покрытии mTLS и сроках сертификатов в Docker-инфраструктуре
# Использование: bash mtls-coverage-report.sh [harbor_url] [vault_addr]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-https://harbor.internal.company.local}}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
WARN_DAYS="${CERT_WARN_DAYS:-30}"
OUTPUT="${MTLS_REPORT_OUTPUT:-mtls-coverage-$(date +%Y%m%d).txt}"

echo "=== Отчёт о покрытии mTLS ==="
echo "Дата: $(date '+%Y-%m-%d %H:%M')"

check_cert_expiry() {
  local host="$1" port="$2" label="$3"
  local not_after days_left exp_epoch now_epoch

  not_after=$(echo | openssl s_client -connect "$host:$port" -servername "$host" \
    2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")

  if [ -z "$not_after" ]; then
    echo "   [WARN] $label ($host:$port): TLS недоступен или сертификат не получен"
    return
  fi

  exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || \
    date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (exp_epoch - now_epoch) / 86400 ))

  if [ "$days_left" -lt 0 ]; then
    echo "   [FAIL] $label ($host:$port): сертификат ИСТЁК $((days_left * -1)) дней назад"
  elif [ "$days_left" -lt "$WARN_DAYS" ]; then
    echo "   [WARN] $label ($host:$port): истекает через $days_left дней ($not_after)"
  else
    echo "   [PASS] $label ($host:$port): действителен $days_left дней ($not_after)"
  fi
}

check_mtls_endpoint() {
  local host="$1" port="$2" label="$3"
  local client_cert="${4:-}" client_key="${5:-}" ca_cert="${6:-}"

  if [ -z "$client_cert" ] || [ ! -f "$client_cert" ]; then
    echo "   [SKIP] $label: клиентский сертификат не задан — mTLS не тестируется"
    return
  fi

  if openssl s_client \
      -connect "$host:$port" \
      -cert "$client_cert" \
      -key "$client_key" \
      -CAfile "$ca_cert" \
      -verify_return_error \
      2>/dev/null </dev/null | grep -q "Verify return code: 0"; then
    echo "   [PASS] $label ($host:$port): mTLS взаимная аутентификация успешна"
  else
    echo "   [FAIL] $label ($host:$port): mTLS аутентификация не прошла"
  fi
}

{
  echo "# Отчёт покрытия mTLS"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M')  |  Порог предупреждения: $WARN_DAYS дней"
  echo ""

  # --- Инфраструктурные компоненты ---
  echo "## Инфраструктурные компоненты"
  harbor_host=$(echo "$HARBOR_URL" | sed 's|https://||' | cut -d/ -f1)
  check_cert_expiry "$harbor_host" 443 "Harbor"

  vault_host=$(echo "$VAULT_ADDR" | sed 's|https://||' | cut -d: -f1)
  vault_port=$(echo "$VAULT_ADDR" | sed 's|https://||' | awk -F: '{print $2}' | cut -d/ -f1)
  vault_port="${vault_port:-8200}"
  check_cert_expiry "$vault_host" "$vault_port" "Vault"

  # GitLab (если настроен)
  GITLAB_URL="${GITLAB_URL:-}"
  if [ -n "$GITLAB_URL" ]; then
    gitlab_host=$(echo "$GITLAB_URL" | sed 's|https://||' | cut -d/ -f1)
    check_cert_expiry "$gitlab_host" 443 "GitLab"
  fi

  echo ""

  # --- Сертификаты PKI Vault ---
  echo "## Сертификаты PKI Vault"
  if [ -n "$VAULT_TOKEN" ] && curl -sf --max-time 5 \
      -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then

    # PKI-монтирования
    mounts=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/sys/mounts" 2>/dev/null | python3 -c "
import json,sys
mounts = json.load(sys.stdin)
for path, info in mounts.items():
    if info.get('type') == 'pki':
        print(path.rstrip('/'))
" 2>/dev/null || echo "")

    if [ -n "$mounts" ]; then
      for mount in $mounts; do
        echo "   PKI-монтирование: $mount"
        # CA сертификат
        ca_cert=$(curl -sf "$VAULT_ADDR/v1/$mount/ca/pem" 2>/dev/null || echo "")
        if [ -n "$ca_cert" ]; then
          not_after=$(echo "$ca_cert" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
          exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || echo 0)
          now_epoch=$(date +%s)
          days_left=$(( (exp_epoch - now_epoch) / 86400 ))
          echo "   [INFO] CA ($mount): действителен $days_left дней"
        fi

        # Количество выданных сертификатов
        cert_count=$(curl -sf \
          -H "X-Vault-Token: $VAULT_TOKEN" \
          -X LIST "$VAULT_ADDR/v1/$mount/certs" 2>/dev/null | \
          python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',{}).get('keys',[])))" \
          2>/dev/null || echo "?")
        echo "   [INFO] Выданных сертификатов: $cert_count"
      done
    else
      echo "   [WARN] PKI-монтирования не найдены"
    fi
  else
    echo "   [SKIP] Vault недоступен или VAULT_TOKEN не задан"
  fi
  echo ""

  # --- SPIRE SVID покрытие ---
  echo "## SPIRE: SVID-покрытие рабочих нагрузок"
  AGENT_SOCKET="${SPIRE_AGENT_SOCKET:-/tmp/spire-agent/public/api.sock}"
  if [ -S "$AGENT_SOCKET" ] && command -v spire-agent &>/dev/null; then
    entries=$(spire-agent api fetch x509 -socketPath "$AGENT_SOCKET" 2>/dev/null || echo "")
    if [ -n "$entries" ]; then
      echo "   [PASS] SPIRE Agent активен, SVID выдаются"
    else
      echo "   [WARN] SPIRE Agent доступен, но SVID не получены"
    fi
  else
    echo "   [SKIP] SPIRE Agent не обнаружен (сокет: $AGENT_SOCKET)"
  fi
  echo ""

  # --- Контейнеры: проверка TLS-портов ---
  echo "## Контейнеры: TLS-порты"
  docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | while read -r cname ports; do
    # Ищем HTTPS-порты (443, 8443, 8200 и т.д.)
    https_ports=$(echo "$ports" | grep -oE '0\.0\.0\.0:[0-9]+->443|0\.0\.0\.0:[0-9]+->8443|0\.0\.0\.0:[0-9]+->8200' | \
      grep -oE ':[0-9]+' | tr -d ':' || echo "")
    for port in $https_ports; do
      check_cert_expiry "localhost" "$port" "$cname"
    done
  done
  echo ""

  # --- Итоговая сводка ---
  echo "## Сводка"
  echo "   Порог предупреждения: $WARN_DAYS дней до истечения"
  echo "   Рекомендации:"
  echo "   - Сертификаты [WARN]: обновите в течение $WARN_DAYS дней"
  echo "   - Сертификаты [FAIL]: требуют немедленного обновления"
  echo "   - [SKIP]: настройте автоматическую выдачу через Vault Agent (раздел 7.3)"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
