#!/usr/bin/env bash
# Настройка GitLab Runner: ограничение образов, отключение привилегий, лимиты ресурсов
# Использование: sudo bash configure-runner-security.sh [harbor_url] [runner_config]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-harbor.internal.company.local}}"
RUNNER_CONFIG="${2:-${GITLAB_RUNNER_CONFIG:-/etc/gitlab-runner/config.toml}}"
RUNNER_USER="${RUNNER_USER:-gitlab-runner}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Настройка безопасности GitLab Runner ==="
echo "Harbor:  $HARBOR_URL"
echo "Конфиг:  $RUNNER_CONFIG"
echo "Дата:    $(date '+%Y-%m-%d %H:%M')"

# --- Проверка наличия GitLab Runner ---
echo ""
echo "--- GitLab Runner ---"
if ! command -v gitlab-runner &>/dev/null; then
  fail "gitlab-runner не найден в PATH"
  exit 1
fi
ok "gitlab-runner: $(gitlab-runner --version 2>/dev/null | grep Version | awk '{print $2}')"

if [ ! -f "$RUNNER_CONFIG" ]; then
  fail "Конфигурационный файл не найден: $RUNNER_CONFIG"
  echo "    Сначала зарегистрируйте Runner: gitlab-runner register"
  exit 1
fi

# --- Резервная копия ---
cp "$RUNNER_CONFIG" "${RUNNER_CONFIG}.backup.$(date +%Y%m%d%H%M%S)"
ok "Резервная копия создана"

# --- Применение настроек безопасности через Python ---
echo ""
echo "--- Применение политик безопасности ---"
python3 - "$RUNNER_CONFIG" "$HARBOR_URL" <<'PYEOF'
import sys, re

config_file = sys.argv[1]
harbor_url  = sys.argv[2]

with open(config_file) as f:
    content = f.read()

# 1. Отключаем privileged mode
content = re.sub(r'privileged\s*=\s*true', 'privileged = false', content)

# 2. Добавляем allowed_images (только Harbor) если не задано
if 'allowed_images' not in content:
    # Добавляем после [runners.docker]
    content = content.replace(
        '[runners.docker]',
        f'[runners.docker]\n  allowed_images = ["{harbor_url}/*"]\n  allowed_services = []'
    )
else:
    # Обновляем существующий список
    content = re.sub(
        r'allowed_images\s*=\s*\[.*?\]',
        f'allowed_images = ["{harbor_url}/*"]',
        content, flags=re.DOTALL
    )

# 3. Устанавливаем pull_policy = if-not-present (не тянуть из интернета)
if 'pull_policy' not in content:
    content = content.replace(
        '[runners.docker]',
        '[runners.docker]\n  pull_policy = ["if-not-present"]'
    )

# 4. Лимиты ресурсов контейнеров заданий
if 'memory' not in content:
    content = content.replace(
        '[runners.docker]',
        '[runners.docker]\n  memory = "2g"\n  memory_swap = "2g"\n  cpus = "2"'
    )

# 5. Отключаем монтирование /var/run/docker.sock (если не задано явно)
content = re.sub(
    r'volumes\s*=\s*\[([^\]]*)/var/run/docker\.sock[^\]]*\]',
    lambda m: m.group(0).replace('/var/run/docker.sock:/var/run/docker.sock', ''),
    content
)

# 6. network_mode: изолированная сеть
if 'network_mode' not in content:
    content = content.replace(
        '[runners.docker]',
        '[runners.docker]\n  network_mode = "bridge"'
    )

with open(config_file, 'w') as f:
    f.write(content)

print(f"[OK] Конфигурация обновлена: {config_file}")
PYEOF

ok "Настройки безопасности применены"

# --- Верификация ---
echo ""
echo "--- Верификация ---"

# Privileged
if grep -q "privileged = false" "$RUNNER_CONFIG" || ! grep -q "privileged = true" "$RUNNER_CONFIG"; then
  ok "privileged = false"
else
  fail "privileged остался true — исправьте вручную"
fi

# Allowed images
if grep -q "allowed_images" "$RUNNER_CONFIG"; then
  allowed=$(grep "allowed_images" "$RUNNER_CONFIG" | head -1)
  ok "allowed_images: $allowed"
  if echo "$allowed" | grep -q "$HARBOR_URL"; then
    ok "allowed_images содержит $HARBOR_URL"
  else
    warn "allowed_images не содержит $HARBOR_URL — проверьте"
  fi
else
  warn "allowed_images не задан"
fi

# Pull policy
if grep -q "pull_policy" "$RUNNER_CONFIG"; then
  ok "pull_policy настроен"
else
  warn "pull_policy не задан"
fi

# --- Проверка socket mount ---
echo ""
echo "--- Проверка Docker socket ---"
if grep -q "/var/run/docker.sock" "$RUNNER_CONFIG"; then
  warn "Docker socket смонтирован — рекомендуется использовать Kaniko или Buildah вместо DinD"
else
  ok "Docker socket не смонтирован в конфигурации Runner"
fi

# --- Перезапуск Runner ---
echo ""
echo "--- Перезапуск ---"
if systemctl is-active gitlab-runner &>/dev/null 2>&1; then
  systemctl restart gitlab-runner && ok "gitlab-runner перезапущен" || warn "Перезапуск не удался"
elif command -v gitlab-runner &>/dev/null; then
  gitlab-runner restart &>/dev/null 2>&1 && ok "gitlab-runner перезапущен" || warn "Перезапуск не удался"
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Конфигурация: $RUNNER_CONFIG"
echo "Проверьте:    gitlab-runner verify"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
