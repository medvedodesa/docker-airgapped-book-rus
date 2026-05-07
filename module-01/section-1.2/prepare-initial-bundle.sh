#!/usr/bin/env bash
# Подготовка первоначального пакета для переноса в закрытый контур
# Запускать на машине с доступом в интернет
set -euo pipefail

DISTRO="${1:-ubuntu-22.04}"
OUTPUT_DIR="${2:-/tmp/initial-bundle}"
DOCKER_VERSION="${3:-26.1.4}"

BUNDLE_DIR="$OUTPUT_DIR/bundle-$(date +%Y%m%d)"

echo "=== Подготовка первоначального пакета ==="
echo "Дистрибутив: $DISTRO"
echo "Версия Docker: $DOCKER_VERSION"
echo "Директория: $BUNDLE_DIR"
echo ""

mkdir -p "$BUNDLE_DIR"/{docker,images,scripts}

# 1. Пакеты Docker
echo "--- Загрузка пакетов Docker ---"
case "$DISTRO" in
  ubuntu-*|debian-*)
    apt-get update -qq
    apt-get download \
      "docker-ce=$DOCKER_VERSION*" \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin 2>/dev/null
    mv ./*.deb "$BUNDLE_DIR/docker/"
    ;;
  rhel-*|rocky-*|alma-*)
    dnf download --resolve \
      "docker-ce-$DOCKER_VERSION" \
      docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin \
      --destdir "$BUNDLE_DIR/docker/" 2>/dev/null
    ;;
  *)
    echo "Неизвестный дистрибутив: $DISTRO"; exit 1 ;;
esac
echo "  Пакеты Docker загружены: $(ls "$BUNDLE_DIR/docker/" | wc -l) файлов"

# 2. Базовые образы
echo ""
echo "--- Загрузка базовых образов ---"
images=(
  "ubuntu:22.04"
  "alpine:3.19"
  "debian:12-slim"
)
for img in "${images[@]}"; do
  echo "  Загрузка $img..."
  docker pull "$img" -q
  filename=$(echo "$img" | tr '/:' '_').tar.gz
  docker save "$img" | gzip > "$BUNDLE_DIR/images/$filename"
done

# 3. Вычисление контрольных сумм
echo ""
echo "--- Контрольные суммы ---"
find "$BUNDLE_DIR" -type f ! -name 'SHA256SUMS' | sort | while read f; do
  sha256sum "$f"
done > "$BUNDLE_DIR/SHA256SUMS"
echo "  SHA256SUMS создан: $(wc -l < "$BUNDLE_DIR/SHA256SUMS") файлов"

# 4. Упаковка
echo ""
echo "--- Упаковка ---"
tar czf "$OUTPUT_DIR/bundle-$(date +%Y%m%d).tar.gz" -C "$OUTPUT_DIR" "bundle-$(date +%Y%m%d)"
sha256sum "$OUTPUT_DIR/bundle-$(date +%Y%m%d).tar.gz" > "$OUTPUT_DIR/bundle-$(date +%Y%m%d).tar.gz.sha256"

echo ""
echo "=== Готово ==="
echo "Архив: $OUTPUT_DIR/bundle-$(date +%Y%m%d).tar.gz"
du -sh "$OUTPUT_DIR/bundle-$(date +%Y%m%d).tar.gz"
