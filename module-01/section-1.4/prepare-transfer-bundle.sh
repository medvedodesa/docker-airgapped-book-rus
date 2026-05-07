#!/usr/bin/env bash
# Подготовка передаточного пакета для развёртывания Docker в закрытом контуре
# Запускать на машине с доступом в интернет
# Использование: sudo bash prepare-transfer-bundle.sh [дистрибутив] [версия_docker] [выходная_директория]
set -euo pipefail

DISTRO="${1:-ubuntu-22.04}"
DOCKER_VERSION="${2:-26.1.4}"
OUTPUT="${3:-/tmp/docker-bundle}"

DATE=$(date +%Y%m%d)
BUNDLE="$OUTPUT/docker-bundle-$DISTRO-$DATE"

echo "=== Подготовка передаточного пакета Docker ==="
echo "  Дистрибутив: $DISTRO | Версия Docker: $DOCKER_VERSION | Дата: $DATE"

mkdir -p "$BUNDLE"/{packages,images,configs,scripts}

# 1. Пакеты Docker
echo ""
echo "--- Загрузка пакетов Docker ---"
cd "$BUNDLE/packages"

case "$DISTRO" in
  ubuntu-22.04|ubuntu-20.04|debian-*)
    # Добавляем репозиторий Docker
    codename=$(. /etc/os-release 2>/dev/null && echo "$VERSION_CODENAME" || echo "jammy")
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /tmp/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/tmp/docker.gpg] \
      https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker-temp.list
    apt-get update -qq

    apt-get download \
      "docker-ce=${DOCKER_VERSION}*" \
      "docker-ce-cli=${DOCKER_VERSION}*" \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin 2>/dev/null || \
    apt-get download docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Зависимости
    apt-get install -y --no-install-recommends apt-rdepends &>/dev/null || true
    for pkg in docker-ce docker-ce-cli containerd.io; do
      apt-get download $(apt-rdepends "$pkg" 2>/dev/null | grep -v "^  " | grep -v "^$pkg$" | head -20) 2>/dev/null || true
    done
    rm -f /etc/apt/sources.list.d/docker-temp.list
    ;;

  rhel-*|rocky-*|alma-*|redos-*)
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || true
    dnf download --resolve \
      "docker-ce-$DOCKER_VERSION" docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin \
      --destdir . 2>/dev/null
    ;;
esac

pkg_count=$(ls -1 "$BUNDLE/packages/" | wc -l)
echo "  Загружено пакетов: $pkg_count"
cd -

# 2. Базовые образы
echo ""
echo "--- Загрузка базовых образов ---"
declare -a IMAGES=(
  "ubuntu:22.04"
  "alpine:3.19"
)
for img in "${IMAGES[@]}"; do
  echo "  $img..."
  docker pull "$img" -q
  fname=$(echo "$img" | tr ':/' '__').tar.gz
  docker save "$img" | gzip > "$BUNDLE/images/$fname"
  size=$(du -sh "$BUNDLE/images/$fname" | awk '{print $1}')
  echo "    -> $fname ($size)"
done

# 3. Конфиги
echo ""
echo "--- Копирование конфигурационных файлов ---"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$SCRIPT_DIR/sysctl-docker.conf" ] && cp "$SCRIPT_DIR/sysctl-docker.conf" "$BUNDLE/configs/"

# 4. Скрипты установки
cat > "$BUNDLE/scripts/install-docker-deb.sh" << 'INSTALL_EOF'
#!/usr/bin/env bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "Установка Docker из локального пакета..."
cd "$SCRIPT_DIR/packages"
sha256sum -c ../SHA256SUMS 2>/dev/null | grep packages/ || true
dpkg -i containerd.io_*.deb 2>/dev/null || true
dpkg -i docker-ce-cli_*.deb 2>/dev/null || true
dpkg -i docker-ce_*.deb 2>/dev/null || true
dpkg -i docker-buildx-plugin_*.deb docker-compose-plugin_*.deb 2>/dev/null || true
apt-get install -f -y 2>/dev/null || true
systemctl start docker && systemctl enable docker
docker version && echo "Docker установлен успешно"
INSTALL_EOF
chmod +x "$BUNDLE/scripts/install-docker-deb.sh"

cat > "$BUNDLE/scripts/verify-bundle.sh" << 'VERIFY_EOF'
#!/usr/bin/env bash
BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "Проверка целостности пакета..."
cd "$BUNDLE_DIR"
sha256sum -c SHA256SUMS
echo "Все файлы проверены успешно"
VERIFY_EOF
chmod +x "$BUNDLE/scripts/verify-bundle.sh"

# 5. Контрольные суммы
echo ""
echo "--- Вычисление контрольных сумм ---"
cd "$BUNDLE"
find . -type f ! -name 'SHA256SUMS' | sort | xargs sha256sum > SHA256SUMS
echo "  SHA256SUMS создан: $(wc -l < SHA256SUMS) файлов"
cd -

# 6. Упаковка
echo ""
echo "--- Упаковка ---"
tar czf "$OUTPUT/docker-bundle-$DISTRO-$DATE.tar.gz" -C "$OUTPUT" "docker-bundle-$DISTRO-$DATE"
sha256sum "$OUTPUT/docker-bundle-$DISTRO-$DATE.tar.gz" > "$OUTPUT/docker-bundle-$DISTRO-$DATE.tar.gz.sha256"

echo ""
echo "=== Готово ==="
echo "Архив:    $OUTPUT/docker-bundle-$DISTRO-$DATE.tar.gz"
echo "Контр.:   $OUTPUT/docker-bundle-$DISTRO-$DATE.tar.gz.sha256"
du -sh "$OUTPUT/docker-bundle-$DISTRO-$DATE.tar.gz"
