#!/usr/bin/env bash
# Установка GitLab CE из локального пакета в изолированной среде
# Использование: bash install-gitlab-offline.sh [deb|rpm] [путь_к_пакету]
set -euo pipefail

PKG_TYPE="${1:-}"
PKG_PATH="${2:-}"
GITLAB_DOMAIN="${GITLAB_DOMAIN:-gitlab.internal.company.local}"
GITLAB_PORT="${GITLAB_PORT:-443}"

echo "=== Установка GitLab CE (офлайн) ==="

# Определение типа пакета по дистрибутиву
if [ -z "$PKG_TYPE" ]; then
  if command -v apt-get &>/dev/null; then
    PKG_TYPE="deb"
  elif command -v rpm &>/dev/null; then
    PKG_TYPE="rpm"
  else
    echo "[FAIL] Не удалось определить тип пакета. Укажите deb или rpm"
    exit 1
  fi
fi

# Поиск пакета
if [ -z "$PKG_PATH" ]; then
  PKG_PATH=$(find /tmp /opt/packages -name "gitlab-ce*.${PKG_TYPE}" 2>/dev/null | head -1 || true)
fi

[ -n "$PKG_PATH" ] && [ -f "$PKG_PATH" ] || {
  echo "[FAIL] Пакет GitLab CE не найден. Укажите путь к пакету"
  exit 1
}

echo "  Пакет: $PKG_PATH"
echo "  Тип:   $PKG_TYPE"

# Зависимости (должны быть уже установлены офлайн)
echo ""
echo "--- Проверка зависимостей ---"
for cmd in curl openssl; do
  command -v "$cmd" &>/dev/null && echo "  [OK] $cmd" || echo "  [WARN] $cmd не найден"
done

# Установка
echo ""
echo "--- Установка пакета ---"
case "$PKG_TYPE" in
  deb)
    DEBIAN_FRONTEND=noninteractive dpkg -i "$PKG_PATH" 2>&1 | tail -5
    ;;
  rpm)
    rpm -ivh "$PKG_PATH" 2>&1 | tail -5
    ;;
esac
echo "  [OK] Пакет установлен"

# Предварительная конфигурация
echo ""
echo "--- Конфигурация ---"
cat > /etc/gitlab/gitlab.rb << GITLABCONF
external_url 'https://${GITLAB_DOMAIN}'

# Отключение внешних сервисов
gitlab_rails['usage_ping_enabled'] = false
gitlab_rails['sentry_enabled'] = false
gitlab_rails['gitlab_kas_enabled'] = false

# TLS — используем Let's Encrypt в офлайн среде — отключаем
letsencrypt['enable'] = false

# TLS — свои сертификаты
nginx['ssl_certificate'] = "/etc/gitlab/ssl/${GITLAB_DOMAIN}.crt"
nginx['ssl_certificate_key'] = "/etc/gitlab/ssl/${GITLAB_DOMAIN}.key"

# Почта (внутренний SMTP)
gitlab_rails['smtp_enable'] = true
gitlab_rails['smtp_address'] = "smtp.internal.company.local"
gitlab_rails['smtp_port'] = 25

# Резервное копирование
gitlab_rails['backup_path'] = "/var/opt/gitlab/backups"
gitlab_rails['backup_keep_time'] = 604800

# Производительность
puma['worker_timeout'] = 60
sidekiq['concurrency'] = 10
GITLABCONF

mkdir -p /etc/gitlab/ssl
echo "  [OK] /etc/gitlab/gitlab.rb создан"
echo "  [!] Поместите TLS-сертификаты в /etc/gitlab/ssl/"

echo ""
echo "=== Установка завершена ==="
echo ""
echo "После размещения TLS-сертификатов:"
echo "  gitlab-ctl reconfigure"
echo "  gitlab-ctl status"
echo ""
echo "Настройка изолированной среды:"
echo "  bash configure-gitlab-airgap.sh"
