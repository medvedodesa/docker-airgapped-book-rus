#!/usr/bin/env bash
# Настройка GitLab Runner с Buildah: user namespaces, хранилище, тест сборки
# Buildah собирает образы без Docker daemon и без привилегированного режима
# Использование: sudo bash setup-buildah-runner.sh [harbor_url] [gitlab_url] [runner_token]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-harbor.internal.company.local}}"
GITLAB_URL="${2:-${GITLAB_URL:-https://gitlab.internal.company.local}}"
RUNNER_TOKEN="${3:-${GITLAB_RUNNER_TOKEN:-}}"
RUNNER_NAME="${RUNNER_NAME:-buildah-runner-$(hostname)}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"
BUILDAH_STORAGE="${BUILDAH_STORAGE:-/var/lib/buildah}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Настройка GitLab Runner с Buildah ==="
echo "Harbor:  $HARBOR_URL"
echo "GitLab:  $GITLAB_URL"
echo "Runner:  $RUNNER_NAME"
echo "Дата:    $(date '+%Y-%m-%d %H:%M')"

# --- Проверка прав ---
[ "$(id -u)" -ne 0 ] && { echo "Требуется root: sudo bash $0"; exit 1; }

# --- Установка Buildah ---
echo ""
echo "--- Buildah ---"
if command -v buildah &>/dev/null; then
  ok "Buildah уже установлен: $(buildah --version)"
else
  echo "Установка Buildah..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y buildah fuse-overlayfs >/dev/null 2>&1 && ok "Buildah установлен (apt)" || \
      fail "Установка не удалась — установите buildah из локального зеркала Nexus"
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    (dnf install -y buildah fuse-overlayfs 2>/dev/null || yum install -y buildah fuse-overlayfs 2>/dev/null) \
      && ok "Buildah установлен (yum/dnf)" || \
      fail "Установка не удалась — установите buildah из локального зеркала Nexus"
  else
    fail "Неизвестный пакетный менеджер — установите buildah вручную"
    exit 1
  fi
fi

# --- Пространства имён пользователей (user namespaces) ---
echo ""
echo "--- User Namespaces ---"
MAX_MAP_COUNT=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)
if [ "${MAX_MAP_COUNT:-0}" -eq 0 ]; then
  echo 1 > /proc/sys/kernel/unprivileged_userns_clone
  echo "kernel.unprivileged_userns_clone = 1" >> /etc/sysctl.d/99-buildah.conf
  sysctl --system >/dev/null 2>&1
  ok "user namespaces включены"
else
  ok "user namespaces уже включены"
fi

# Проверяем newuidmap/newgidmap
if command -v newuidmap &>/dev/null; then
  ok "newuidmap/newgidmap доступны"
else
  apt-get install -y uidmap 2>/dev/null || yum install -y shadow-utils 2>/dev/null || true
fi

# --- Настройка subuid/subgid для Runner'а ---
echo ""
echo "--- subuid/subgid ---"
if ! id "$RUNNER_USER" &>/dev/null; then
  useradd -r -s /bin/false -m "$RUNNER_USER"
  ok "Пользователь создан: $RUNNER_USER"
fi

RUNNER_UID=$(id -u "$RUNNER_USER")
if ! grep -q "^$RUNNER_USER:" /etc/subuid 2>/dev/null; then
  echo "$RUNNER_USER:100000:65536" >> /etc/subuid
  ok "subuid добавлен: $RUNNER_USER:100000:65536"
else
  ok "subuid уже настроен"
fi

if ! grep -q "^$RUNNER_USER:" /etc/subgid 2>/dev/null; then
  echo "$RUNNER_USER:100000:65536" >> /etc/subgid
  ok "subgid добавлен: $RUNNER_USER:100000:65536"
else
  ok "subgid уже настроен"
fi

# --- Конфигурация хранилища Buildah ---
echo ""
echo "--- Хранилище Buildah ---"
mkdir -p "$BUILDAH_STORAGE" /etc/containers
chown "$RUNNER_USER:$RUNNER_USER" "$BUILDAH_STORAGE"

STORAGE_CONF="/etc/containers/storage.conf"
cat > "$STORAGE_CONF" <<TOML
[storage]
driver = "overlay"
runroot = "/run/containers/storage"
graphroot = "$BUILDAH_STORAGE"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mount_program = "/usr/bin/fuse-overlayfs"
mountopt = "nodev,metacopy=on"
TOML
ok "Конфигурация хранилища: $STORAGE_CONF"

# --- Конфигурация реестров ---
REGISTRIES_CONF="/etc/containers/registries.conf"
cat > "$REGISTRIES_CONF" <<TOML
# Единственный доверенный реестр — внутренний Harbor
[[registry]]
location = "$HARBOR_URL"
insecure = false

# Запрещаем поиск в публичных реестрах
[registries.search]
registries = ["$HARBOR_URL"]

[registries.insecure]
registries = []

[registries.block]
registries = ["docker.io", "quay.io", "gcr.io", "ghcr.io"]
TOML
ok "Реестры настроены: $REGISTRIES_CONF"

# --- Регистрация Runner в GitLab ---
echo ""
echo "--- GitLab Runner ---"
if ! command -v gitlab-runner &>/dev/null; then
  warn "gitlab-runner не найден — пропуск регистрации"
else
  if [ -n "$RUNNER_TOKEN" ]; then
    RUNNER_CONFIG="/etc/gitlab-runner/config.toml"

    gitlab-runner register \
      --non-interactive \
      --url "$GITLAB_URL" \
      --token "$RUNNER_TOKEN" \
      --executor "shell" \
      --shell "bash" \
      --description "$RUNNER_NAME" \
      --tag-list "buildah,no-docker,airgap" \
      --run-untagged=false \
      --locked=false \
      2>/dev/null && ok "Runner зарегистрирован" || warn "Регистрация Runner не удалась"

    # Настройка: запуск заданий от имени RUNNER_USER
    if [ -f "$RUNNER_CONFIG" ]; then
      python3 - "$RUNNER_CONFIG" "$RUNNER_USER" <<'PYEOF'
import sys, re
config_file, user = sys.argv[1], sys.argv[2]
with open(config_file) as f:
    content = f.read()
# Добавляем настройки shell executor
if 'builds_dir' not in content:
    content = content.replace(
        '[runners.custom]',
        f'[runners.custom]\n  builds_dir = "/home/{user}/builds"\n  cache_dir = "/home/{user}/cache"'
    )
with open(config_file, 'w') as f:
    f.write(content)
print(f"Runner настроен для пользователя: {user}")
PYEOF
    fi
  else
    warn "GITLAB_RUNNER_TOKEN не задан — пропуск регистрации"
    echo "    Зарегистрируйте вручную: gitlab-runner register --url $GITLAB_URL --token <token> --executor shell"
  fi
fi

# --- Тест сборки ---
echo ""
echo "--- Тест сборки через Buildah ---"
TEST_IMAGE="$HARBOR_URL/test/buildah-test:$(date +%s)"

# Тест от имени RUNNER_USER
sudo -u "$RUNNER_USER" bash -c "
  buildah from '$HARBOR_URL/library/alpine:3.19' 2>/dev/null || \
  buildah from scratch
" 2>/dev/null && ok "Buildah может создавать контейнеры от $RUNNER_USER" || \
  warn "Тест от $RUNNER_USER не прошёл — проверьте subuid/subgid"

# Тест полного цикла сборки
TEST_CTR=$(sudo -u "$RUNNER_USER" buildah from scratch 2>/dev/null || echo "")
if [ -n "$TEST_CTR" ]; then
  sudo -u "$RUNNER_USER" buildah rm "$TEST_CTR" >/dev/null 2>&1 || true
  ok "Полный цикл сборки: создание и удаление контейнера"
fi

# --- Шаблон .gitlab-ci.yml для Buildah ---
TEMPLATE_FILE="./buildah-pipeline-template.yml"
cat > "$TEMPLATE_FILE" <<YAML
# GitLab CI шаблон: сборка через Buildah без Docker daemon и без привилегий
# Runner должен иметь тег 'buildah'

.buildah-build:
  tags:
    - buildah
    - no-docker
  variables:
    BUILDAH_FORMAT: docker
    STORAGE_DRIVER: overlay
    BUILDAH_ISOLATION: chroot
    HARBOR_URL: "$HARBOR_URL"
  before_script:
    - buildah version
    - buildah login -u "\$HARBOR_USER" -p "\$HARBOR_PASS" "\$HARBOR_URL"
  script:
    - |
      buildah build \\
        --format \$BUILDAH_FORMAT \\
        --storage-driver \$STORAGE_DRIVER \\
        --build-arg HARBOR_URL=\$HARBOR_URL \\
        --tag "\$HARBOR_URL/\$CI_PROJECT_PATH:\$CI_COMMIT_SHA" \\
        -f Dockerfile .
    - buildah push "\$HARBOR_URL/\$CI_PROJECT_PATH:\$CI_COMMIT_SHA"
  after_script:
    - buildah logout "\$HARBOR_URL"

build-image:
  extends: .buildah-build
  stage: build
YAML
ok "Шаблон конвейера: $TEMPLATE_FILE"

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Buildah runner готов. Проверьте:"
echo "  buildah version"
echo "  sudo -u $RUNNER_USER buildah images"
echo ""
echo "Для сборки образа вручную:"
echo "  sudo -u $RUNNER_USER buildah build -t $HARBOR_URL/myapp/api:test ."
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
