#!/usr/bin/env bash
# Оценка готовности инфраструктуры к развёртыванию Docker в закрытом контуре
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Оценка готовности инфраструктуры ==="
echo "Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"

# --- ОС и ядро ---
echo ""
echo "--- Операционная система ---"
kernel=$(uname -r)
kernel_major=$(echo "$kernel" | cut -d. -f1)
kernel_minor=$(echo "$kernel" | cut -d. -f2)
if [ "$kernel_major" -gt 4 ] || ([ "$kernel_major" -eq 4" ] && [ "$kernel_minor" -ge 0 ]); then
  ok "Ядро: $kernel (поддерживается)"
else
  fail "Ядро: $kernel — требуется 4.0+"
fi

if [ -f /etc/os-release ]; then
  os_name=$(. /etc/os-release && echo "$PRETTY_NAME")
  ok "ОС: $os_name"
fi

# --- Диск ---
echo ""
echo "--- Дисковое пространство ---"
root_free=$(df -BG / | awk 'NR==2{gsub("G",""); print $4}')
if [ "${root_free:-0}" -ge 20 ]; then
  ok "Корневой раздел: $root_free ГБ свободно"
else
  fail "Корневой раздел: $root_free ГБ — недостаточно (минимум 20 ГБ)"
fi

docker_dir="/var/lib/docker"
if [ -d "$docker_dir" ]; then
  docker_free=$(df -BG "$docker_dir" | awk 'NR==2{gsub("G",""); print $4}')
  if [ "${docker_free:-0}" -ge 50 ]; then
    ok "$docker_dir: $docker_free ГБ свободно"
  else
    warn "$docker_dir: $docker_free ГБ — рекомендуется 50+ ГБ"
  fi
fi

# --- Файловая система ---
echo ""
echo "--- Файловая система ---"
fs_type=$(df -T / | awk 'NR==2{print $2}')
ok "Корневая ФС: $fs_type"

if command -v docker &>/dev/null; then
  docker_fs=$(df -T "$docker_dir" 2>/dev/null | awk 'NR==2{print $2}')
  case "$docker_fs" in
    ext4) ok "Docker хранилище ($docker_dir): ext4 — поддерживает overlay2" ;;
    xfs)
      ftype=$(xfs_info "$docker_dir" 2>/dev/null | grep -o 'ftype=[0-9]' | cut -d= -f2 || echo "?")
      [ "$ftype" = "1" ] && ok "Docker хранилище: xfs с ftype=1" || \
        fail "Docker хранилище: xfs с ftype=$ftype — требуется ftype=1 для overlay2"
      ;;
    *) warn "Docker хранилище: $docker_fs — проверьте совместимость с overlay2" ;;
  esac
fi

# --- Сеть ---
echo ""
echo "--- Сеть ---"
if resolvectl status &>/dev/null 2>&1; then
  dns_server=$(resolvectl status | grep 'DNS Servers' | head -1 | awk '{print $NF}')
  [ -n "$dns_server" ] && ok "DNS-сервер: $dns_server" || warn "DNS-сервер не настроен"
elif grep -q nameserver /etc/resolv.conf 2>/dev/null; then
  dns=$(grep nameserver /etc/resolv.conf | head -1 | awk '{print $2}')
  ok "DNS-сервер: $dns"
else
  warn "DNS-сервер не настроен"
fi

# NTP
ntpd_running=$(systemctl is-active chronyd 2>/dev/null || systemctl is-active ntp 2>/dev/null || echo "inactive")
[ "$ntpd_running" = "active" ] && ok "NTP-сервис активен" || warn "NTP-сервис не запущен"

# --- Безопасность ---
echo ""
echo "--- Безопасность ---"
if command -v getenforce &>/dev/null; then
  selinux=$(getenforce 2>/dev/null || echo "Disabled")
  [ "$selinux" = "Enforcing" ] && ok "SELinux: Enforcing" || warn "SELinux: $selinux (рекомендуется Enforcing)"
elif command -v aa-status &>/dev/null; then
  aa=$(aa-status --enabled 2>/dev/null && echo "enabled" || echo "disabled")
  [ "$aa" = "enabled" ] && ok "AppArmor: включён" || warn "AppArmor: выключен"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
