#!/usr/bin/env bash
# Установка TeamCity Server и Agent из локального архива
# Отключение автообновлений, настройка внутреннего реестра Docker
# Использование: sudo bash install-teamcity-offline.sh [архив_teamcity.tar.gz] [harbor_url]
set -euo pipefail

TC_ARCHIVE="${1:-./TeamCity.tar.gz}"
HARBOR_URL="${2:-${HARBOR_URL:-harbor.internal.company.local}}"
TC_HOME="${TC_HOME:-/opt/teamcity}"
TC_DATA="${TC_DATA:-/var/lib/teamcity}"
TC_USER="${TC_USER:-teamcity}"
TC_PORT="${TC_PORT:-8111}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Установка TeamCity (офлайн) ==="
echo "Архив:   $TC_ARCHIVE"
echo "Harbor:  $HARBOR_URL"
echo "Каталог: $TC_HOME"
echo "Дата:    $(date '+%Y-%m-%d %H:%M')"

[ "$(id -u)" -ne 0 ] && { echo "Требуется root: sudo bash $0"; exit 1; }

# --- Проверка архива ---
echo ""
echo "--- Архив TeamCity ---"
[ -f "$TC_ARCHIVE" ] || { fail "Архив не найден: $TC_ARCHIVE"; exit 1; }
ok "Архив найден: $TC_ARCHIVE ($(du -sh "$TC_ARCHIVE" | cut -f1))"

# SHA-256
if [ -f "${TC_ARCHIVE}.sha256" ]; then
  if sha256sum -c "${TC_ARCHIVE}.sha256" 2>/dev/null; then
    ok "SHA-256 проверен"
  else
    fail "SHA-256 не совпадает — архив повреждён"
    exit 1
  fi
else
  warn "Файл ${TC_ARCHIVE}.sha256 не найден — пропуск проверки целостности"
fi

# --- Пользователь и директории ---
echo ""
echo "--- Подготовка ---"
if ! id "$TC_USER" &>/dev/null; then
  useradd -r -s /bin/false -d "$TC_HOME" -c "TeamCity Service" "$TC_USER"
  ok "Создан пользователь: $TC_USER"
else
  ok "Пользователь уже существует: $TC_USER"
fi

mkdir -p "$TC_HOME" "$TC_DATA"/{logs,config,system}

# --- Распаковка ---
echo ""
echo "--- Распаковка ---"
tar xzf "$TC_ARCHIVE" -C "$TC_HOME" --strip-components=1
ok "Распакован в $TC_HOME"

# --- Отключение автообновлений и внешних запросов ---
echo ""
echo "--- Конфигурация для закрытого контура ---"
TC_PROPERTIES="$TC_DATA/config/teamcity-startup.properties"
mkdir -p "$(dirname "$TC_PROPERTIES")"
cat > "$TC_PROPERTIES" <<PROPS
# TeamCity: отключение внешних запросов для закрытого контура
teamcity.startup.maintenance=false
teamcity.updateConfig.enabled=false
teamcity.plugins.updateEnabled=false
teamcity.license.statisticsEnabled=false
teamcity.server.http.port=$TC_PORT
teamcity.agent.ownAddress=localhost
PROPS
ok "Автообновления и статистика отключены"

# Внутренний реестр Docker для агента
TC_AGENT_PROPS="$TC_HOME/buildAgent/conf/buildAgent.dist.properties"
AGENT_PROPS="$TC_HOME/buildAgent/conf/buildAgent.properties"
if [ -f "$TC_AGENT_PROPS" ]; then
  cp "$TC_AGENT_PROPS" "$AGENT_PROPS"
  # Настройка Docker реестра
  cat >> "$AGENT_PROPS" <<APROPS

# Внутренний реестр Docker
env.DOCKER_REGISTRY=$HARBOR_URL
env.DOCKER_OPTS=--registry-mirror=https://$HARBOR_URL
APROPS
  ok "Агент настроен на Harbor: $HARBOR_URL"
fi

# --- Права ---
chown -R "$TC_USER:$TC_USER" "$TC_HOME" "$TC_DATA"
ok "Права установлены для $TC_USER"

# --- systemd юнит для Server ---
cat > /etc/systemd/system/teamcity-server.service <<UNIT
[Unit]
Description=TeamCity Server
After=network.target docker.service
Requires=network.target

[Service]
Type=forking
User=$TC_USER
Group=$TC_USER
ExecStart=$TC_HOME/bin/teamcity-server.sh start
ExecStop=$TC_HOME/bin/teamcity-server.sh stop
PIDFile=$TC_HOME/logs/teamcity.pid
WorkingDirectory=$TC_HOME
Environment=TEAMCITY_DATA_PATH=$TC_DATA
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
UNIT

# --- systemd юнит для Agent ---
cat > /etc/systemd/system/teamcity-agent.service <<UNIT
[Unit]
Description=TeamCity Build Agent
After=network.target teamcity-server.service

[Service]
Type=forking
User=$TC_USER
Group=$TC_USER
ExecStart=$TC_HOME/buildAgent/bin/agent.sh start
ExecStop=$TC_HOME/buildAgent/bin/agent.sh stop
WorkingDirectory=$TC_HOME/buildAgent
Restart=on-failure
RestartSec=15s

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable teamcity-server
ok "systemd юниты созданы и включены"

# --- Запуск ---
echo ""
echo "--- Запуск ---"
systemctl start teamcity-server && ok "TeamCity Server запущен" || warn "Запуск не удался — проверьте $TC_DATA/logs/teamcity-server.log"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Доступен по: http://$(hostname):$TC_PORT"
echo "Данные:      $TC_DATA"
echo "Журнал:      $TC_DATA/logs/teamcity-server.log"
echo ""
echo "Первый запуск: откройте браузер, примите лицензию, создайте администратора"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
