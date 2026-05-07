#!/usr/bin/env bash
# Комплексный аудит безопасности Docker-инфраструктуры
# Проверяет: привилегированные контейнеры, открытые сокеты, монтирования, SELinux
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Аудит безопасности Docker ==="
echo "Хост: $(hostname) | Дата: $(date '+%Y-%m-%d %H:%M')"
echo ""

echo "--- Привилегированные контейнеры ---"
priv_containers=$(docker ps -q 2>/dev/null | while read cid; do
  priv=$(docker inspect "$cid" --format '{{.HostConfig.Privileged}}')
  name=$(docker inspect "$cid" --format '{{.Name}}')
  [ "$priv" = "true" ] && echo "$name"
done)
if [ -z "$priv_containers" ]; then
  ok "Привилегированных контейнеров нет"
else
  fail "Привилегированные контейнеры обнаружены:"
  echo "$priv_containers" | sed 's/^/  /'
fi

echo ""
echo "--- Контейнеры с --network=host ---"
host_net=$(docker ps --filter network=host --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
if [ -z "$host_net" ]; then
  ok "Контейнеров с --network=host нет"
else
  warn "Контейнеры с --network=host: $host_net"
fi

echo ""
echo "--- Монтирование чувствительных директорий ---"
docker ps -q 2>/dev/null | while read cid; do
  name=$(docker inspect "$cid" --format '{{.Name}}')
  mounts=$(docker inspect "$cid" --format '{{range .Mounts}}{{.Source}} {{end}}')
  for mount in $mounts; do
    case "$mount" in
      /|/etc|/etc/docker|/var/run/docker.sock|/proc|/sys|/boot)
        fail "Контейнер $name монтирует $mount"
        ;;
    esac
  done
done

echo ""
echo "--- Docker socket доступность ---"
if [ -S /var/run/docker.sock ]; then
  sock_perms=$(ls -la /var/run/docker.sock | awk '{print $1,$3,$4}')
  ok "Docker socket: $sock_perms"
  sock_group=$(ls -la /var/run/docker.sock | awk '{print $4}')
  docker_group_members=$(getent group docker 2>/dev/null | cut -d: -f4)
  if [ -n "$docker_group_members" ]; then
    warn "Члены группы docker (root-эквивалент): $docker_group_members"
  fi
fi

echo ""
echo "--- SELinux/AppArmor ---"
if command -v getenforce &>/dev/null; then
  se=$(getenforce 2>/dev/null)
  [ "$se" = "Enforcing" ] && ok "SELinux: Enforcing" || warn "SELinux: $se"
elif command -v aa-status &>/dev/null; then
  aa-status --enabled &>/dev/null 2>&1 && ok "AppArmor: включён" || warn "AppArmor: выключен"
fi

echo ""
echo "--- Docker API TLS ---"
if docker info --format '{{.DockerRootDir}}' &>/dev/null 2>&1; then
  tls=$(docker info 2>/dev/null | grep -i 'tls\|ssl' || true)
  [ -n "$tls" ] && ok "TLS для Docker API: $tls" || warn "TLS для Docker API не настроен"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
