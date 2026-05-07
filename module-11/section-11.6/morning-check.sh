#!/usr/bin/env bash
# Утренняя проверка состояния инфраструктуры
# Использование: bash morning-check.sh [--send-report]
set -euo pipefail

SEND_REPORT="${1:-}"
REPORT_EMAIL="${REPORT_EMAIL:-ops@company.local}"
PASS=0; WARN=0; FAIL=0
REPORT=""

ok()   { echo "  [PASS] $1"; REPORT+="✓ $1\n"; ((PASS++)); }
warn() { echo "  [WARN] $1"; REPORT+="⚠ $1\n"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; REPORT+="✗ $1\n"; ((FAIL++)); }

echo "=== Утренняя проверка: $(date '+%Y-%m-%d %H:%M') ==="

# Docker daemon
echo ""
echo "--- Docker ---"
systemctl is-active docker &>/dev/null && ok "Docker daemon запущен" || fail "Docker daemon не запущен"
docker info &>/dev/null && ok "Docker API отвечает" || fail "Docker API недоступен"

# Swarm
echo ""
echo "--- Docker Swarm ---"
if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
  ok "Swarm активен"
  unavail=$(docker node ls 2>/dev/null | grep -v "Ready" | grep -v "Status" | wc -l)
  [ "$unavail" -eq 0 ] && ok "Все узлы Swarm готовы" || warn "$unavail узел(а) недоступны"
else
  echo "  [SKIP] Swarm не используется"
fi

# Сервисы
echo ""
echo "--- Контейнеры ---"
total=$(docker ps -q 2>/dev/null | wc -l)
restarting=$(docker ps --filter "status=restarting" -q 2>/dev/null | wc -l)
ok "Запущено контейнеров: $total"
[ "$restarting" -eq 0 ] && ok "Нет перезапускающихся контейнеров" || \
  fail "$restarting контейнер(а) в состоянии restarting"

# Диск
echo ""
echo "--- Диск ---"
while IFS= read -r line; do
  usage=$(echo "$line" | awk '{print $5}' | tr -d '%')
  mount=$(echo "$line" | awk '{print $6}')
  [ "$usage" -ge 90 ] && fail "Диск $mount: $usage%" && continue
  [ "$usage" -ge 75 ] && warn "Диск $mount: $usage%" && continue
  ok "Диск $mount: $usage%"
done < <(df -h / /var/lib/docker 2>/dev/null | tail -n +2)

# Harbor
echo ""
echo "--- Harbor ---"
harbor_code=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 5 \
  "https://harbor.internal.company.local/api/v2.0/systeminfo" \
  --insecure 2>/dev/null || echo "000")
[ "$harbor_code" = "200" ] && ok "Harbor доступен" || warn "Harbor: HTTP $harbor_code"

# Vault
echo ""
echo "--- Vault ---"
if command -v vault &>/dev/null; then
  sealed=$(vault status -format=json 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "true")
  [ "$sealed" = "False" ] && ok "Vault не запечатан" || warn "Vault запечатан или недоступен"
fi

# Сертификаты
echo ""
echo "--- Сертификаты ---"
for cert in /etc/harbor/ssl/*.crt /etc/vault.d/tls/*.crt /etc/ssl/internal/*.crt; do
  [ -f "$cert" ] || continue
  days=$(( ($(date -d "$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)" +%s) - $(date +%s)) / 86400 )) 2>/dev/null || continue
  name=$(basename "$cert")
  [ "$days" -lt 14 ] && fail "Сертификат $name: истекает через $days дней" && continue
  [ "$days" -lt 30 ] && warn "Сертификат $name: истекает через $days дней" && continue
  ok "Сертификат $name: $days дней"
done

# Итог
echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="

# Отправка отчёта
if [ "$SEND_REPORT" = "--send-report" ] && command -v mail &>/dev/null; then
  subject="[$([ $FAIL -gt 0 ] && echo 'FAIL' || ([ $WARN -gt 0 ] && echo 'WARN' || echo 'OK'))] Утренняя проверка $(hostname) $(date +%Y-%m-%d)"
  printf "%b" "$REPORT\n\nPASS=$PASS WARN=$WARN FAIL=$FAIL" | \
    mail -s "$subject" "$REPORT_EMAIL" 2>/dev/null && \
    echo "Отчёт отправлен на $REPORT_EMAIL" || true
fi

[ "$FAIL" -eq 0 ] || exit 1
