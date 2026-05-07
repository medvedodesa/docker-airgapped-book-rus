#!/usr/bin/env bash
# Обновление Docker Engine на узлах кластера без остановки сервисов
# Использование: bash update-docker-rolling.sh [node1 node2 ...] или из узла Swarm
set -euo pipefail

NODES="${@:-$(docker node ls --format '{{.Hostname}}' 2>/dev/null | tr '\n' ' ')}"
PKG_DIR="${DOCKER_PKG_DIR:-/opt/packages/docker}"
SSH_USER="${SSH_USER:-root}"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"

echo "=== Поочерёдное обновление Docker ==="
echo "  Узлы: $NODES"
echo "  Пакеты: $PKG_DIR"

[ -n "$NODES" ] || { echo "[FAIL] Нет узлов для обновления"; exit 1; }

for node in $NODES; do
  echo ""
  echo "=============================="
  echo "  Узел: $node"
  echo "=============================="

  # Проверка доступности
  if ! ssh $SSH_OPTS "$SSH_USER@$node" "echo ok" &>/dev/null 2>&1; then
    echo "  [FAIL] Узел $node недоступен по SSH — пропуск"
    continue
  fi

  # Проверка версии
  current_ver=$(ssh $SSH_OPTS "$SSH_USER@$node" "docker version --format '{{.Server.Version}}'" 2>/dev/null || echo "неизвестно")
  echo "  Текущая версия Docker: $current_ver"

  # Вывод из ротации (Swarm)
  if docker node ls --format '{{.Hostname}}' &>/dev/null 2>&1; then
    node_id=$(docker node ls --format '{{.ID}} {{.Hostname}}' 2>/dev/null | grep "$node" | awk '{print $1}')
    if [ -n "$node_id" ]; then
      docker node update --availability drain "$node_id" 2>/dev/null
      echo "  [OK] Узел $node переведён в drain"
      echo "  Ожидание миграции задач (30 сек)..."
      sleep 30
    fi
  fi

  # Остановка Docker
  ssh $SSH_OPTS "$SSH_USER@$node" "systemctl stop docker docker.socket 2>/dev/null" 2>/dev/null
  echo "  [OK] Docker остановлен"

  # Копирование и установка пакетов
  if [ -d "$PKG_DIR" ]; then
    scp $SSH_OPTS "$PKG_DIR"/*.deb "$SSH_USER@$node:/tmp/" 2>/dev/null || \
    scp $SSH_OPTS "$PKG_DIR"/*.rpm "$SSH_USER@$node:/tmp/" 2>/dev/null || true

    ssh $SSH_OPTS "$SSH_USER@$node" "
      if ls /tmp/*.deb &>/dev/null 2>&1; then
        dpkg -i /tmp/*.deb 2>/dev/null
      elif ls /tmp/*.rpm &>/dev/null 2>&1; then
        rpm -Uvh /tmp/*.rpm 2>/dev/null
      fi
    " 2>/dev/null
    echo "  [OK] Пакеты установлены"
  fi

  # Запуск Docker
  ssh $SSH_OPTS "$SSH_USER@$node" "systemctl start docker" 2>/dev/null
  sleep 5

  new_ver=$(ssh $SSH_OPTS "$SSH_USER@$node" "docker version --format '{{.Server.Version}}'" 2>/dev/null || echo "неизвестно")
  echo "  Новая версия Docker: $new_ver"

  # Возврат в ротацию
  if [ -n "${node_id:-}" ]; then
    docker node update --availability active "$node_id" 2>/dev/null
    echo "  [OK] Узел $node возвращён в active"
  fi

  echo "  [OK] Узел $node обновлён"
done

echo ""
echo "=== Обновление Docker завершено ==="
docker node ls 2>/dev/null | head -10 || true
