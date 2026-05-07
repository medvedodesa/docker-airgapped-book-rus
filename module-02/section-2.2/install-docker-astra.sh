#!/usr/bin/env bash
# Установка Docker на Astra Linux SE с учётом особенностей Parsec
# Использование: sudo bash install-docker-astra.sh [директория_с_пакетами]
set -euo pipefail

PKG_DIR="${1:-./packages}"

echo "=== Установка Docker на Astra Linux SE ==="

# Проверка дистрибутива
if ! grep -qi "astra" /etc/os-release 2>/dev/null; then
  echo "ПРЕДУПРЕЖДЕНИЕ: это не Astra Linux. Продолжить? (y/N)"
  read -r ans; [ "$ans" = "y" ] || exit 1
fi

astra_ver=$(grep VERSION_ID /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')
echo "  Версия Astra Linux: $astra_ver"

# Проверка Parsec
parsec_level=$(cat /etc/parsec/privcap 2>/dev/null || echo "0")
echo "  Уровень Parsec: $parsec_level"

# Установка пакетов
echo ""
echo "--- Установка Docker ---"
[ -d "$PKG_DIR" ] || { echo "Директория пакетов не найдена: $PKG_DIR"; exit 1; }
cd "$PKG_DIR"
dpkg -i containerd.io_*.deb 2>&1 | tail -2 || true
dpkg -i docker-ce-cli_*.deb 2>&1 | tail -2 || true
dpkg -i docker-ce_*.deb 2>&1 | tail -2 || true
dpkg -i docker-buildx-plugin_*.deb docker-compose-plugin_*.deb 2>&1 | tail -2 || true
apt-get install -f -y -qq 2>/dev/null || true
cd - >/dev/null

# Настройка Parsec для Docker
echo ""
echo "--- Настройка Parsec ---"
# Директории Docker должны иметь метку максимально допустимого уровня
DOCKER_DIRS=("/var/lib/docker" "/run/docker" "/etc/docker")
for dir in "${DOCKER_DIRS[@]}"; do
  mkdir -p "$dir"
  if command -v pdpl-file &>/dev/null; then
    pdpl-file -R "0:0" "$dir" 2>/dev/null || true
    echo "  Parsec-метка установлена для $dir"
  fi
done

# Политика для dockerd
if command -v astra-admin &>/dev/null; then
  astra-admin -r docker 2>/dev/null || true
fi

# daemon.json для Astra
cat > /etc/docker/daemon.json << 'EOF'
{
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "3"},
  "live-restore": true,
  "no-new-privileges": true
}
EOF

# Запуск
echo ""
echo "--- Запуск Docker daemon ---"
systemctl daemon-reload
systemctl start docker && systemctl enable docker

docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
if [ -n "$docker_ver" ]; then
  echo "[PASS] Docker $docker_ver запущен на Astra Linux"
  echo ""
  echo "ВАЖНО: При проблемах с контейнерами проверьте Parsec-метки:"
  echo "  pdpl-file -R <уровень> <директория>"
else
  echo "[FAIL] Docker не запустился. Журнал:"
  journalctl -u docker -n 30
  exit 1
fi
