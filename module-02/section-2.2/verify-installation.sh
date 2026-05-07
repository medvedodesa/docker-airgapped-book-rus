#!/usr/bin/env bash
# Комплексная верификация установки Docker
set -euo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Верификация установки Docker ==="
echo "Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"
echo ""

# Версии компонентов
echo "--- Версии компонентов ---"
docker_cli=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo "")
docker_srv=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
containerd_ver=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "")

[ -n "$docker_cli" ] && ok "Docker CLI: $docker_cli" || fail "Docker CLI недоступен"
[ -n "$docker_srv" ] && ok "Docker daemon: $docker_srv" || fail "Docker daemon не отвечает"
[ -n "$containerd_ver" ] && ok "containerd: $containerd_ver" || fail "containerd не найден"

# Совпадение версий
if [ -n "$docker_cli" ] && [ -n "$docker_srv" ] && [ "$docker_cli" = "$docker_srv" ]; then
  ok "Версии CLI и daemon совпадают"
elif [ -n "$docker_cli" ] && [ -n "$docker_srv" ]; then
  warn "Версии CLI ($docker_cli) и daemon ($docker_srv) различаются"
fi

echo ""
echo "--- Конфигурация daemon ---"
storage_driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo "")
[ "$storage_driver" = "overlay2" ] && ok "Storage driver: overlay2" || warn "Storage driver: $storage_driver"

live_restore=$(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || echo "false")
[ "$live_restore" = "true" ] && ok "live-restore: включён" || warn "live-restore: выключен (рекомендуется включить)"

cgroup_driver=$(docker info --format '{{.CgroupDriver}}' 2>/dev/null || echo "")
ok "Cgroup driver: $cgroup_driver"

echo ""
echo "--- Функциональная проверка ---"
# Тестовый контейнер
if docker run --rm --network none alpine:latest echo "test" &>/dev/null 2>&1; then
  ok "Тестовый контейнер запущен"
else
  fail "Не удалось запустить тестовый контейнер"
fi

# Сети
default_net=$(docker network ls --filter name=bridge --format '{{.Name}}' 2>/dev/null)
[ -n "$default_net" ] && ok "Сеть bridge создана" || fail "Сеть bridge отсутствует"

# Docker Compose
if docker compose version &>/dev/null 2>&1; then
  compose_ver=$(docker compose version --short 2>/dev/null || echo "ok")
  ok "Docker Compose: $compose_ver"
else
  warn "Docker Compose plugin не установлен"
fi

# Buildx
if docker buildx version &>/dev/null 2>&1; then
  ok "Docker Buildx доступен"
else
  warn "Docker Buildx plugin не установлен"
fi

echo ""
echo "--- systemd ---"
docker_enabled=$(systemctl is-enabled docker 2>/dev/null || echo "disabled")
docker_active=$(systemctl is-active docker 2>/dev/null || echo "inactive")
[ "$docker_active" = "active" ] && ok "Docker daemon: active" || fail "Docker daemon: $docker_active"
[ "$docker_enabled" = "enabled" ] && ok "Автозапуск: включён" || warn "Автозапуск: $docker_enabled"

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || { echo "Исправьте ошибки перед продолжением"; exit 1; }
