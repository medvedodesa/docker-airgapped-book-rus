#!/usr/bin/env bash
# Регистрация GitLab Runner с Docker executor для изолированной среды
# Использование: bash register-gitlab-runner.sh <gitlab_url> <registration_token>
set -euo pipefail

GITLAB_URL="${1:-https://gitlab.internal.company.local}"
REG_TOKEN="${2:-}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-docker}"
HARBOR_HOST="${HARBOR_HOST:-harbor.internal.company.local}"
RUNNER_TAG="${RUNNER_TAGS:-docker,internal}"

echo "=== Регистрация GitLab Runner ==="
echo "  GitLab: $GITLAB_URL"
echo "  Имя:    $RUNNER_NAME"
echo "  Теги:   $RUNNER_TAG"

[ -n "$REG_TOKEN" ] || { echo "[FAIL] Токен регистрации не задан"; exit 1; }

command -v gitlab-runner &>/dev/null || {
  echo "[FAIL] gitlab-runner не установлен"
  exit 1
}

# Регистрация runner
echo ""
echo "--- Регистрация ---"
gitlab-runner register \
  --non-interactive \
  --url "$GITLAB_URL" \
  --registration-token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --executor docker \
  --docker-image "${HARBOR_HOST}/base/alpine:3.19" \
  --docker-pull-policy if-not-present \
  --docker-network-mode internal-net \
  --docker-disable-cache false \
  --docker-volumes "/var/run/docker.sock:/var/run/docker.sock" \
  --docker-volumes "/opt/cache:/cache" \
  --tag-list "$RUNNER_TAG" \
  --run-untagged false \
  --locked false \
  --tls-ca-file "/etc/gitlab-runner/certs/ca.crt" \
  2>/dev/null
echo "  [OK] Runner зарегистрирован"

# Настройка concurrent
echo ""
echo "--- Настройка конкурентности ---"
RUNNER_CONFIG="/etc/gitlab-runner/config.toml"
if [ -f "$RUNNER_CONFIG" ]; then
  # Устанавливаем concurrent = 4
  sed -i 's/^concurrent = .*/concurrent = 4/' "$RUNNER_CONFIG" 2>/dev/null || true
  echo "  [OK] concurrent = 4"

  # Добавление pull policy для Harbor
  if ! grep -q "allowed_pull_policies" "$RUNNER_CONFIG" 2>/dev/null; then
    sed -i '/\[runners\.docker\]/a\    allowed_pull_policies = ["if-not-present", "never"]' \
      "$RUNNER_CONFIG" 2>/dev/null || true
    echo "  [OK] allowed_pull_policies = if-not-present, never"
  fi
fi

# Запуск сервиса
echo ""
echo "--- Запуск сервиса ---"
systemctl enable gitlab-runner 2>/dev/null || true
systemctl restart gitlab-runner 2>/dev/null || true
sleep 2
systemctl is-active gitlab-runner &>/dev/null && \
  echo "  [OK] gitlab-runner запущен" || \
  echo "  [WARN] gitlab-runner не запущен"

echo ""
echo "=== Runner зарегистрирован ==="
echo ""
echo "Список зарегистрированных runner-ов:"
echo "  gitlab-runner list"
echo ""
echo "Статус:"
echo "  gitlab-runner verify"
