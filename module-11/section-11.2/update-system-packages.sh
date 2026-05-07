#!/usr/bin/env bash
# Обновление пакетов ОС из локального зеркала Nexus с проверкой и журналированием
# Использование: sudo bash update-system-packages.sh [nexus_url] [тип: security|all]
set -euo pipefail

NEXUS_URL="${1:-${NEXUS_URL:-http://nexus.internal.company.local:8081}}"
UPDATE_TYPE="${2:-security}"   # security | all
LOG_FILE="${UPDATE_LOG:-/var/log/package-updates-$(date +%Y%m%d).log}"
DRY_RUN="${DRY_RUN:-false}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

echo "=== Обновление пакетов ОС ==="
echo "Nexus:  $NEXUS_URL"
echo "Тип:    $UPDATE_TYPE"
echo "Режим:  $([ "$DRY_RUN" = true ] && echo 'DRY RUN' || echo 'ПРИМЕНИТЬ')"
echo "Журнал: $LOG_FILE"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

[ "$(id -u)" -ne 0 ] && { echo "Требуется root"; exit 1; }

log "=== Начало обновления пакетов ==="
log "Хост: $(hostname)  ОС: $(. /etc/os-release && echo "$PRETTY_NAME")"

# --- Определяем дистрибутив ---
echo ""
echo "--- Дистрибутив ---"
if command -v apt-get &>/dev/null; then
  PKG_MANAGER="apt"
  . /etc/os-release
  ok "Дистрибутив: $PRETTY_NAME (apt)"
elif command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
  . /etc/os-release
  ok "Дистрибутив: $PRETTY_NAME (dnf)"
elif command -v yum &>/dev/null; then
  PKG_MANAGER="yum"
  . /etc/os-release
  ok "Дистрибутив: $PRETTY_NAME (yum)"
else
  fail "Неизвестный пакетный менеджер"
  exit 1
fi

# --- Проверка зеркала Nexus ---
echo ""
echo "--- Зеркало Nexus ---"
if curl -sf --max-time 10 "$NEXUS_URL/service/rest/v1/status" >/dev/null 2>&1; then
  ok "Nexus доступен: $NEXUS_URL"
else
  fail "Nexus недоступен: $NEXUS_URL — обновление из интернета запрещено"
  log "FAIL: Nexus недоступен $NEXUS_URL"
  exit 1
fi

# Проверяем что источники пакетов указывают на Nexus, а не на внешние серверы
check_repos_point_to_nexus() {
  case "$PKG_MANAGER" in
    apt)
      external=$(grep -rh "^deb " /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null | \
        grep -v "$(echo "$NEXUS_URL" | sed 's|http://||')" | \
        grep -v "^#" | wc -l)
      ;;
    dnf|yum)
      external=$(grep -rh "^baseurl" /etc/yum.repos.d/ 2>/dev/null | \
        grep -v "$(echo "$NEXUS_URL" | sed 's|http://||')" | \
        grep -v "^#" | wc -l)
      ;;
  esac
  if [ "${external:-0}" -gt 0 ]; then
    warn "Обнаружены репозитории не из Nexus ($external шт.) — проверьте конфигурацию"
  else
    ok "Все репозитории указывают на внутренний Nexus"
  fi
}
check_repos_point_to_nexus

# --- Список обновлений ---
echo ""
echo "--- Доступные обновления ---"
case "$PKG_MANAGER" in
  apt)
    apt-get update -qq 2>/dev/null && ok "apt update выполнен"
    if [ "$UPDATE_TYPE" = "security" ]; then
      # Только патчи безопасности
      updates=$(apt-get --simulate upgrade 2>/dev/null | grep "^Inst" | \
        grep -i "security" | wc -l || echo 0)
    else
      updates=$(apt-get --simulate upgrade 2>/dev/null | grep "^Inst" | wc -l || echo 0)
    fi
    ;;
  dnf|yum)
    if [ "$UPDATE_TYPE" = "security" ]; then
      updates=$($PKG_MANAGER check-update --security --quiet 2>/dev/null | \
        grep -v "^$\|^Last" | wc -l || echo 0)
    else
      updates=$($PKG_MANAGER check-update --quiet 2>/dev/null | \
        grep -v "^$\|^Last" | wc -l || echo 0)
    fi
    ;;
esac

ok "Доступно обновлений ($UPDATE_TYPE): ${updates:-0}"
log "Доступно обновлений ($UPDATE_TYPE): ${updates:-0}"

if [ "${updates:-0}" -eq 0 ]; then
  ok "Система актуальна — обновлений нет"
  log "Система актуальна"
  exit 0
fi

# --- Применение ---
echo ""
echo "--- Применение ---"
if [ "$DRY_RUN" = "true" ]; then
  warn "DRY RUN — изменения не применяются"
  exit 0
fi

BEFORE_PKGS=$(dpkg -l 2>/dev/null | grep "^ii" | wc -l || rpm -qa 2>/dev/null | wc -l || echo 0)

case "$PKG_MANAGER" in
  apt)
    if [ "$UPDATE_TYPE" = "security" ]; then
      DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        upgrade --with-new-pkgs 2>&1 | tee -a "$LOG_FILE" | tail -5
    else
      DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        dist-upgrade 2>&1 | tee -a "$LOG_FILE" | tail -5
    fi
    ;;
  dnf)
    if [ "$UPDATE_TYPE" = "security" ]; then
      dnf -y update --security 2>&1 | tee -a "$LOG_FILE" | tail -5
    else
      dnf -y update 2>&1 | tee -a "$LOG_FILE" | tail -5
    fi
    ;;
  yum)
    if [ "$UPDATE_TYPE" = "security" ]; then
      yum -y update --security 2>&1 | tee -a "$LOG_FILE" | tail -5
    else
      yum -y update 2>&1 | tee -a "$LOG_FILE" | tail -5
    fi
    ;;
esac

ok "Обновление применено"
log "Обновление применено успешно"

# Перезагрузка нужна?
if [ -f /var/run/reboot-required ] || \
   (command -v needs-restarting &>/dev/null && needs-restarting -r &>/dev/null); then
  warn "Требуется перезагрузка для применения обновлений ядра"
  log "WARN: Требуется перезагрузка"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
log "=== Итог: PASS=$PASS WARN=$WARN FAIL=$FAIL ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
