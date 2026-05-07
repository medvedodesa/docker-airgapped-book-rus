#!/usr/bin/env bash
# Применение конфигурации Docker daemon с валидацией и проверкой после перезапуска
# Использование: sudo bash apply-daemon-config.sh [путь_к_daemon.json]
set -euo pipefail

CONFIG_SRC="${1:-$(dirname "$0")/daemon.json}"
CONFIG_DST="/etc/docker/daemon.json"

echo "=== Применение конфигурации Docker daemon ==="
echo "  Источник: $CONFIG_SRC"

[ -f "$CONFIG_SRC" ] || { echo "Файл конфигурации не найден: $CONFIG_SRC"; exit 1; }

# 1. Валидация JSON
echo ""
echo "--- Валидация JSON ---"
if command -v python3 &>/dev/null; then
  python3 -c "import json,sys; json.load(open('$CONFIG_SRC'))" && echo "[OK] JSON валиден"
elif command -v jq &>/dev/null; then
  jq . "$CONFIG_SRC" > /dev/null && echo "[OK] JSON валиден"
else
  echo "[WARN] python3/jq не найдены, пропускаем валидацию JSON"
fi

# 2. Проверка через dockerd --validate
echo ""
echo "--- Валидация Docker daemon ---"
if dockerd --validate --config-file="$CONFIG_SRC" 2>&1; then
  echo "[OK] Конфигурация принята dockerd"
else
  echo "[FAIL] Ошибка в конфигурации"
  exit 1
fi

# 3. Бэкап текущей конфигурации
echo ""
echo "--- Резервная копия ---"
if [ -f "$CONFIG_DST" ]; then
  backup="$CONFIG_DST.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG_DST" "$backup"
  echo "[OK] Резервная копия: $backup"
fi

# 4. Применение
mkdir -p /etc/docker
cp "$CONFIG_SRC" "$CONFIG_DST"
echo "[OK] Конфигурация скопирована в $CONFIG_DST"

# 5. Перезапуск daemon
echo ""
echo "--- Перезапуск Docker daemon ---"
systemctl restart docker
sleep 3

# 6. Проверка после перезапуска
echo ""
echo "--- Проверка после перезапуска ---"
docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
[ -n "$docker_ver" ] && echo "[PASS] Docker daemon запущен: $docker_ver" || \
  { echo "[FAIL] Docker daemon не ответил после перезапуска"; journalctl -u docker -n 20; exit 1; }

storage=$(docker info --format '{{.Driver}}' 2>/dev/null)
echo "[INFO] Storage driver: $storage"
live_restore=$(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null)
echo "[INFO] Live restore: $live_restore"

echo ""
echo "=== Конфигурация применена успешно ==="
