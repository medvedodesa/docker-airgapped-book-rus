#!/usr/bin/env bash
# Проверка готовности к передаче данных в ГосСОПКА
# Использование: bash gossopka-readiness-check.sh [loki_url] [vault_addr] [категория_КИИ]
set -euo pipefail

LOKI_URL="${1:-${LOKI_URL:-http://loki.internal:3100}}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
KII_CATEGORY="${3:-1}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
OUTPUT="${GOSSOPKA_REPORT:-gossopka-readiness-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка готовности к ГосСОПКА ==="
echo "КИИ категория: $KII_CATEGORY"
echo "Loki:          $LOKI_URL"
echo "Vault:         $VAULT_ADDR"
echo "Дата:          $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Отчёт готовности к ГосСОПКА"
  echo "# Категория КИИ: $KII_CATEGORY  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  # ── 1. Регуляторные требования по категории ───────────────────────────
  echo "## 1. Регуляторные требования"
  case "$KII_CATEGORY" in
    1)
      echo "  КИИ 1 категории: подключение к ГосСОПКА ОБЯЗАТЕЛЬНО (187-ФЗ ст.9 п.2)"
      echo "  Срок уведомления НКЦКИ об инцидентах: 3 часа"
      ;;
    2)
      echo "  КИИ 2 категории: подключение к ГосСОПКА ОБЯЗАТЕЛЬНО"
      echo "  Срок уведомления НКЦКИ об инцидентах: 24 часа"
      ;;
    3)
      echo "  КИИ 3 категории: подключение к ГосСОПКА РЕКОМЕНДОВАНО"
      echo "  Срок уведомления НКЦКИ об инцидентах: 3 суток"
      ;;
  esac
  echo ""

  # ── 2. Техническая интеграция ─────────────────────────────────────────
  echo "## 2. Техническая интеграция"

  # Loki доступен
  if curl -sf --max-time 5 "$LOKI_URL/ready" 2>/dev/null | grep -q "ready"; then
    ok "Loki доступен: $LOKI_URL"
  else
    fail "Loki недоступен — агрегация событий не работает"
  fi

  # Потоки из всех источников
  for source in falco vault gitlab auditd docker; do
    count=$(curl -sf --max-time 10 -G "$LOKI_URL/loki/api/v1/query" \
      --data-urlencode "query=count_over_time({job=\"$source\"}[24h])" 2>/dev/null | \
      python3 -c "
import json,sys
d = json.load(sys.stdin)
results = d.get('data',{}).get('result',[])
total = sum(int(r['value'][1]) for r in results if r.get('value'))
print(total)
" 2>/dev/null || echo 0)
    if [ "${count:-0}" -gt 0 ]; then
      ok "Источник журналов '$source': $count событий за 24ч"
    else
      warn "Источник '$source': нет событий за 24ч — возможно не настроен"
    fi
  done
  echo ""

  # Экспорт в ГосСОПКА
  echo "## 3. Экспорт событий в ГосСОПКА"
  GOSSOPKA_ENDPOINT="${GOSSOPKA_ENDPOINT:-}"
  if [ -n "$GOSSOPKA_ENDPOINT" ]; then
    if curl -sf --max-time 10 "$GOSSOPKA_ENDPOINT/ping" >/dev/null 2>&1; then
      ok "Агент/эндпоинт ГосСОПКА доступен: $GOSSOPKA_ENDPOINT"
    else
      fail "Агент ГосСОПКА недоступен: $GOSSOPKA_ENDPOINT"
    fi
  else
    warn "GOSSOPKA_ENDPOINT не настроен — задайте переменную окружения"
    echo "    Запустите setup-gossopka-integration.sh для настройки экспорта"
  fi
  echo ""

  # ── 3. Документация процедур ──────────────────────────────────────────
  echo "## 4. Документация и процедуры"

  # Процедура уведомления
  RESPONSE_CHECKLIST="$(dirname "$0")/incident-response-checklist.sh"
  if [ -f "$RESPONSE_CHECKLIST" ]; then
    ok "Чек-лист реагирования: $RESPONSE_CHECKLIST"
  else
    fail "Чек-лист реагирования не найден"
  fi

  # Форма уведомления
  NKCI_TEMPLATE="$(dirname "$0")/incident-report-nkci.md"
  if [ -f "$NKCI_TEMPLATE" ]; then
    ok "Форма уведомления НКЦКИ: $NKCI_TEMPLATE"
  else
    fail "Форма уведомления НКЦКИ не найдена"
  fi

  # Ответственный за уведомление
  NKCI_RESPONSIBLE="${NKCI_RESPONSIBLE:-}"
  if [ -n "$NKCI_RESPONSIBLE" ]; then
    ok "Ответственный за уведомление: $NKCI_RESPONSIBLE"
  else
    warn "NKCI_RESPONSIBLE не задан — укажите ответственного в переменной окружения"
  fi

  # Контакты НКЦКИ
  echo "  Контакты НКЦКИ:"
  echo "    Горячая линия: +7 (800) 555-07-05"
  echo "    E-mail: incident@cert.gov.ru"
  echo "    Портал: https://cert.gov.ru"
  echo ""

  # ── 4. Vault audit для ГосСОПКА ───────────────────────────────────────
  echo "## 5. Vault: журналы для ГосСОПКА"
  if [ -n "$VAULT_TOKEN" ]; then
    audit_devices=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/sys/audit" 2>/dev/null | \
      python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    if [ "${audit_devices:-0}" -gt 0 ]; then
      ok "Vault audit включён ($audit_devices устройств)"
    else
      fail "Vault audit не настроен — события не передаются в Loki"
    fi
  else
    warn "VAULT_TOKEN не задан — пропуск проверки Vault audit"
  fi
  echo ""

  # ── 5. Тест сбора криминалистических данных ───────────────────────────
  echo "## 6. Криминалистика"
  FORENSICS_SCRIPT="$(dirname "$0")/collect-forensics.sh"
  if [ -f "$FORENSICS_SCRIPT" ]; then
    ok "Скрипт криминалистики: $FORENSICS_SCRIPT"
  else
    fail "collect-forensics.sh не найден"
  fi
  echo ""

  # ── Итог ─────────────────────────────────────────────────────────────
  echo "## Итог"
  echo "  PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
  echo ""
  if [ "$FAIL" -eq 0 ] && [ "$WARN" -le 2 ]; then
    echo "  Готовность: ВЫСОКАЯ"
    echo "  Инфраструктура готова к передаче данных в ГосСОПКА"
  elif [ "$FAIL" -le 2 ]; then
    echo "  Готовность: СРЕДНЯЯ"
    echo "  Устраните FAIL-пункты перед проверкой регулятором"
  else
    echo "  Готовность: НИЗКАЯ"
    echo "  Требуется настройка: setup-gossopka-integration.sh"
  fi

} | tee "$OUTPUT"

echo ""
echo "Отчёт: $OUTPUT"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
