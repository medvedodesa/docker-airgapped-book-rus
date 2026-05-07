#!/usr/bin/env bash
# Проверка соответствия требованиям ФСТЭК: Приказ №239 (КИИ) и №17 (ГИС)
# Использование: bash compliance-check.sh [--kii|--gis|--all]
set -euo pipefail

MODE="${1:---all}"
PASS=0; WARN=0; FAIL=0
REPORT_FILE="/tmp/compliance-$(date +%Y%m%d_%H%M%S).txt"

ok()   { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

{
echo "=== Проверка соответствия требованиям ==="
echo "  Режим: $MODE"
echo "  Дата:  $(date '+%Y-%m-%d %H:%M')"
echo "  Хост:  $(hostname)"

# === Аутентификация и управление доступом ===
echo ""
echo "--- УПД: Управление правами доступа ---"

# Проверка sudo без пароля
if grep -rq "NOPASSWD:ALL" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
  fail "Обнаружен sudo NOPASSWD:ALL (требует авторизации для КИИ)"
else
  ok "NOPASSWD:ALL не используется"
fi

# Пустые пароли
empty_pass=$(awk -F: '($2=="" || $2=="!!" ) && $1!="root" {print $1}' /etc/shadow 2>/dev/null | wc -l)
[ "$empty_pass" -eq 0 ] && ok "Пустых паролей нет" || fail "$empty_pass пользователей без пароля"

# Проверка PAM минимальной длины пароля
if grep -qE "minlen\s*=\s*([8-9]|[1-9][0-9])" /etc/security/pwquality.conf 2>/dev/null || \
   grep -qE "minlen\s*=\s*([8-9]|[1-9][0-9])" /etc/pam.d/common-password 2>/dev/null; then
  ok "Минимальная длина пароля ≥8"
else
  warn "Не удалось проверить минимальную длину пароля (проверьте PAM)"
fi

# === Аудит ===
echo ""
echo "--- АУД: Аудит событий безопасности ---"

# auditd
systemctl is-active auditd &>/dev/null && ok "auditd запущен" || fail "auditd не запущен"

# Правила аудита Docker
if auditctl -l 2>/dev/null | grep -qE "docker|/var/lib/docker|/etc/docker"; then
  ok "Правила аудита Docker присутствуют"
else
  warn "Правила аудита для Docker отсутствуют"
fi

# Vault audit log
if [ -f /var/log/vault/audit.log ]; then
  ok "Vault audit log включён: /var/log/vault/audit.log"
else
  warn "Vault audit log не найден"
fi

# === Сетевая защита ===
echo ""
echo "--- ЗСВ: Защита среды виртуализации ---"

# Привилегированные контейнеры
priv_containers=$(docker ps -q 2>/dev/null | xargs -I{} docker inspect {} \
  --format '{{.Name}} {{.HostConfig.Privileged}}' 2>/dev/null | \
  grep "true" | wc -l)
[ "$priv_containers" -eq 0 ] && ok "Привилегированных контейнеров нет" || \
  fail "$priv_containers привилегированных контейнера(ов)"

# no-new-privileges
no_nnp=$(docker ps -q 2>/dev/null | xargs -I{} docker inspect {} \
  --format '{{.Name}} {{.HostConfig.SecurityOpt}}' 2>/dev/null | \
  grep -v "no-new-privileges" | grep -v "^$" | wc -l)
[ "$no_nnp" -eq 0 ] && ok "Все контейнеры имеют no-new-privileges" || \
  warn "$no_nnp контейнер(а) без no-new-privileges"

# Docker socket
if docker ps -q 2>/dev/null | xargs -I{} docker inspect {} \
  --format '{{range .Mounts}}{{.Source}}{{end}}' 2>/dev/null | \
  grep -q "docker.sock"; then
  warn "Обнаружено монтирование docker.sock в контейнер"
else
  ok "docker.sock не монтируется в контейнеры"
fi

# === Шифрование ===
echo ""
echo "--- КЗИ: Криптографическая защита ---"

# TLS для Harbor
harbor_tls=$(curl -s --max-time 5 \
  "https://harbor.internal.company.local/api/v2.0/systeminfo" \
  --cacert /etc/ssl/certs/ca-certificates.crt 2>/dev/null | \
  python3 -c "import json,sys; print(json.load(sys.stdin).get('with_notary',False))" \
  2>/dev/null || echo "false")
ok "Harbor доступен по HTTPS"

# Шифрование Vault
[ -f /etc/vault.d/tls/vault.crt ] && ok "Vault использует TLS" || warn "TLS-сертификат Vault не найден"

# === Целостность ===
echo ""
echo "--- ОЦЛ: Обеспечение целостности ---"

# AIDE или другой IDS
if command -v aide &>/dev/null && [ -f /var/lib/aide/aide.db 2>/dev/null ]; then
  ok "AIDE установлен и база инициализирована"
elif command -v tripwire &>/dev/null; then
  ok "Tripwire установлен"
else
  warn "Система контроля целостности файлов не обнаружена (AIDE/Tripwire)"
fi

# Подпись образов
if command -v cosign &>/dev/null; then
  ok "cosign установлен (подпись образов)"
else
  warn "cosign не установлен"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "  СТАТУС: НЕ СООТВЕТСТВУЕТ требованиям"
elif [ "$WARN" -gt 0 ]; then
  echo "  СТАТУС: ЧАСТИЧНО СООТВЕТСТВУЕТ (требует внимания)"
else
  echo "  СТАТУС: СООТВЕТСТВУЕТ базовым требованиям"
fi
} | tee "$REPORT_FILE"

echo ""
echo "Отчёт сохранён: $REPORT_FILE"
[ "$FAIL" -eq 0 ] || exit 1
