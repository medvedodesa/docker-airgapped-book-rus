#!/usr/bin/env bash
# Проверка синхронизации времени NTP на хосте (critерий: расхождение < 1 с)
# Использование: bash check-ntp-sync.sh [макс_смещение_в_секундах]
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

MAX_OFFSET="${1:-1}"  # R-1.3-3: допустимое расхождение ≤ 1 секунда

echo "=== Проверка синхронизации времени ==="
echo "Хост: $(hostname)  |  Дата: $(date)"
echo "Допустимое расхождение: ≤ ${MAX_OFFSET} с"
echo ""

# --- Служба синхронизации ---
echo "--- Служба NTP ---"
NTP_CMD=""
if systemctl is-active chronyd &>/dev/null 2>&1; then
  ok "chronyd активен"
  NTP_CMD="chrony"
elif systemctl is-active ntpd &>/dev/null 2>&1; then
  ok "ntpd активен"
  NTP_CMD="ntpd"
elif timedatectl status 2>/dev/null | grep -q 'NTP service: active'; then
  ok "systemd-timesyncd активен"
  NTP_CMD="timedatectl"
else
  fail "Служба синхронизации времени не запущена (chrony, ntpd или systemd-timesyncd)"
fi

echo ""

# --- Смещение времени ---
echo "--- Смещение времени ---"
if [ "$NTP_CMD" = "chrony" ]; then
  tracking=$(chronyc tracking 2>/dev/null || true)
  echo "$tracking" | grep -E 'Reference|System time|Stratum|Last offset' || true
  echo ""
  offset_raw=$(echo "$tracking" | grep 'System time' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)
  if [ -z "$offset_raw" ]; then
    warn "Не удалось прочитать смещение времени из chronyc tracking"
  else
    # Сравниваем через awk (без bc)
    result=$(awk -v offset="$offset_raw" -v max="$MAX_OFFSET" 'BEGIN {
      if (offset + 0 <= max + 0) print "ok"
      else print "fail"
    }')
    if [ "$result" = "ok" ]; then
      ok "Смещение ${offset_raw}с ≤ ${MAX_OFFSET}с — критерий PASS по R-1.3-3"
    else
      fail "Смещение ${offset_raw}с > ${MAX_OFFSET}с — критерий FAIL по R-1.3-3"
    fi
  fi

elif [ "$NTP_CMD" = "ntpd" ]; then
  ntpq_out=$(ntpq -p 2>/dev/null || true)
  echo "$ntpq_out"
  echo ""
  offset_ms=$(echo "$ntpq_out" | awk 'NR>1 && /^\*/{print $9}' | head -1 || true)
  if [ -n "$offset_ms" ]; then
    result=$(awk -v off="$offset_ms" -v max="$MAX_OFFSET" 'BEGIN {
      if (off < 0) off = -off
      if (off / 1000 <= max + 0) print "ok"
      else print "fail"
    }')
    if [ "$result" = "ok" ]; then
      ok "Смещение ${offset_ms}мс — критерий PASS по R-1.3-3"
    else
      fail "Смещение ${offset_ms}мс > $((MAX_OFFSET * 1000))мс — критерий FAIL по R-1.3-3"
    fi
  else
    warn "Активный источник NTP не найден (нет строки с *)"
  fi

elif [ "$NTP_CMD" = "timedatectl" ]; then
  timedatectl status 2>/dev/null | grep -E 'NTP|synchronized|Time zone|RTC' || true
  synced=$(timedatectl status 2>/dev/null | grep -c 'synchronized: yes' || true)
  if [ "${synced:-0}" -ge 1 ]; then
    ok "Время синхронизировано (timedatectl)"
  else
    fail "Время не синхронизировано (timedatectl)"
  fi
fi

echo ""

# --- Источники NTP ---
echo "--- Источники NTP ---"
if [ "$NTP_CMD" = "chrony" ]; then
  sources=$(chronyc sources -v 2>/dev/null | grep -E '^\^\*|^\^\+|^\^\-' || true)
  if [ -n "$sources" ]; then
    ok "Достижимые источники NTP:"
    echo "$sources" | sed 's/^/  /'
    if echo "$sources" | grep -qE 'pool\.ntp\.org|time\.google|time\.cloudflare|ntp\.ubuntu'; then
      warn "Обнаружены публичные NTP-серверы — в закрытом контуре они недоступны, укажите внутренний сервер"
    fi
  else
    fail "Ни один источник NTP не достигается — синхронизация невозможна"
  fi
fi

# --- Конфигурационный файл ---
echo ""
echo "--- Конфигурация ---"
for conf in /etc/chrony.conf /etc/chrony/chrony.conf /etc/ntp.conf; do
  if [ -f "$conf" ]; then
    ok "Файл конфигурации: $conf"
    servers=$(grep -E '^(server|pool|peer)\s' "$conf" | awk '{print $2}' || true)
    if [ -n "$servers" ]; then
      echo "  Серверы:"
      echo "$servers" | sed 's/^/    /'
    fi
    break
  fi
done

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Устраните ошибки синхронизации времени перед развёртыванием компонентов."
  exit 1
fi
