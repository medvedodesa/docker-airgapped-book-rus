#!/usr/bin/env bash
# Установка Docker из локальных .deb пакетов (Ubuntu/Debian/Astra Linux).
# Запускать в закрытом контуре после переноса установочного пакета.
# Использование: sudo bash install-docker-deb.sh [директория_с_пакетами]
set -euo pipefail

PKG_DIR="${1:-./packages}"
PASS=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Установка Docker из .deb пакетов ==="
echo "  Директория: $PKG_DIR"

[ -d "$PKG_DIR" ] || { echo "Директория $PKG_DIR не найдена"; exit 1; }

deb_count=$(ls -1 "$PKG_DIR"/*.deb 2>/dev/null | wc -l)
[ "$deb_count" -gt 0 ] || { echo "Нет .deb файлов в $PKG_DIR"; exit 1; }

# Проверка контрольных сумм
echo ""
echo "--- Проверка целостности ---"
if [ -f "$PKG_DIR/SHA256SUMS" ] || [ -f "$(dirname "$PKG_DIR")/SHA256SUMS" ]; then
  cd "$(dirname "$PKG_DIR")"
  sha256sum -c SHA256SUMS 2>/dev/null | grep "^$PKG_DIR" | grep -v OK && \
    { echo "ОШИБКА: повреждённые пакеты!"; exit 1; } || ok "Контрольные суммы верны"
  cd - >/dev/null
else
  echo "[WARN] SHA256SUMS не найден, пропускаем проверку"
fi

# Установка в правильном порядке
echo ""
echo "--- Установка пакетов ---"
cd "$PKG_DIR"

# Сначала containerd.io, потом cli, потом ce, потом плагины
for pattern in "containerd.io" "docker-ce-cli" "docker-ce_" "docker-buildx" "docker-compose"; do
  pkgs=$(ls -1 ${pattern}*.deb 2>/dev/null || true)
  if [ -n "$pkgs" ]; then
    dpkg -i $pkgs 2>&1 | tail -3
  fi
done

# Разрешение зависимостей
apt-get install -f -y -qq 2>/dev/null || true

cd - >/dev/null

# Запуск сервиса
echo ""
echo "--- Запуск Docker daemon ---"
systemctl daemon-reload
systemctl start docker
systemctl enable docker

# Верификация
echo ""
echo "--- Верификация ---"
docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null)
if [ -n "$docker_ver" ]; then
  ok "Docker $docker_ver запущен"
else
  fail "Docker daemon не отвечает"
fi

containerd_ver=$(containerd --version 2>/dev/null | awk '{print $3}')
[ -n "$containerd_ver" ] && ok "containerd $containerd_ver" || fail "containerd не найден"

echo ""
echo "=== Итог: PASS=$PASS  FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
