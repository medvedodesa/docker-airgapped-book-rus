#!/usr/bin/env bash
# Автоматическая сборка пакета документов для аттестации из текущего состояния системы
# Использование: bash attestation-docs-package.sh [output_dir] [harbor_url] [vault_addr]
set -euo pipefail

OUTPUT_DIR="${1:-./attestation-package-$(date +%Y%m%d)}"
HARBOR_URL="${2:-${HARBOR_URL:-https://harbor.internal.company.local}}"
VAULT_ADDR="${3:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
SYSTEM_NAME="${SYSTEM_NAME:-Docker-инфраструктура закрытого контура}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Сборка пакета аттестационных документов ==="
echo "Система:      $SYSTEM_NAME"
echo "Harbor:       $HARBOR_URL"
echo "Директория:   $OUTPUT_DIR"
echo "Дата:         $(date '+%Y-%m-%d %H:%M')"

mkdir -p "$OUTPUT_DIR"/{inventory,network,compliance,logs,certs}
REPORT_DATE=$(date '+%Y-%m-%d %H:%M')

# ── 1. Технический паспорт ────────────────────────────────────────────────
echo ""
echo "── 1. Технический паспорт ───────────────────────────────────────────"
PASSPORT="$OUTPUT_DIR/inventory/technical-passport.md"
{
  echo "# Технический паспорт"
  echo "# Система: $SYSTEM_NAME"
  echo "# Дата: $REPORT_DATE"
  echo ""
  echo "## Хосты"
  hostname && echo "ОС: $(. /etc/os-release && echo "$PRETTY_NAME")" && \
    echo "Ядро: $(uname -r)" && \
    echo "Архитектура: $(uname -m)"
  echo ""
  echo "## Docker"
  docker version --format 'Версия: {{.Server.Version}}  API: {{.Server.APIVersion}}' 2>/dev/null || echo "Недоступен"
  echo ""
  echo "## Контейнеры (запущенные)"
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null
  echo ""
  echo "## Docker-сети"
  docker network ls --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}' 2>/dev/null
  echo ""
  echo "## Образы в Harbor"
  if curl -sf --max-time 10 "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
    echo "Доступен: $HARBOR_URL"
  else
    echo "Harbor недоступен при генерации паспорта"
  fi
} > "$PASSPORT" 2>/dev/null
ok "Технический паспорт: $PASSPORT"

# Генерация полного паспорта если скрипт есть
SCRIPT_DIR="$(dirname "$0")"
if [ -f "$SCRIPT_DIR/generate-system-inventory.sh" ]; then
  bash "$SCRIPT_DIR/generate-system-inventory.sh" "$HARBOR_URL" \
    > "$OUTPUT_DIR/inventory/system-inventory-full.md" 2>/dev/null && \
    ok "Полный инвентарь: system-inventory-full.md" || \
    warn "Генерация полного инвентаря не завершена"
fi

# ── 2. Схема сети ─────────────────────────────────────────────────────────
echo ""
echo "── 2. Сетевая конфигурация ─────────────────────────────────────────"
NETWORK_DOC="$OUTPUT_DIR/network/network-config.md"
{
  echo "# Сетевая конфигурация"
  echo "# Дата: $REPORT_DATE"
  echo ""
  echo "## Docker-сети"
  docker network ls 2>/dev/null
  echo ""
  echo "## Детали сетей"
  docker network ls -q 2>/dev/null | while read -r nid; do
    docker network inspect "$nid" --format \
      '{{.Name}} subnet={{range .IPAM.Config}}{{.Subnet}}{{end}} internal={{.Internal}} containers={{len .Containers}}' \
      2>/dev/null
  done
  echo ""
  echo "## Правила iptables (DOCKER-USER)"
  iptables -L DOCKER-USER --line-numbers 2>/dev/null || echo "(нет доступа или не настроено)"
  echo ""
  echo "## Открытые порты"
  ss -tlnp 2>/dev/null | grep -v "^Netid" | head -30
} > "$NETWORK_DOC" 2>/dev/null
ok "Сетевая конфигурация: $NETWORK_DOC"

# ── 3. Матрица соответствия ───────────────────────────────────────────────
echo ""
echo "── 3. Проверка соответствия (Приказ №239) ──────────────────────────"
COMPLIANCE_REPORT="$OUTPUT_DIR/compliance/compliance-report.txt"
if [ -f "$SCRIPT_DIR/compliance-check.sh" ]; then
  bash "$SCRIPT_DIR/compliance-check.sh" "$HARBOR_URL" "$VAULT_ADDR" \
    > "$COMPLIANCE_REPORT" 2>&1 && ok "Отчёт соответствия создан" || \
    warn "Compliance-check завершился с предупреждениями"
fi
# Копируем матрицу соответствия
[ -f "$SCRIPT_DIR/compliance-matrix.md" ] && \
  cp "$SCRIPT_DIR/compliance-matrix.md" "$OUTPUT_DIR/compliance/" && \
  ok "Матрица соответствия скопирована"

# ── 4. Состояние журналов аудита ──────────────────────────────────────────
echo ""
echo "── 4. Журналы аудита ───────────────────────────────────────────────"
AUDIT_STATUS="$OUTPUT_DIR/logs/audit-status.md"
{
  echo "# Статус журналов аудита"
  echo "# Дата: $REPORT_DATE"
  echo ""
  echo "## Vault audit"
  if [ -n "$VAULT_TOKEN" ]; then
    curl -sf -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/audit" 2>/dev/null | \
      python3 -m json.tool 2>/dev/null || echo "Недоступен (проверьте VAULT_TOKEN)"
  else
    echo "VAULT_TOKEN не задан — проверьте вручную: vault audit list"
  fi
  echo ""
  echo "## GitLab audit"
  echo "  Доступен через GitLab Admin → Журналы аудита"
  echo ""
  echo "## Docker daemon journald"
  journalctl -u docker --since "7 days ago" --no-pager 2>/dev/null | \
    grep -i "error\|warning" | tail -10 || echo "(journald недоступен)"
} > "$AUDIT_STATUS" 2>/dev/null
ok "Статус журналов: $AUDIT_STATUS"

# ── 5. Сертификаты ────────────────────────────────────────────────────────
echo ""
echo "── 5. Сертификаты ──────────────────────────────────────────────────"
CERT_REPORT="$OUTPUT_DIR/certs/certificates.md"
{
  echo "# Сертификаты системы"
  echo "# Дата: $REPORT_DATE"
  echo ""
  echo "## TLS-эндпоинты"
  for endpoint in "$HARBOR_URL" "$VAULT_ADDR"; do
    host=$(echo "$endpoint" | sed 's|https\?://||' | cut -d: -f1)
    port=$(echo "$endpoint" | awk -F: '{print $NF}' | cut -d/ -f1)
    not_after=$(echo | openssl s_client -connect "$host:${port:-443}" -servername "$host" \
      2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || echo "недоступен")
    echo "  $endpoint: $not_after"
  done
  echo ""
  echo "## Файлы сертификатов"
  find /etc/ssl /opt/harbor/data/cert /etc/gitlab/ssl 2>/dev/null \
    -name "*.crt" -o -name "*.pem" | while read -r cert; do
    not_after=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "?")
    echo "  $cert: $not_after"
  done
} > "$CERT_REPORT" 2>/dev/null
ok "Отчёт по сертификатам: $CERT_REPORT"

# ── 6. Создание архива ────────────────────────────────────────────────────
echo ""
echo "── 6. Архивирование ────────────────────────────────────────────────"
ARCHIVE="${OUTPUT_DIR}.tar.gz"
tar czf "$ARCHIVE" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")" 2>/dev/null && \
  ok "Пакет архивирован: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))" || \
  warn "Архивирование не удалось"

# ── Итог ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Пакет документов: $OUTPUT_DIR/"
echo "Архив:            $ARCHIVE"
echo ""
echo "Содержимое:"
find "$OUTPUT_DIR" -type f | sort | sed "s|$OUTPUT_DIR/||"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
