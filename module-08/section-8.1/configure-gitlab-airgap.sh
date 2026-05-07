#!/usr/bin/env bash
# Настройка GitLab для работы в изолированной среде (отключение внешних сервисов)
# Использование: bash configure-gitlab-airgap.sh
set -euo pipefail

echo "=== Настройка GitLab для изолированной среды ==="

command -v gitlab-rails &>/dev/null || {
  echo "[FAIL] GitLab не установлен или не в PATH"
  exit 1
}

# Отключение внешних сервисов через Rails console
echo ""
echo "--- Отключение интеграций ---"
gitlab-rails runner '
ApplicationSetting.current.update!(
  usage_ping_enabled: false,
  version_check_enabled: false,
  gravatar_enabled: false,
  spam_check_enabled: false,
  container_registry_vendor_plan: nil,
  snowplow_enabled: false,
  error_tracking_enabled: false
)
puts "OK"
' 2>/dev/null && echo "  [OK] Внешние интеграции отключены" || \
  echo "  [WARN] Не удалось настроить через Rails runner"

# Блокировка исходящих соединений через gitlab.rb
echo ""
echo "--- Настройка outbound блокировки ---"
cat >> /etc/gitlab/gitlab.rb << 'CONF'

# Изолированная среда — блокировка исходящих запросов
gitlab_rails['outbound_local_requests_allowlist'] = []
gitlab_rails['dns_rebinding_protection_enabled'] = true

# Отключение авто-обновлений runner-ов
gitlab_rails['runner_auto_update_enabled'] = false
CONF
echo "  [OK] Добавлено в /etc/gitlab/gitlab.rb"

# Настройка Docker Registry (отключение pull из интернета)
echo ""
echo "--- Настройка Container Registry ---"
cat >> /etc/gitlab/gitlab.rb << 'CONF'

# Container Registry — только внутренний
registry_external_url 'https://registry.internal.company.local'
registry['enable'] = true
CONF
echo "  [OK] Registry настроен на внутренний домен"

# Применение конфигурации
echo ""
echo "--- Применение конфигурации ---"
gitlab-ctl reconfigure 2>&1 | tail -3
gitlab-ctl restart 2>&1 | tail -3
echo "  [OK] GitLab перезапущен"

# Проверка статуса сервисов
echo ""
echo "--- Статус сервисов ---"
gitlab-ctl status 2>/dev/null | grep -E "run|down" | sed 's/^/  /'

echo ""
echo "=== GitLab настроен для изолированной среды ==="
echo ""
echo "Проверка:"
echo "  curl -k https://$(gitlab-rails runner 'puts Gitlab.config.gitlab.host' 2>/dev/null | tail -1)/api/v4/version"
