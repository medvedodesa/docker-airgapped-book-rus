#!/usr/bin/env bash
# Проверка статуса SELinux/AppArmor на всех хостах Docker и оповещение при отклонениях
# Использование: bash selinux-status-check.sh [hosts_file_or_host1 host2 ...]
set -euo pipefail

HOSTS_FILE="${HOSTS_FILE:-}"
OUTPUT="${SELINUX_CHECK_OUTPUT:-selinux-status-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Определяем список хостов
if [ -n "$HOSTS_FILE" ] && [ -f "$HOSTS_FILE" ]; then
  mapfile -t HOSTS < "$HOSTS_FILE"
elif [ "$#" -gt 0 ]; then
  HOSTS=("$@")
else
  HOSTS=("localhost")
fi

echo "=== Проверка статуса MAC (SELinux / AppArmor) ==="
echo "Хосты: ${HOSTS[*]}"
echo "Дата:  $(date '+%Y-%m-%d %H:%M')"

check_host() {
  local host="$1"
  echo ""
  echo "--- Хост: $host ---"

  if [ "$host" = "localhost" ] || [ "$host" = "$(hostname)" ]; then
    CMD=""
  else
    CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 $host"
  fi

  # Определяем дистрибутив
  os_info=$(${CMD:-} cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' || echo "неизвестно")

  # --- SELinux ---
  if ${CMD:-} command -v getenforce &>/dev/null 2>&1; then
    selinux_status=$(${CMD:-} getenforce 2>/dev/null || echo "error")
    case "$selinux_status" in
      Enforcing)
        ok "$host: SELinux = Enforcing (рекомендуется)"
        ;;
      Permissive)
        warn "$host: SELinux = Permissive — не обеспечивает защиту, только логирует"
        ;;
      Disabled)
        fail "$host: SELinux = Disabled — механизм принудительного контроля доступа отключён"
        ;;
      *)
        warn "$host: SELinux статус не определён ($selinux_status)"
        ;;
    esac

    # Политика
    if selinux_policy=$(${CMD:-} sestatus 2>/dev/null | grep "Loaded policy" | awk '{print $NF}'); then
      echo "    Политика: $selinux_policy"
    fi

    # Docker с SELinux
    docker_selinux=$(${CMD:-} docker info 2>/dev/null | grep -i selinux || echo "")
    if echo "$docker_selinux" | grep -qi "enabled\|true"; then
      ok "$host: Docker SELinux-поддержка включена"
    elif [ -n "$docker_selinux" ]; then
      warn "$host: Docker SELinux — $docker_selinux"
    fi

  # --- AppArmor ---
  elif ${CMD:-} command -v aa-status &>/dev/null 2>&1 || ${CMD:-} aa-enabled &>/dev/null 2>&1; then
    aa_status=$(${CMD:-} aa-enabled 2>/dev/null || echo "no")
    if [ "$aa_status" = "Yes" ]; then
      ok "$host: AppArmor включён"
      profile_count=$(${CMD:-} aa-status --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('profiles',{}).get('enforce',0))" 2>/dev/null || echo "?")
      echo "    Профилей в режиме enforce: $profile_count"

      docker_apparmor=$(${CMD:-} docker info 2>/dev/null | grep -i apparmor || echo "")
      if echo "$docker_apparmor" | grep -qi "enabled\|true\|docker-default"; then
        ok "$host: Docker использует профиль AppArmor"
      else
        warn "$host: Docker AppArmor-профиль не применён"
      fi
    else
      fail "$host: AppArmor отключён"
    fi
  else
    warn "$host: Ни SELinux, ни AppArmor не обнаружены — ОС: $os_info"
  fi

  # --- Контейнеры без MAC-профиля ---
  no_profile=$(${CMD:-} docker ps -q 2>/dev/null | xargs -r ${CMD:-} docker inspect \
    --format '{{.Name}} security={{.HostConfig.SecurityOpt}}' 2>/dev/null | \
    grep 'security=\[\]' | awk '{print $1}' || echo "")
  if [ -n "$no_profile" ]; then
    warn "$host: Контейнеры без явного security-профиля: $(echo "$no_profile" | wc -l)"
  else
    ok "$host: Все контейнеры имеют security-профиль или проверка недоступна"
  fi
}

{
  echo "# Отчёт проверки SELinux/AppArmor"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  for host in "${HOSTS[@]}"; do
    check_host "$host" 2>&1
  done

  echo ""
  echo "=== Итог ==="
  echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
