#!/usr/bin/env bash
# Установка SPIRE (SPIFFE Runtime Environment) в закрытом контуре.
# Запускать после переноса архива с машины с доступом к интернету.
#
# Использование: sudo bash install-spire-offline.sh <архив.tar.gz>
# Пример: sudo bash install-spire-offline.sh spire-offline-1.9.0.tar.gz

set -euo pipefail

ARCHIVE="${1:-}"
INSTALL_DIR="/usr/local/bin"
SPIRE_DATA="/var/lib/spire"
SPIRE_CONF="/etc/spire"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET} $1"; }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Требуются права root"
[ -n "$ARCHIVE" ] || fail "Укажите архив: $0 spire-offline-X.X.X.tar.gz"
[ -f "$ARCHIVE" ] || fail "Архив не найден: $ARCHIVE"

log "Установка SPIRE из: $ARCHIVE"

# Распаковка
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
tar xzf "$ARCHIVE" -C "$TMPDIR"

# Поиск бинарных файлов
SPIRE_BIN=$(find "$TMPDIR" -name "spire-server" -exec dirname {} \; 2>/dev/null | head -1)
[ -n "$SPIRE_BIN" ] || fail "Бинарные файлы SPIRE не найдены в архиве"

# Установка бинарных файлов
log "Установка бинарных файлов в $INSTALL_DIR..."
for bin in spire-server spire-agent; do
    if [ -f "$SPIRE_BIN/$bin" ]; then
        cp "$SPIRE_BIN/$bin" "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/$bin"
        log "  Установлен: $bin"
    fi
done

# Создание каталогов
log "Создание каталогов..."
mkdir -p "$SPIRE_DATA/server/data" \
         "$SPIRE_DATA/agent/data" \
         "$SPIRE_CONF" \
         "/tmp/spire-agent/public"

# Создание конфигурации SPIRE Server (базовая)
if [ ! -f "$SPIRE_CONF/server.conf" ]; then
    cat > "$SPIRE_CONF/server.conf" << 'EOF'
server {
    bind_address = "0.0.0.0"
    bind_port = "8081"
    trust_domain = "company.local"
    data_dir = "/var/lib/spire/server/data"
    log_level = "INFO"
    ca_ttl = "87600h"
    default_x509_svid_ttl = "1h"
}
plugins {
    DataStore "sql" {
        plugin_data {
            database_type = "sqlite3"
            connection_string = "/var/lib/spire/server/data/datastore.sqlite3"
        }
    }
    KeyManager "disk" {
        plugin_data { keys_path = "/var/lib/spire/server/data/keys.json" }
    }
    NodeAttestor "join_token" { plugin_data {} }
}
health_checks {
    listener_enabled = true
    bind_address = "127.0.0.1"
    bind_port = "8080"
}
EOF
    log "Создан шаблон конфигурации: $SPIRE_CONF/server.conf"
    log "  Отредактируйте trust_domain под ваш домен"
fi

# Создание systemd unit для SPIRE Server
cat > /etc/systemd/system/spire-server.service << EOF
[Unit]
Description=SPIRE Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=$INSTALL_DIR/spire-server run -config $SPIRE_CONF/server.conf
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log "Systemd unit создан: spire-server.service"

# Проверка
spire-server --version 2>/dev/null && log "spire-server установлен" || fail "Ошибка установки spire-server"
spire-agent --version 2>/dev/null && log "spire-agent установлен"   || fail "Ошибка установки spire-agent"

echo
echo "Следующие шаги:"
echo "  1. Отредактируйте $SPIRE_CONF/server.conf (trust_domain)"
echo "  2. Запустите: systemctl start spire-server"
echo "  3. Создайте join token: spire-server token generate -spiffeID spiffe://company.local/agent/host-01"
echo "  4. Запустите агент с токеном на каждом Docker-хосте"
