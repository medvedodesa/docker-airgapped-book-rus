#!/usr/bin/env bash
# Проверка текущей конфигурации Docker daemon и выявление потенциальных проблем
set -euo pipefail

DAEMON_JSON="${DOCKER_DAEMON_CONFIG:-/etc/docker/daemon.json}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка конфигурации Docker daemon ==="
echo "Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"
echo "Файл конфигурации: $DAEMON_JSON"

# --- Проверка наличия файла ---
echo ""
echo "--- Файл конфигурации ---"
if [ ! -f "$DAEMON_JSON" ]; then
  fail "Файл $DAEMON_JSON не найден — демон работает с параметрами по умолчанию"
  echo ""
  echo "=== Итог: FAIL — конфигурационный файл отсутствует ==="
  exit 1
fi

# Проверка валидности JSON
if ! python3 -m json.tool "$DAEMON_JSON" >/dev/null 2>&1; then
  fail "Файл $DAEMON_JSON содержит невалидный JSON"
  exit 1
fi
ok "Файл присутствует и содержит валидный JSON"

# --- Читаем значения ---
get_val() { python3 -c "import json,sys; d=json.load(open('$DAEMON_JSON')); print(d.get('$1',''))" 2>/dev/null || echo ""; }

# --- Драйвер журналов ---
echo ""
echo "--- Журналирование ---"
log_driver=$(get_val log-driver)
if [ "$log_driver" = "json-file" ] || [ "$log_driver" = "local" ]; then
  ok "log-driver: $log_driver"
elif [ -z "$log_driver" ]; then
  warn "log-driver не задан — используется json-file по умолчанию (рекомендуется задать явно)"
else
  warn "log-driver: $log_driver — убедитесь что драйвер поддерживается в закрытом контуре"
fi

# --- Внутренний реестр ---
echo ""
echo "--- Реестр образов ---"
insecure_reg=$(python3 -c "import json; d=json.load(open('$DAEMON_JSON')); print('\n'.join(d.get('insecure-registries',[])))  " 2>/dev/null || echo "")
if [ -n "$insecure_reg" ]; then
  warn "insecure-registries задан: $insecure_reg — рекомендуется использовать TLS"
else
  ok "insecure-registries не задан"
fi

mirrors=$(python3 -c "import json; d=json.load(open('$DAEMON_JSON')); print('\n'.join(d.get('registry-mirrors',[])))  " 2>/dev/null || echo "")
if [ -n "$mirrors" ]; then
  ok "registry-mirrors: $mirrors"
else
  warn "registry-mirrors не задан — в закрытом контуре рекомендуется указать Harbor"
fi

# --- Безопасность ---
echo ""
echo "--- Параметры безопасности ---"
userns=$(get_val userns-remap)
if [ "$userns" = "default" ] || [ -n "$userns" ]; then
  ok "userns-remap: $userns (user namespace remapping включён)"
else
  warn "userns-remap не задан — контейнеры запускаются с UID хоста"
fi

no_new_priv=$(get_val no-new-privileges)
if [ "$no_new_priv" = "True" ] || [ "$no_new_priv" = "true" ]; then
  ok "no-new-privileges: true"
else
  warn "no-new-privileges не задан или false — рекомендуется включить"
fi

# --- Хранилище данных ---
echo ""
echo "--- Хранилище ---"
data_root=$(get_val data-root)
if [ -n "$data_root" ]; then
  ok "data-root: $data_root"
  if [ -d "$data_root" ]; then
    used_pct=$(df "$data_root" | awk 'NR==2{print $5}' | tr -d '%')
    if [ "${used_pct:-0}" -gt 85 ]; then
      warn "Диск data-root заполнен на ${used_pct}% — приближается к критическому уровню"
    else
      ok "Заполненность data-root: ${used_pct}%"
    fi
  fi
else
  warn "data-root не задан — используется /var/lib/docker по умолчанию"
fi

# --- Live restore ---
echo ""
echo "--- Операционные параметры ---"
live_restore=$(get_val live-restore)
if [ "$live_restore" = "True" ] || [ "$live_restore" = "true" ]; then
  ok "live-restore: true — контейнеры переживут перезапуск демона"
else
  warn "live-restore не включён — перезапуск демона остановит все контейнеры"
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
