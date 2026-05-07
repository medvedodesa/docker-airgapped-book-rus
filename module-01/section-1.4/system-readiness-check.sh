#!/usr/bin/env bash
# Комплексная проверка совместимости хост-системы с Docker
# Использование: sudo bash system-readiness-check.sh
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка совместимости с Docker ==="
echo "Хост: $(hostname)  |  ОС: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -s)"
echo ""

# --- Ядро ---
echo "--- Ядро Linux ---"
kernel=$(uname -r)
major=$(echo "$kernel" | cut -d. -f1)
minor=$(echo "$kernel" | cut -d. -f2)
if [ "$major" -ge 5 ] || ([ "$major" -eq 4 ] && [ "$minor" -ge 0 ]); then
  ok "Версия ядра: $kernel"
else
  fail "Версия ядра: $kernel — требуется 4.0+, рекомендуется 5.4+"
fi

# --- Модули ядра ---
echo ""
echo "--- Модули ядра ---"
for mod in overlay br_netfilter; do
  if lsmod 2>/dev/null | grep -q "^$mod"; then
    ok "Модуль $mod загружен"
  elif modprobe -n "$mod" &>/dev/null 2>&1; then
    warn "Модуль $mod не загружен (но доступен для загрузки)"
  else
    fail "Модуль $mod недоступен"
  fi
done

# --- Параметры ядра ---
echo ""
echo "--- Параметры ядра ---"
declare -A sysctl_expected=(
  ["net.bridge.bridge-nf-call-iptables"]="1"
  ["net.bridge.bridge-nf-call-ip6tables"]="1"
  ["net.ipv4.ip_forward"]="1"
)
for param in "${!sysctl_expected[@]}"; do
  expected="${sysctl_expected[$param]}"
  actual=$(sysctl -n "$param" 2>/dev/null || echo "?")
  [ "$actual" = "$expected" ] && ok "$param = $actual" || warn "$param = $actual (ожидается $expected)"
done

# --- Файловая система ---
echo ""
echo "--- Файловая система для Docker ---"
docker_mount=$(df -T /var/lib/docker 2>/dev/null | awk 'NR==2{print $2}' || \
              df -T / | awk 'NR==2{print $2}')
case "$docker_mount" in
  ext4)
    ok "ФС для Docker: ext4 — поддерживает overlay2"
    ;;
  xfs)
    ftype=$(xfs_info /var/lib/docker 2>/dev/null | grep -o 'ftype=[0-9]' | cut -d= -f2 || \
            xfs_info / 2>/dev/null | grep -o 'ftype=[0-9]' | cut -d= -f2 || echo "?")
    if [ "$ftype" = "1" ]; then
      ok "ФС для Docker: xfs с ftype=1 — поддерживает overlay2"
    else
      fail "ФС для Docker: xfs с ftype=$ftype — требуется ftype=1 (переформатирование!)"
    fi
    ;;
  *)
    warn "ФС для Docker: $docker_mount — проверьте совместимость с overlay2"
    ;;
esac

# --- cgroups ---
echo ""
echo "--- cgroups ---"
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
  ok "cgroups v2 (рекомендуется)"
else
  ok "cgroups v1 (поддерживается)"
fi

# --- Свободное место ---
echo ""
echo "--- Дисковое пространство ---"
free_gb=$(df -BG /var/lib/docker 2>/dev/null | awk 'NR==2{gsub("G",""); print $4}' || \
          df -BG / | awk 'NR==2{gsub("G",""); print $4}')
if [ "${free_gb:-0}" -ge 50 ]; then
  ok "Свободное место под Docker: $free_gb ГБ"
elif [ "${free_gb:-0}" -ge 20 ]; then
  warn "Свободное место: $free_gb ГБ (рекомендуется 50+ ГБ)"
else
  fail "Свободное место: $free_gb ГБ — недостаточно (минимум 20 ГБ)"
fi

# --- systemd ---
echo ""
echo "--- systemd ---"
if command -v systemctl &>/dev/null && systemctl status &>/dev/null 2>&1; then
  ok "systemd доступен"
else
  warn "systemd недоступен — потребуется ручное создание юнитов"
fi

# --- SELinux/AppArmor ---
echo ""
echo "--- MAC (SELinux/AppArmor) ---"
if command -v getenforce &>/dev/null; then
  se=$(getenforce 2>/dev/null || echo "Disabled")
  [ "$se" = "Enforcing" ] && ok "SELinux: Enforcing" || warn "SELinux: $se"
elif command -v aa-status &>/dev/null && aa-status --enabled &>/dev/null 2>&1; then
  ok "AppArmor включён"
else
  warn "Ни SELinux, ни AppArmor не включены"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "КРИТИЧЕСКИЕ ОШИБКИ: устраните все [FAIL] перед установкой Docker"
  exit 1
fi
