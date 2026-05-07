#!/usr/bin/env bash
# Чеклист подготовки к аттестации ИС по требованиям ФСТЭК (17, 21, 239)
# Использование: bash pre-attestation-checklist.sh [приказ]
set -euo pipefail

ORDER="${1:-239}"   # 17 (ГИС), 21 (ПДн), 239 (КИИ)
PASS=0; WARN=0; FAIL=0
REPORT="/tmp/attestation-checklist-$(date +%Y%m%d).txt"

ok()   { echo "  [ДА]  $1"; ((PASS++)); }
warn() { echo "  [???] $1"; ((WARN++)); }
fail() { echo "  [НЕТ] $1"; ((FAIL++)); }

{
echo "=== Чеклист подготовки к аттестации ==="
echo "  Приказ ФСТЭК: №$ORDER"
echo "  Дата: $(date '+%Y-%m-%d')"
echo "  Система: $(hostname)"
echo ""

# === Техническая документация ===
echo "--- Документация (ОРД) ---"

for doc_type in \
  "Модель угроз безопасности:/opt/attestation/threat-model.pdf" \
  "Модель нарушителя:/opt/attestation/intruder-model.pdf" \
  "Техническое задание на ИС:/opt/attestation/technical-spec.pdf" \
  "Техническое задание на СОИБ:/opt/attestation/soib-spec.pdf" \
  "Проектная документация:/opt/attestation/design-docs.pdf" \
  "Эксплуатационная документация:/opt/attestation/operation-docs.pdf" \
  "Организационно-распорядительная документация:/opt/attestation/ord/"; do
  name=$(echo "$doc_type" | cut -d: -f1)
  path=$(echo "$doc_type" | cut -d: -f2)
  [ -e "$path" ] && ok "$name" || fail "$name ($path)"
done

# === Технические меры ===
echo ""
echo "--- Технические меры защиты ---"

# Идентификация и аутентификация (ИАФ)
echo ""
echo "  ИАФ (Идентификация и аутентификация):"
grep -qrE "two_factor|2fa|mfa" /etc/gitlab/gitlab.rb 2>/dev/null && \
  ok "  GitLab: многофакторная аутентификация" || \
  warn "  GitLab: MFA не подтверждена"

command -v vault &>/dev/null && ok "  Vault: централизованное управление доступом" || \
  warn "  Vault не установлен"

# Управление доступом (УПД)
echo ""
echo "  УПД (Управление правами доступа):"
[ -f /etc/audit/audit.rules ] && ok "  Правила аудита доступа настроены" || fail "  Файл audit.rules отсутствует"

# Ограничение программной среды (ОПС)
echo ""
echo "  ОПС (Ограничение программной среды):"
priv=$(docker ps -q 2>/dev/null | xargs -I{} docker inspect {} --format '{{.HostConfig.Privileged}}' 2>/dev/null | grep true | wc -l)
[ "$priv" -eq 0 ] && ok "  Нет привилегированных контейнеров" || fail "  $priv привилегированных контейнеров"

command -v cosign &>/dev/null && ok "  Подпись образов (cosign)" || warn "  cosign не установлен"

# Защита от НСД (ЗСВ)
echo ""
echo "  ЗСВ (Защита виртуальной инфраструктуры):"
systemctl is-active falco &>/dev/null && ok "  Falco (обнаружение аномалий) запущен" || warn "  Falco не запущен"
systemctl is-active auditd &>/dev/null && ok "  auditd запущен" || fail "  auditd не запущен"

# Криптографическая защита
echo ""
echo "  КЗИ (Криптографическая защита):"
command -v cryptcp &>/dev/null && ok "  КриптоПро CSP установлен" || warn "  КриптоПро CSP не обнаружен"
[ -f /etc/vault.d/tls/vault.crt ] && ok "  Vault использует TLS" || warn "  TLS Vault: не проверен"

# === Организационные меры ===
echo ""
echo "--- Организационные меры ---"

for doc in \
  "Политика ИБ:/etc/security/security-policy.pdf" \
  "Инструкция администратора безопасности:/opt/docs/admin-security-guide.pdf" \
  "Инструкция пользователя:/opt/docs/user-security-guide.pdf" \
  "Журнал учёта ОРД:/opt/docs/document-register.xlsx" \
  "План обеспечения непрерывности:/opt/docs/continuity-plan.pdf"; do
  name=$(echo "$doc" | cut -d: -f1)
  path=$(echo "$doc" | cut -d: -f2)
  [ -f "$path" ] && ok "$name" || fail "$name"
done

echo ""
echo "=== Итог: ДА=$PASS  ???=$WARN  НЕТ=$FAIL ==="
echo ""
readiness=$(( PASS * 100 / (PASS + WARN + FAIL) ))
echo "  Готовность к аттестации: ~${readiness}%"
echo ""
if [ "$FAIL" -gt 5 ]; then
  echo "  СТАТУС: НЕ ГОТОВО — устраните критические замечания"
elif [ "$FAIL" -gt 0 ] || [ "$WARN" -gt 5 ]; then
  echo "  СТАТУС: ТРЕБУЕТ ДОРАБОТКИ"
else
  echo "  СТАТУС: ГОТОВО к предъявлению на аттестацию"
fi
} | tee "$REPORT"

echo ""
echo "Отчёт сохранён: $REPORT"
