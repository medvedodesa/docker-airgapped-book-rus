#!/usr/bin/env bash
# Проверка конфигурации безопасности всех запущенных контейнеров
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo "=== Проверка hardening контейнеров ==="
echo ""

containers=$(docker ps -q 2>/dev/null)
[ -n "$containers" ] || { echo "Нет запущенных контейнеров"; exit 0; }

for cid in $containers; do
  name=$(docker inspect "$cid" --format '{{.Name}}' | tr -d '/')
  image=$(docker inspect "$cid" --format '{{.Config.Image}}')
  echo "--- Контейнер: $name ($image) ---"

  # Привилегированный режим
  priv=$(docker inspect "$cid" --format '{{.HostConfig.Privileged}}')
  [ "$priv" = "false" ] && ok "Не привилегированный" || fail "PRIVILEGED MODE!"

  # Пользователь
  user=$(docker inspect "$cid" --format '{{.Config.User}}')
  [ -n "$user" ] && [ "$user" != "root" ] && [ "$user" != "0" ] && \
    ok "Пользователь: $user" || warn "Запускается от root (User='$user')"

  # Лимиты памяти
  mem=$(docker inspect "$cid" --format '{{.HostConfig.Memory}}')
  [ "${mem:-0}" -gt 0 ] && ok "Лимит памяти: $(( mem / 1024 / 1024 )) МБ" || warn "Лимит памяти не установлен"

  # no-new-privileges
  nnp=$(docker inspect "$cid" --format '{{.HostConfig.SecurityOpt}}' 2>/dev/null)
  echo "$nnp" | grep -q "no-new-privileges" && ok "no-new-privileges: включён" || warn "no-new-privileges: не установлен"

  # Capabilities
  cap_add=$(docker inspect "$cid" --format '{{.HostConfig.CapAdd}}')
  cap_drop=$(docker inspect "$cid" --format '{{.HostConfig.CapDrop}}')
  [ "$cap_add" = "[]" ] || warn "Добавленные capabilities: $cap_add"
  echo "$cap_drop" | grep -qi "all" && ok "Capabilities: ALL dropped" || warn "Capabilities не ограничены явно"

  # Опасные монтирования
  mounts=$(docker inspect "$cid" --format '{{range .Mounts}}{{.Source}} {{end}}')
  dangerous=false
  for m in $mounts; do
    case "$m" in
      /|/etc|/var/run/docker.sock|/proc|/sys|/boot)
        fail "Опасное монтирование: $m"; dangerous=true ;;
    esac
  done
  $dangerous || ok "Нет опасных монтирований"

  echo ""
done

echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
