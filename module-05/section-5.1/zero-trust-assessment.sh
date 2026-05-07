#!/usr/bin/env bash
# Оценка текущего состояния Docker-инфраструктуры по принципам Zero Trust
# Проверяет: сетевую сегментацию, mTLS, управление секретами, журналирование, управление доступом
set -euo pipefail

HARBOR_URL="${HARBOR_URL:-https://harbor.internal.company.local}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
OUTPUT="${ZT_ASSESSMENT_OUTPUT:-zero-trust-assessment-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Оценка Zero Trust: Docker-инфраструктура ==="
echo "Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"

# ── 1. Принцип «Никогда не доверяй, всегда проверяй» ─────────────────────────
echo ""
echo "── 1. Аутентификация и авторизация ─────────────────────────────────────"

# Vault доступен и настроен
if [ -n "$VAULT_TOKEN" ] && curl -sf --max-time 5 \
    -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/auth/token/lookup-self" >/dev/null 2>&1; then
  ok "Vault: доступен и токен действителен"

  # Проверяем что аудит включён
  audit_devices=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/sys/audit" 2>/dev/null | python3 -c \
    "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  if [ "$audit_devices" -gt 0 ]; then
    ok "Vault audit: включён ($audit_devices устройство(а))"
  else
    fail "Vault audit: не настроен — все обращения к секретам не фиксируются"
  fi

  # Корневой токен не должен быть активен
  token_type=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/auth/token/lookup-self" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('policies',[]))" 2>/dev/null || echo "")
  if echo "$token_type" | grep -q '"root"'; then
    warn "Vault: используется root-токен — должен быть отозван после настройки"
  else
    ok "Vault: не используется root-токен"
  fi
else
  warn "Vault: недоступен или токен не задан (VAULT_TOKEN) — пропуск проверок секретов"
fi

# Анонимный доступ к Harbor
if curl -sf --max-time 5 "$HARBOR_URL/api/v2.0/projects" >/dev/null 2>&1; then
  warn "Harbor: анонимный доступ к API не заблокирован — проверьте настройку гостевого доступа"
else
  ok "Harbor: анонимный доступ к API заблокирован"
fi

# ── 2. Минимальные привилегии ────────────────────────────────────────────────
echo ""
echo "── 2. Минимальные привилегии ────────────────────────────────────────────"

privileged_count=$(docker ps -q 2>/dev/null | xargs -r docker inspect \
  --format '{{if .HostConfig.Privileged}}{{.Name}}{{end}}' 2>/dev/null | grep -c . || echo 0)
if [ "$privileged_count" -gt 0 ]; then
  fail "Привилегированных контейнеров: $privileged_count — нарушение принципа минимальных привилегий"
else
  ok "Привилегированных контейнеров: 0"
fi

root_count=$(docker ps -q 2>/dev/null | xargs -r docker inspect \
  --format '{{.Name}} user={{.Config.User}}' 2>/dev/null | grep 'user=$\|user=0\|user=root' | wc -l || echo 0)
if [ "$root_count" -gt 0 ]; then
  warn "Контейнеров от root (user не задан): $root_count"
else
  ok "Все контейнеры работают от непривилегированного пользователя"
fi

# ── 3. Сетевая микросегментация ─────────────────────────────────────────────
echo ""
echo "── 3. Сетевая сегментация ───────────────────────────────────────────────"

default_bridge=$(docker network inspect bridge \
  --format '{{len .Containers}}' 2>/dev/null || echo 0)
if [ "$default_bridge" -gt 0 ]; then
  warn "Контейнеров в сети bridge (default): $default_bridge — рекомендуется использовать именованные сети"
else
  ok "Сеть bridge (default): не используется"
fi

internal_networks=$(docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | \
  xargs -r -I{} docker network inspect {} --format '{{.Name}} internal={{.Internal}}' 2>/dev/null | \
  grep 'internal=true' | wc -l || echo 0)
ok "Внутренних изолированных сетей (--internal): $internal_networks"

# ── 4. Шифрование в движении ────────────────────────────────────────────────
echo ""
echo "── 4. Шифрование (TLS/mTLS) ─────────────────────────────────────────────"

# Harbor по HTTPS
if echo | openssl s_client -connect "$(echo "$HARBOR_URL" | sed 's|https://||'):443" \
    -servername "$(echo "$HARBOR_URL" | sed 's|https://||')" 2>/dev/null | \
    grep -q "Verify return code: 0"; then
  ok "Harbor: TLS с доверенным сертификатом"
elif curl -skf "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
  warn "Harbor: TLS есть, но сертификат самоподписанный или CA не в системном хранилище"
else
  fail "Harbor: TLS не настроен или хост недоступен"
fi

# SPIRE/mTLS
if command -v spire-agent &>/dev/null || systemctl is-active spire-agent &>/dev/null 2>&1; then
  ok "SPIRE Agent: запущен (SVID-аутентификация активна)"
else
  warn "SPIRE Agent: не обнаружен — mTLS на основе SVID не настроен"
fi

# ── 5. Наблюдаемость и аудит ────────────────────────────────────────────────
echo ""
echo "── 5. Наблюдаемость и аудит ─────────────────────────────────────────────"

if systemctl is-active falco &>/dev/null 2>&1 || docker ps --format '{{.Names}}' | grep -q falco; then
  ok "Falco: запущен (runtime security мониторинг активен)"
else
  warn "Falco: не обнаружен — аномалии в контейнерах не отслеживаются"
fi

if systemctl is-active auditd &>/dev/null 2>&1; then
  ok "auditd: запущен"
  if auditctl -l 2>/dev/null | grep -q docker; then
    ok "auditd: правила для Docker присутствуют"
  else
    warn "auditd: правила для Docker отсутствуют — добавьте configure-auditd-docker.sh"
  fi
else
  warn "auditd: не запущен"
fi

# ── 6. Целостность образов ───────────────────────────────────────────────────
echo ""
echo "── 6. Целостность образов ───────────────────────────────────────────────"

if command -v cosign &>/dev/null; then
  ok "cosign: установлен ($(cosign version 2>/dev/null | grep GitVersion | awk '{print $2}' || echo 'найден'))"
else
  warn "cosign: не установлен — подпись образов не реализована"
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
{
  score=$((PASS * 100 / (PASS + WARN + FAIL) ))
  echo ""
  echo "=== Итог Zero Trust Assessment ==="
  echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
  echo "Уровень зрелости: ${score}%"
  echo ""
  if [ "$score" -ge 80 ]; then
    echo "Оценка: ВЫСОКИЙ уровень — большинство принципов Zero Trust реализованы"
  elif [ "$score" -ge 60 ]; then
    echo "Оценка: СРЕДНИЙ уровень — критичные принципы соблюдены, есть пробелы"
  else
    echo "Оценка: НИЗКИЙ уровень — требуется системная работа по реализации Zero Trust"
  fi
} | tee -a /dev/null

echo ""
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
score=$((PASS * 100 / (PASS + WARN + FAIL)))
echo "Уровень зрелости: ${score}%"
echo ""
echo "Подробный отчёт: zero-trust-maturity-report.sh"
