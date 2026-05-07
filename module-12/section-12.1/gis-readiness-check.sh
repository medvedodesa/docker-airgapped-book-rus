#!/usr/bin/env bash
# Оценка соответствия Docker-инфраструктуры требованиям Приказа №17 для ГИС
# Использование: bash gis-readiness-check.sh [класс: K1|K2|K3] [harbor_url] [vault_addr]
set -euo pipefail

GIS_CLASS="${1:-K2}"
HARBOR_URL="${2:-${HARBOR_URL:-https://harbor.internal.company.local}}"
VAULT_ADDR="${3:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
OUTPUT="${GIS_REPORT:-gis-readiness-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Оценка готовности к аттестации ГИС (Приказ №17) ==="
echo "Класс ГИС:  $GIS_CLASS"
echo "Harbor:     $HARBOR_URL"
echo "Vault:      $VAULT_ADDR"
echo "Дата:       $(date '+%Y-%m-%d %H:%M')"
echo ""
echo "Требования Приказа №17 зависят от класса:"
echo "  К1: максимальный набор мер (сертифицированные СЗИ обязательны)"
echo "  К2: расширенный набор мер"
echo "  К3: базовый набор мер"

# ── Базовые требования (все классы) ──────────────────────────────────────
echo ""
echo "── Базовые требования (К1/К2/К3) ───────────────────────────────────"

# Идентификация и аутентификация
if curl -sf --max-time 5 "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
  auth_mode=$(curl -sf -H "Authorization: Basic $(echo -n "admin:${HARBOR_PASSWORD:-}" | base64)" \
    "$HARBOR_URL/api/v2.0/configurations" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('auth_mode',{}).get('value','?'))" 2>/dev/null || echo "?")
  if [ "$auth_mode" = "ldap_auth" ]; then
    ok "ИАФ: Harbor — аутентификация через LDAP/AD"
  else
    warn "ИАФ: Harbor — локальная аутентификация (для К1/К2 рекомендуется LDAP)"
  fi
else
  warn "Harbor недоступен — пропуск проверок аутентификации"
fi

# Аудит
if [ -n "$VAULT_TOKEN" ]; then
  audit_count=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/sys/audit" 2>/dev/null | \
    python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
  [ "$audit_count" -gt 0 ] && ok "АУД: Vault audit включён" || fail "АУД: Vault audit не настроен"
fi

# Сетевая изоляция
default_ct=$(docker network inspect bridge --format '{{len .Containers}}' 2>/dev/null || echo 0)
[ "${default_ct:-0}" -eq 0 ] && ok "ЗИС.3: Контейнеры не в default bridge" || \
  warn "ЗИС.3: ${default_ct} контейнеров в default bridge"

# Резервное копирование
backup_recent=$(find /var/backups /opt/backups 2>/dev/null -name "*.snap" -o -name "*.sql.gz" | \
  xargs -r stat -c %Y 2>/dev/null | sort -r | head -1)
if [ -n "$backup_recent" ]; then
  age_h=$(( ($(date +%s) - backup_recent) / 3600 ))
  [ "$age_h" -lt 25 ] && ok "ОДТ.1: Резервная копия свежая (${age_h}ч)" || \
    warn "ОДТ.1: Последняя резервная копия ${age_h}ч назад (>24ч)"
else
  fail "ОДТ.1: Резервные копии не найдены"
fi

# ── Требования К2 и К1 ───────────────────────────────────────────────────
if [ "$GIS_CLASS" = "K1" ] || [ "$GIS_CLASS" = "K2" ]; then
  echo ""
  echo "── Дополнительные требования К1/К2 ─────────────────────────────────"

  # Сертифицированный МЭ (Приказ №17 требует сертифицированных СЗИ)
  warn "СЗИ: Убедитесь что периметр защищён сертифицированным МЭ (Континент, ViPNet и т.д.)"

  # Подпись образов
  if command -v cosign &>/dev/null; then
    ok "ЗИС.23: cosign установлен"
  else
    fail "ЗИС.23: cosign не установлен — подпись образов не реализована"
  fi

  # TLS
  harbor_host=$(echo "$HARBOR_URL" | sed 's|https://||' | cut -d/ -f1)
  cert_days=$(echo | openssl s_client -connect "$harbor_host:443" -servername "$harbor_host" \
    2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | \
    cut -d= -f2 | xargs -I{} bash -c 'echo $(( ($(date -d "{}" +%s) - $(date +%s)) / 86400 ))' \
    2>/dev/null || echo 0)
  if [ "${cert_days:-0}" -gt 30 ]; then
    ok "КЗИ.1: TLS-сертификат Harbor действителен ($cert_days дней)"
  else
    fail "КЗИ.1: Сертификат истекает через $cert_days дней"
  fi
fi

# ── Требования только К1 ─────────────────────────────────────────────────
if [ "$GIS_CLASS" = "K1" ]; then
  echo ""
  echo "── Требования только К1 ─────────────────────────────────────────────"

  # СКЗИ (К1 требует сертифицированных СКЗИ для каналов связи)
  if command -v cryptcp &>/dev/null || [ -d /opt/cprocsp ]; then
    ok "СКЗИ: КриптоПро CSP обнаружен"
  else
    fail "СКЗИ: Для К1 требуется сертифицированное СКЗИ (КриптоПро, ViPNet)"
  fi

  # ГосСОПКА для К1 обязательно
  warn "ГосСОПКА: Проверьте подключение к ГосСОПКА (обязательно для К1)"
  warn "ИНЦ: Для К1 — уведомление НКЦКИ в течение 3 часов (задокументируйте процедуру)"
fi

# ── Документация для аттестации ───────────────────────────────────────────
echo ""
echo "── Документация ─────────────────────────────────────────────────────"

# Технический паспорт
if command -v jq &>/dev/null || command -v python3 &>/dev/null; then
  ok "Генерация паспорта: python3 доступен для generate-system-inventory.sh"
else
  warn "python3 не доступен — генерация паспорта ограничена"
fi

# Git-история как документ изменений
if git -C . rev-parse HEAD &>/dev/null 2>&1; then
  commits=$(git log --oneline --since="3 months ago" 2>/dev/null | wc -l)
  ok "Документация изменений: Git-история ($commits коммитов за 3 месяца)"
else
  warn "Конфигурация не под контролем Git — история изменений отсутствует"
fi

# ── Итог ─────────────────────────────────────────────────────────────────
{
  echo ""
  echo "=== Итог: $GIS_CLASS ==="
  echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
  echo ""
  score=$((PASS * 100 / (PASS + WARN + FAIL + 1)))
  if [ "$FAIL" -eq 0 ] && [ "$WARN" -le 2 ]; then
    echo "Готовность: ВЫСОКАЯ — инфраструктура готова к аттестации"
  elif [ "$FAIL" -le 2 ]; then
    echo "Готовность: СРЕДНЯЯ — устраните FAIL до аттестации"
  else
    echo "Готовность: НИЗКАЯ — требуется существенная доработка"
  fi
  echo ""
  echo "Следующие шаги:"
  echo "  1. Устраните все FAIL-пункты"
  echo "  2. Запустите: bash pre-attestation-checklist.sh"
  echo "  3. Сгенерируйте паспорт: bash generate-system-inventory.sh"
  echo "  4. Сформируйте пакет документов: bash attestation-docs-package.sh"
} | tee -a /dev/stderr 2>/dev/null

echo ""
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
