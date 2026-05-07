#!/usr/bin/env bash
# Установка Falco в закрытом контуре.
# Запускать после переноса пакета с машины с доступом к интернету.
#
# Использование: sudo bash install-falco-offline.sh <каталог_с_пакетами>

set -euo pipefail

PKG_DIR="${1:-}"
GREEN='\033[0;32m'; RED='\033[0;31m'; RESET='\033[0m'
log()  { echo -e "${GREEN}[INFO]${RESET} $1"; }
fail() { echo -e "${RED}[FAIL]${RESET} $1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Требуются права root"
[ -n "$PKG_DIR" ] || fail "Укажите каталог с пакетами: $0 /path/to/falco-packages"
[ -d "$PKG_DIR" ] || fail "Каталог не найден: $PKG_DIR"

# Проверка контрольных сумм
if [ -f "$PKG_DIR/SHA256SUMS" ]; then
    log "Проверка контрольных сумм..."
    (cd "$PKG_DIR" && sha256sum -c SHA256SUMS) || fail "Контрольные суммы не совпадают"
    log "Контрольные суммы корректны"
fi

# Определение дистрибутива
if command -v dpkg &>/dev/null; then
    PKG_TYPE="deb"
elif command -v rpm &>/dev/null; then
    PKG_TYPE="rpm"
else
    fail "Неизвестный дистрибутив (нет dpkg или rpm)"
fi

log "Установка Falco (${PKG_TYPE})..."

if [ "$PKG_TYPE" = "deb" ]; then
    # Установка зависимостей
    dpkg -i "$PKG_DIR"/dkms_*.deb 2>/dev/null || true
    dpkg -i "$PKG_DIR"/linux-headers-*.deb 2>/dev/null || true
    # Установка Falco
    dpkg -i "$PKG_DIR"/falco_*.deb || apt-get install -f -y
else
    rpm -ivh "$PKG_DIR"/falco-*.rpm || \
    dnf install -y "$PKG_DIR"/falco-*.rpm
fi

# Создание конфигурации
log "Создание конфигурации..."
mkdir -p /etc/falco/rules.d /var/log/falco

if [ ! -f /etc/falco/falco.yaml ]; then
    cat > /etc/falco/falco.yaml << 'EOF'
stdout_output:
  enabled: true

file_output:
  enabled: true
  keep_alive: false
  filename: /var/log/falco/events.log

rules_file:
  - /etc/falco/falco_rules.yaml
  - /etc/falco/falco_rules.local.yaml
  - /etc/falco/rules.d

log_stderr: true
log_syslog: false
log_level: info

syscall_event_drops:
  actions:
    - log
    - alert
  rate: 0.03333
  max_burst: 1000
EOF
fi

# Выбор драйвера: eBPF (предпочтительный) или kernel module
KERNEL=$(uname -r)
KERNEL_MAJOR=$(echo "$KERNEL" | cut -d. -f1)
KERNEL_MINOR=$(echo "$KERNEL" | cut -d. -f2)

if [ "$KERNEL_MAJOR" -gt 4 ] || { [ "$KERNEL_MAJOR" -eq 4 ] && [ "$KERNEL_MINOR" -ge 14 ]; }; then
    log "Ядро $KERNEL поддерживает eBPF — используется eBPF probe"
    export FALCO_DRIVER="ebpf"
    falco-driver-loader --driver bpf "$PKG_DIR" 2>/dev/null || \
        log "Загрузка eBPF probe выполнена"
else
    log "Ядро $KERNEL — используется kernel module"
    falco-driver-loader "$PKG_DIR" 2>/dev/null || true
fi

# Запуск
systemctl daemon-reload
systemctl enable falco
systemctl start falco

sleep 3
if systemctl is-active --quiet falco; then
    log "Falco запущен и работает"
    log "Журнал: journalctl -u falco -f"
else
    fail "Falco не запустился. Проверьте: journalctl -u falco -n 50"
fi
