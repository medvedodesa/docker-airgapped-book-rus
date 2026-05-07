#!/usr/bin/env bash
# Установка Nexus Repository Manager OSS из локального архива
# Использование: sudo bash install-nexus-offline.sh [nexus.tar.gz] [jdk_home]
set -euo pipefail

NEXUS_ARCHIVE="${1:-./nexus-3-unix.tar.gz}"
JAVA_HOME="${2:-${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}}"
NEXUS_HOME="${NEXUS_HOME:-/opt/nexus}"
NEXUS_DATA="${NEXUS_DATA:-/var/lib/nexus}"
NEXUS_USER="${NEXUS_USER:-nexus}"
NEXUS_PORT="${NEXUS_PORT:-8081}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Установка Nexus Repository OSS (офлайн) ==="
echo "Архив:   $NEXUS_ARCHIVE"
echo "Java:    $JAVA_HOME"
echo "Каталог: $NEXUS_HOME"
echo "Порт:    $NEXUS_PORT"
echo "Дата:    $(date '+%Y-%m-%d %H:%M')"

[ "$(id -u)" -ne 0 ] && { echo "Требуется root: sudo bash $0"; exit 1; }

# --- Java ---
echo ""
echo "--- Java ---"
if [ -x "$JAVA_HOME/bin/java" ]; then
  ok "Java: $($JAVA_HOME/bin/java -version 2>&1 | head -1)"
elif java -version &>/dev/null 2>&1; then
  ok "Java в PATH: $(java -version 2>&1 | head -1)"
  JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
else
  fail "Java не найдена — установите OpenJDK 8+ из локального репозитория"
  exit 1
fi

# --- Архив ---
echo ""
echo "--- Архив Nexus ---"
[ -f "$NEXUS_ARCHIVE" ] || { fail "Архив не найден: $NEXUS_ARCHIVE"; exit 1; }
ok "Архив: $NEXUS_ARCHIVE ($(du -sh "$NEXUS_ARCHIVE" | cut -f1))"

if [ -f "${NEXUS_ARCHIVE}.sha256" ]; then
  sha256sum -c "${NEXUS_ARCHIVE}.sha256" 2>/dev/null && ok "SHA-256 проверен" || { fail "SHA-256 не совпадает"; exit 1; }
else
  warn "Файл .sha256 не найден — пропуск проверки целостности"
fi

# --- Пользователь и директории ---
echo ""
echo "--- Подготовка ---"
if ! id "$NEXUS_USER" &>/dev/null; then
  useradd -r -s /bin/false -d "$NEXUS_HOME" -c "Nexus Repository Service" "$NEXUS_USER"
  ok "Создан пользователь: $NEXUS_USER"
fi
mkdir -p "$NEXUS_HOME" "$NEXUS_DATA"

# --- Распаковка ---
echo ""
echo "--- Распаковка ---"
tar xzf "$NEXUS_ARCHIVE" -C "$NEXUS_HOME" --strip-components=1
ok "Nexus распакован: $NEXUS_HOME"

# --- Настройка ---
echo ""
echo "--- Конфигурация ---"
NEXUS_PROPS="$NEXUS_HOME/etc/nexus-default.properties"
if [ -f "$NEXUS_PROPS" ]; then
  # Порт
  sed -i "s/^application-port=.*/application-port=$NEXUS_PORT/" "$NEXUS_PROPS"
  # Путь к данным
  sed -i "s|nexus-work=.*|nexus-work=$NEXUS_DATA|" "$NEXUS_PROPS" 2>/dev/null || \
    echo "nexus-work=$NEXUS_DATA" >> "$NEXUS_PROPS"
  ok "nexus-default.properties настроен (порт=$NEXUS_PORT, данные=$NEXUS_DATA)"
fi

# Параметры JVM
NEXUS_VMOPTIONS="$NEXUS_HOME/bin/nexus.vmoptions"
if [ -f "$NEXUS_VMOPTIONS" ]; then
  # Рекомендуемая память для production
  cat > "$NEXUS_VMOPTIONS" <<VMOPTS
-Xms1024m
-Xmx1024m
-XX:MaxDirectMemorySize=2048m
-XX:+UnlockDiagnosticVMOptions
-XX:+LogVMOutput
-XX:LogFile=$NEXUS_DATA/log/jvm.log
-XX:-OmitStackTraceInFastThrow
-Djava.net.preferIPv4Stack=true
-Dkaraf.home=.
-Dkaraf.base=.
-Dkaraf.etc=etc/karaf
-Djava.util.logging.config.file=etc/karaf/java.util.logging.properties
-Dkaraf.data=$NEXUS_DATA
-Dkaraf.log=$NEXUS_DATA/log
-Djava.io.tmpdir=$NEXUS_DATA/tmp
VMOPTS
  ok "JVM параметры настроены (1 GB heap)"
fi

# Скрипт запуска — привязка пользователя
NEXUS_BIN="$NEXUS_HOME/bin/nexus"
if [ -f "$NEXUS_BIN" ]; then
  sed -i "s/^#RUN_AS_USER=.*/RUN_AS_USER=$NEXUS_USER/" "$NEXUS_BIN"
  ok "RUN_AS_USER=$NEXUS_USER"
fi

# --- Права ---
chown -R "$NEXUS_USER:$NEXUS_USER" "$NEXUS_HOME" "$NEXUS_DATA"
ok "Права установлены"

# --- systemd юнит ---
cat > /etc/systemd/system/nexus.service <<UNIT
[Unit]
Description=Nexus Repository Manager
After=network.target
Requires=network.target

[Service]
Type=forking
LimitNOFILE=65536
User=$NEXUS_USER
Group=$NEXUS_USER
Environment=JAVA_HOME=$JAVA_HOME
ExecStart=$NEXUS_BIN start
ExecStop=$NEXUS_BIN stop
PIDFile=$NEXUS_DATA/nexus.pid
Restart=on-failure
RestartSec=10s
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable nexus
ok "systemd юнит создан и включён"

# --- Запуск ---
echo ""
echo "--- Запуск ---"
systemctl start nexus

echo "Ожидание готовности (до 120 секунд)..."
for i in $(seq 1 24); do
  if curl -sf --max-time 5 "http://localhost:$NEXUS_PORT/service/rest/v1/status" >/dev/null 2>&1; then
    ok "Nexus готов (попытка $i)"
    break
  fi
  sleep 5
  [ "$i" -eq 24 ] && warn "Nexus не ответил за 120 с — проверьте: journalctl -u nexus -n 50"
done

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "URL:           http://$(hostname):$NEXUS_PORT"
echo "Данные:        $NEXUS_DATA"
echo "Пароль admin:  $(cat $NEXUS_DATA/admin.password 2>/dev/null || echo 'см. $NEXUS_DATA/admin.password')"
echo ""
echo "Следующий шаг: bash setup-nexus-mirrors.sh http://$(hostname):$NEXUS_PORT <пароль>"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
