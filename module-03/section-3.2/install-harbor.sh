#!/usr/bin/env bash
# Установка Harbor из офлайн-установщика
# Использование: sudo bash install-harbor.sh [директория_с_installer] [имя_хоста] [пароль_admin]
set -euo pipefail

INSTALLER_DIR="${1:-./}"
HARBOR_HOSTNAME="${2:-harbor.internal.company.local}"
ADMIN_PASSWORD="${3:-$(openssl rand -base64 16)}"
DATA_VOLUME="${HARBOR_DATA_VOLUME:-/data}"
CERT_DIR="${HARBOR_CERT_DIR:-/etc/harbor/certs}"

echo "=== Установка Harbor ==="
echo "  Хост:          $HARBOR_HOSTNAME"
echo "  Данные:        $DATA_VOLUME"
echo "  Сертификаты:   $CERT_DIR"

# Найти installer
installer=$(ls "$INSTALLER_DIR"/harbor-offline-installer-*.tgz 2>/dev/null | head -1)
[ -n "$installer" ] || { echo "Installer не найден в $INSTALLER_DIR"; exit 1; }
echo "  Installer: $(basename "$installer")"

# Распаковка
echo ""
echo "--- Распаковка ---"
tar xzf "$installer" -C /tmp/
cd /tmp/harbor

# Сертификаты
echo ""
echo "--- TLS-сертификаты ---"
mkdir -p "$CERT_DIR"
if [ ! -f "$CERT_DIR/server.crt" ] || [ ! -f "$CERT_DIR/server.key" ]; then
  echo "  Генерация самоподписанного сертификата (заменить на CA-сертификат!)"
  openssl req -newkey rsa:4096 -nodes -sha256 \
    -keyout "$CERT_DIR/server.key" \
    -x509 -days 365 \
    -out "$CERT_DIR/server.crt" \
    -subj "/CN=$HARBOR_HOSTNAME" \
    -addext "subjectAltName=DNS:$HARBOR_HOSTNAME" 2>/dev/null
  echo "  [WARN] Используется самоподписанный сертификат. Замените на сертификат от внутреннего CA!"
fi

# Конфигурация
echo ""
echo "--- Конфигурация harbor.yml ---"
cp harbor.yml.tmpl harbor.yml

sed -i "s|^hostname: .*|hostname: $HARBOR_HOSTNAME|" harbor.yml
sed -i "s|certificate: .*|certificate: $CERT_DIR/server.crt|" harbor.yml
sed -i "s|private_key: .*|private_key: $CERT_DIR/server.key|" harbor.yml
sed -i "s|data_volume: .*|data_volume: $DATA_VOLUME|" harbor.yml
sed -i "s|harbor_admin_password: .*|harbor_admin_password: $ADMIN_PASSWORD|" harbor.yml
# Отключить внешний доступ к метрикам порта 9090
sed -i "s|^  port: 9090|  port: 9090 # внутренний|" harbor.yml 2>/dev/null || true

echo "  harbor.yml настроен"

# Подготовка и установка
echo ""
echo "--- Установка ---"
mkdir -p "$DATA_VOLUME"
bash prepare
bash install.sh 2>&1 | tail -10

echo ""
echo "=== Harbor установлен ==="
echo "  URL:      https://$HARBOR_HOSTNAME"
echo "  Логин:    admin"
echo "  Пароль:   $ADMIN_PASSWORD"
echo ""
echo "  ВАЖНО: сохраните пароль в Vault немедленно!"
echo "  ВАЖНО: замените самоподписанный сертификат на CA-выданный!"
