#!/usr/bin/env bash
# Структурированный отчёт Zero Trust Maturity Model с рекомендациями по приоритетам
# Использование: bash zero-trust-maturity-report.sh [harbor_url] [vault_addr]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-https://harbor.internal.company.local}}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
OUTPUT="${ZT_REPORT_OUTPUT:-zero-trust-maturity-$(date +%Y%m%d).txt}"

# Уровни зрелости: 0=Традиционный 1=Начальный 2=Продвинутый 3=Оптимальный
declare -A PILLARS
declare -A SCORES

check_identity() {
  local score=0
  # Vault настроен
  if [ -n "$VAULT_TOKEN" ] && curl -sf --max-time 5 \
      -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
    ((score+=1))
    # AppRole настроен
    if curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/sys/auth" 2>/dev/null | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print('approle/' in d)" 2>/dev/null | grep -q True; then
      ((score+=1))
    fi
    # Аудит включён
    audit=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/sys/audit" 2>/dev/null | python3 -c \
      "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [ "$audit" -gt 0 ] && ((score+=1))
  fi
  echo $score
}

check_devices() {
  local score=0
  # Нет привилегированных контейнеров
  priv=$(docker ps -q 2>/dev/null | xargs -r docker inspect \
    --format '{{.HostConfig.Privileged}}' 2>/dev/null | grep -c true || echo 0)
  [ "$priv" -eq 0 ] && ((score+=1))
  # seccomp/AppArmor
  secure=$(docker ps -q 2>/dev/null | xargs -r docker inspect \
    --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null | grep -cv '^\[\]$' || echo 0)
  [ "$secure" -gt 0 ] && ((score+=1))
  # Falco
  (systemctl is-active falco &>/dev/null 2>&1 || docker ps --format '{{.Names}}' 2>/dev/null | grep -q falco) && ((score+=1)) || true
  echo $score
}

check_network() {
  local score=0
  # Нет контейнеров в default bridge
  default_ct=$(docker network inspect bridge --format '{{len .Containers}}' 2>/dev/null || echo 0)
  [ "$default_ct" -eq 0 ] && ((score+=1))
  # Внутренние сети используются
  internal=$(docker network ls --filter driver=bridge --format '{{.Name}}' 2>/dev/null | \
    xargs -r -I{} docker network inspect {} --format '{{.Internal}}' 2>/dev/null | \
    grep -c true || echo 0)
  [ "$internal" -gt 0 ] && ((score+=1))
  # SPIRE
  (command -v spire-agent &>/dev/null || systemctl is-active spire-agent &>/dev/null 2>&1) && ((score+=1)) || true
  echo $score
}

check_applications() {
  local score=0
  # Cosign
  command -v cosign &>/dev/null && ((score+=1)) || true
  # Harbor с политикой сканирования
  if curl -sf --max-time 5 "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
    ((score+=1))
    # Trivy настроен
    AUTH=$(echo -n "admin:${HARBOR_PASSWORD:-Harbor12345}" | base64)
    scanners=$(curl -sf -H "Authorization: Basic $AUTH" \
      "$HARBOR_URL/api/v2.0/scanners" 2>/dev/null | python3 -c \
      "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
    [ "$scanners" -gt 0 ] && ((score+=1))
  fi
  echo $score
}

check_data() {
  local score=0
  # Vault для шифрования
  if [ -n "$VAULT_TOKEN" ] && curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/sys/mounts" 2>/dev/null | python3 -c \
      "import json,sys; d=json.load(sys.stdin); print('transit/' in d)" 2>/dev/null | grep -q True; then
    ((score+=1))
  fi
  # TLS на Harbor
  if echo | openssl s_client -connect "$(echo "$HARBOR_URL" | sed 's|https://||'):443" 2>/dev/null | \
      grep -q "Verify return code: 0" 2>/dev/null; then
    ((score+=1))
  elif curl -skf "$HARBOR_URL/api/v2.0/ping" >/dev/null 2>&1; then
    ((score+=1))
  fi
  # auditd
  systemctl is-active auditd &>/dev/null 2>&1 && ((score+=1)) || true
  echo $score
}

maturity_label() {
  case "$1" in
    0) echo "Традиционный" ;;
    1) echo "Начальный" ;;
    2) echo "Продвинутый" ;;
    3) echo "Оптимальный" ;;
    *) echo "Оптимальный+" ;;
  esac
}

recommendations() {
  local pillar="$1" score="$2"
  case "$pillar" in
    identity)
      [ "$score" -lt 1 ] && echo "    → Установите и настройте HashiCorp Vault (раздел 7.2)"
      [ "$score" -lt 2 ] && echo "    → Настройте AppRole для сервисов (раздел 7.6)"
      [ "$score" -lt 3 ] && echo "    → Включите audit device в Vault (раздел 7.4)"
      ;;
    devices)
      [ "$score" -lt 1 ] && echo "    → Устраните все привилегированные контейнеры (раздел 4.2)"
      [ "$score" -lt 2 ] && echo "    → Добавьте seccomp/AppArmor профили (раздел 4.2)"
      [ "$score" -lt 3 ] && echo "    → Установите Falco для runtime-мониторинга (раздел 5.4)"
      ;;
    network)
      [ "$score" -lt 1 ] && echo "    → Перенесите контейнеры из default bridge в именованные сети (раздел 6.3)"
      [ "$score" -lt 2 ] && echo "    → Используйте --internal сети для изоляции (раздел 6.3)"
      [ "$score" -lt 3 ] && echo "    → Внедрите SPIRE для SVID-аутентификации (раздел 5.2)"
      ;;
    applications)
      [ "$score" -lt 1 ] && echo "    → Настройте подпись образов через Cosign (раздел 4.3)"
      [ "$score" -lt 2 ] && echo "    → Разверните Harbor и включите сканирование (раздел 3.2)"
      [ "$score" -lt 3 ] && echo "    → Включите политику блокировки уязвимых образов (раздел 3.3)"
      ;;
    data)
      [ "$score" -lt 1 ] && echo "    → Включите Vault Transit для шифрования данных (раздел 7.4)"
      [ "$score" -lt 2 ] && echo "    → Настройте TLS на всех компонентах (раздел 6.4)"
      [ "$score" -lt 3 ] && echo "    → Включите auditd с правилами Docker (раздел 5.4)"
      ;;
  esac
}

{
  echo "# Отчёт Zero Trust Maturity: Docker-инфраструктура"
  echo "# Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""
  echo "Методология: CISA Zero Trust Maturity Model v2.0 (адаптировано для Docker)"
  echo ""

  id_score=$(check_identity)
  dev_score=$(check_devices)
  net_score=$(check_network)
  app_score=$(check_applications)
  data_score=$(check_data)

  echo "## Оценка по направлениям (0–3)"
  echo ""
  printf "   %-25s %s / 3  (%s)\n" "Идентификация:"     "$id_score"   "$(maturity_label "$id_score")"
  printf "   %-25s %s / 3  (%s)\n" "Устройства:"         "$dev_score"  "$(maturity_label "$dev_score")"
  printf "   %-25s %s / 3  (%s)\n" "Сети:"               "$net_score"  "$(maturity_label "$net_score")"
  printf "   %-25s %s / 3  (%s)\n" "Приложения:"         "$app_score"  "$(maturity_label "$app_score")"
  printf "   %-25s %s / 3  (%s)\n" "Данные:"             "$data_score" "$(maturity_label "$data_score")"
  echo ""

  total=$((id_score + dev_score + net_score + app_score + data_score))
  max=15
  pct=$((total * 100 / max))

  echo "## Общий балл: $total / $max ($pct%)"
  echo ""
  if   [ "$pct" -ge 80 ]; then echo "   Уровень: ОПТИМАЛЬНЫЙ — инфраструктура соответствует принципам Zero Trust"
  elif [ "$pct" -ge 60 ]; then echo "   Уровень: ПРОДВИНУТЫЙ — основные принципы реализованы, есть точки роста"
  elif [ "$pct" -ge 40 ]; then echo "   Уровень: НАЧАЛЬНЫЙ — базовые меры есть, требуется системная работа"
  else                          echo "   Уровень: ТРАДИЦИОННЫЙ — Zero Trust не реализован, высокий риск"
  fi
  echo ""

  echo "## Приоритетные рекомендации"
  echo ""
  echo "### Идентификация (текущий балл: $id_score/3)"
  recommendations identity "$id_score"
  echo ""
  echo "### Устройства (текущий балл: $dev_score/3)"
  recommendations devices "$dev_score"
  echo ""
  echo "### Сети (текущий балл: $net_score/3)"
  recommendations network "$net_score"
  echo ""
  echo "### Приложения (текущий балл: $app_score/3)"
  recommendations applications "$app_score"
  echo ""
  echo "### Данные (текущий балл: $data_score/3)"
  recommendations data "$data_score"
  echo ""

  echo "## Следующие шаги"
  min_score=$((id_score < dev_score ? id_score : dev_score))
  min_score=$((min_score < net_score ? min_score : net_score))
  echo "   Начните с направления с наименьшим баллом и выполните рекомендации последовательно."
  echo "   Повторите оценку через 30–60 дней: zero-trust-assessment.sh"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
