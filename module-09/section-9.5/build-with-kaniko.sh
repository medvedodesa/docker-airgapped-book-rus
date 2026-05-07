#!/usr/bin/env bash
# Сборка Docker-образа через Kaniko (без привилегированного режима)
# Использование: bash build-with-kaniko.sh <context_dir> <image:tag> [dockerfile]
set -euo pipefail

CONTEXT_DIR="${1:-$(pwd)}"
TARGET_IMAGE="${2:-}"
DOCKERFILE="${3:-Dockerfile}"
HARBOR_HOST="${HARBOR_HOST:-harbor.internal.company.local}"
KANIKO_IMAGE="${HARBOR_HOST}/tools/kaniko/executor:latest"
BUILD_ARGS="${BUILD_ARGS:-}"

[ -n "$TARGET_IMAGE" ] || { echo "Использование: $0 <context> <image:tag> [dockerfile]"; exit 1; }

echo "=== Сборка через Kaniko ==="
echo "  Контекст:  $CONTEXT_DIR"
echo "  Образ:     $TARGET_IMAGE"
echo "  Dockerfile: $DOCKERFILE"

[ -f "$CONTEXT_DIR/$DOCKERFILE" ] || {
  echo "[FAIL] Dockerfile не найден: $CONTEXT_DIR/$DOCKERFILE"
  exit 1
}

# Docker credentials для push в Harbor
echo ""
echo "--- Настройка credentials ---"
DOCKER_CONFIG_DIR=$(mktemp -d)
mkdir -p "$DOCKER_CONFIG_DIR"

if [ -f "$HOME/.docker/config.json" ]; then
  cp "$HOME/.docker/config.json" "$DOCKER_CONFIG_DIR/config.json"
  echo "  [OK] Docker credentials скопированы"
else
  echo "  [WARN] Docker config не найден — убедитесь что выполнен docker login"
fi

# Подготовка build args
KANIKO_BUILD_ARGS=()
if [ -n "$BUILD_ARGS" ]; then
  while IFS= read -r arg; do
    [ -n "$arg" ] && KANIKO_BUILD_ARGS+=("--build-arg" "$arg")
  done <<< "$BUILD_ARGS"
fi

# Запуск Kaniko
echo ""
echo "--- Сборка ---"
docker run --rm \
  -v "$CONTEXT_DIR:/workspace" \
  -v "$DOCKER_CONFIG_DIR:/kaniko/.docker:ro" \
  "$KANIKO_IMAGE" \
  --context "/workspace" \
  --dockerfile "/workspace/$DOCKERFILE" \
  --destination "$TARGET_IMAGE" \
  --cache=false \
  --skip-tls-verify-pull=false \
  --skip-tls-verify=false \
  --compressed-caching=false \
  --snapshot-mode=redo \
  --use-new-run \
  "${KANIKO_BUILD_ARGS[@]}" \
  2>&1

exit_code=$?
rm -rf "$DOCKER_CONFIG_DIR"

if [ $exit_code -eq 0 ]; then
  echo ""
  echo "  [OK] Образ собран и отправлен: $TARGET_IMAGE"
else
  echo ""
  echo "  [FAIL] Сборка завершилась с ошибкой (код $exit_code)"
  exit $exit_code
fi

echo ""
echo "=== Kaniko build завершён: $TARGET_IMAGE ==="
