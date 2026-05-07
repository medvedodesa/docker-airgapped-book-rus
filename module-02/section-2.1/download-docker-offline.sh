#!/usr/bin/env bash
# Загрузка пакетов Docker для автономной установки в закрытом контуре.
# Запускать ТОЛЬКО на машине с доступом к интернету.
# Использование: sudo bash download-docker-offline.sh [дистрибутив] [версия] [директория]
set -euo pipefail

DISTRO="${1:-ubuntu-22.04}"
DOCKER_VERSION="${2:-26.1.4}"
OUTPUT_DIR="${3:-/tmp/docker-offline-$(date +%Y%m%d)}"

echo "=== Загрузка Docker для автономной установки ==="
echo "  Дистрибутив: $DISTRO | Docker: $DOCKER_VERSION"
echo "  Директория:  $OUTPUT_DIR"

mkdir -p "$OUTPUT_DIR"/{packages,binaries}
cd "$OUTPUT_DIR/packages"

case "$DISTRO" in
  ubuntu-22.04|ubuntu-20.04|debian-12|debian-11)
    distro_id=$(echo "$DISTRO" | cut -d- -f1)
    codename=""
    case "$DISTRO" in
      ubuntu-22.04) codename="jammy" ;;
      ubuntu-20.04) codename="focal" ;;
      debian-12)    codename="bookworm" ;;
      debian-11)    codename="bullseye" ;;
    esac

    echo "--- Настройка репозитория Docker ---"
    apt-get update -qq
    apt-get install -y -qq curl gnupg ca-certificates

    curl -fsSL "https://download.docker.com/linux/$distro_id/gpg" | \
      gpg --dearmor -o /tmp/docker-archive-keyring.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/tmp/docker-archive-keyring.gpg] \
      https://download.docker.com/linux/$distro_id $codename stable" \
      > /etc/apt/sources.list.d/docker-download-temp.list
    apt-get update -qq

    echo "--- Загрузка основных пакетов ---"
    apt-get download \
      "docker-ce=${DOCKER_VERSION}*" \
      "docker-ce-cli=${DOCKER_VERSION}*" \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin 2>/dev/null || \
    apt-get download docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    echo "--- Загрузка зависимостей ---"
    apt-get install -y --no-install-recommends apt-rdepends 2>/dev/null || true
    for pkg in docker-ce containerd.io; do
      apt-get download $(apt-get install --print-uris -qq "$pkg" 2>/dev/null | \
        awk '{print $1}' | tr -d "'" | xargs -I{} basename {} .deb | \
        sed 's/_.*//') 2>/dev/null || true
    done

    rm -f /etc/apt/sources.list.d/docker-download-temp.list
    apt-get update -qq 2>/dev/null || true
    ;;

  rhel-*|rocky-*|alma-*|redos-*)
    echo "--- Настройка репозитория Docker ---"
    dnf config-manager --add-repo \
      https://download.docker.com/linux/rhel/docker-ce.repo 2>/dev/null || \
    yum-config-manager --add-repo \
      https://download.docker.com/linux/centos/docker-ce.repo

    echo "--- Загрузка пакетов ---"
    dnf download --resolve \
      "docker-ce-$DOCKER_VERSION" docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin \
      --destdir . 2>/dev/null || \
    yum install --downloadonly --downloaddir=. \
      docker-ce docker-ce-cli containerd.io
    ;;

  *)
    echo "Неизвестный дистрибутив: $DISTRO"
    echo "Поддерживаемые: ubuntu-22.04, ubuntu-20.04, debian-12, rhel-9, rocky-9"
    exit 1 ;;
esac

pkg_count=$(ls -1 "$OUTPUT_DIR/packages/" | wc -l)
echo "  Загружено пакетов: $pkg_count"

# Скачиваем также статический бинарник (запасной вариант)
echo ""
echo "--- Загрузка статических бинарников (запасной вариант) ---"
ARCH=$(uname -m); [ "$ARCH" = "x86_64" ] && ARCH="x86_64"
STATIC_URL="https://download.docker.com/linux/static/stable/$ARCH/docker-$DOCKER_VERSION.tgz"
curl -fsSL "$STATIC_URL" -o "$OUTPUT_DIR/binaries/docker-$DOCKER_VERSION.tgz" || true

# Контрольные суммы
echo ""
echo "--- Контрольные суммы ---"
cd "$OUTPUT_DIR"
find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS
echo "  SHA256SUMS: $(wc -l < SHA256SUMS) файлов"

echo ""
echo "=== Готово: $OUTPUT_DIR ==="
du -sh "$OUTPUT_DIR"
