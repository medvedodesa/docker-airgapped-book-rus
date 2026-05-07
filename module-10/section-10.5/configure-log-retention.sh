#!/usr/bin/env bash
# Настройка политик хранения логов: Docker, Loki, journald
# Использование: bash configure-log-retention.sh [retention_days]
set -euo pipefail

RETENTION_DAYS="${1:-30}"
MAX_SIZE_DOCKER="${MAX_SIZE_DOCKER:-10m}"
MAX_FILE_DOCKER="${MAX_FILE_DOCKER:-5}"

echo "=== Настройка хранения логов ==="
echo "  Хранение: $RETENTION_DAYS дней"

PASS=0; WARN=0

ok()   { echo "  [OK] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }

# Docker logging driver
echo ""
echo "--- Docker logging ---"
DAEMON_JSON="/etc/docker/daemon.json"
if [ -f "$DAEMON_JSON" ]; then
  python3 - << PYEOF 2>/dev/null
import json
with open("$DAEMON_JSON") as f:
    d = json.load(f)

d.setdefault("log-driver", "json-file")
d.setdefault("log-opts", {})
d["log-opts"]["max-size"] = "$MAX_SIZE_DOCKER"
d["log-opts"]["max-file"] = "$MAX_FILE_DOCKER"
d["log-opts"]["compress"] = "true"

with open("$DAEMON_JSON", "w") as f:
    json.dump(d, f, indent=2)
print("updated")
PYEOF
  ok "daemon.json обновлён (max-size=${MAX_SIZE_DOCKER}, max-file=${MAX_FILE_DOCKER})"
  echo "  Перезапустите Docker для применения: systemctl restart docker"
else
  warn "daemon.json не найден"
fi

# journald
echo ""
echo "--- journald ---"
JOURNALD_CONF="/etc/systemd/journald.conf"
if [ -f "$JOURNALD_CONF" ]; then
  # Обновление или добавление параметров
  for param in "SystemMaxUse=2G" "SystemKeepFree=500M" "MaxRetentionSec=${RETENTION_DAYS}day" "Compress=yes"; do
    key=$(echo "$param" | cut -d= -f1)
    if grep -q "^${key}=" "$JOURNALD_CONF" 2>/dev/null; then
      sed -i "s/^${key}=.*/${param}/" "$JOURNALD_CONF"
    elif grep -q "^#${key}=" "$JOURNALD_CONF" 2>/dev/null; then
      sed -i "s/^#${key}=.*/${param}/" "$JOURNALD_CONF"
    else
      echo "$param" >> "$JOURNALD_CONF"
    fi
  done
  ok "journald.conf: MaxRetentionSec=${RETENTION_DAYS}day, SystemMaxUse=2G"
  systemctl restart systemd-journald 2>/dev/null && ok "journald перезапущен" || warn "Перезапустите journald вручную"
fi

# Loki retention
echo ""
echo "--- Loki retention ---"
LOKI_CONFIG_DIR="${LOKI_CONFIG_DIR:-/opt/monitoring/config/loki}"
LOKI_CONF="$LOKI_CONFIG_DIR/loki.yml"
if [ -f "$LOKI_CONF" ]; then
  # Обновление retention_period
  python3 - << PYEOF 2>/dev/null
import re
with open("$LOKI_CONF") as f:
    content = f.read()
content = re.sub(r'retention_period: \S+', f'retention_period: ${RETENTION_DAYS}d', content)
with open("$LOKI_CONF", "w") as f:
    f.write(content)
PYEOF
  ok "Loki: retention_period=${RETENTION_DAYS}d"
else
  warn "Конфиг Loki не найден в $LOKI_CONFIG_DIR"
fi

# Очистка старых логов вручную
echo ""
echo "--- Очистка старых логов ---"
journalctl --vacuum-time="${RETENTION_DAYS}d" 2>/dev/null && ok "Старые записи journald удалены" || true
docker system prune --volumes -f 2>/dev/null | grep -E "reclaimed" || true

echo ""
echo "=== Итог: OK=$PASS  WARN=$WARN ==="
