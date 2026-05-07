#!/usr/bin/env bash
# Установка Jenkins с предустановленными плагинами из локальной директории
# Использование: sudo bash install-jenkins-offline.sh [jenkins.war] [plugins_dir] [harbor_url]
set -euo pipefail

JENKINS_WAR="${1:-./jenkins.war}"
PLUGINS_DIR="${2:-./jenkins-plugins}"
HARBOR_URL="${3:-${HARBOR_URL:-harbor.internal.company.local}}"
JENKINS_HOME="${JENKINS_HOME_DIR:-/var/lib/jenkins}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
JENKINS_USER="${JENKINS_USER:-jenkins}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Установка Jenkins (офлайн) ==="
echo "WAR-файл:  $JENKINS_WAR"
echo "Плагины:   $PLUGINS_DIR"
echo "Harbor:    $HARBOR_URL"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"

[ "$(id -u)" -ne 0 ] && { echo "Требуется root: sudo bash $0"; exit 1; }

# --- Проверка Java ---
echo ""
echo "--- Java ---"
if java -version &>/dev/null 2>&1; then
  java_ver=$(java -version 2>&1 | head -1)
  ok "Java найдена: $java_ver"
else
  fail "Java не найдена — установите OpenJDK 11 или 17 из локального зеркала"
  exit 1
fi

# --- WAR-файл ---
echo ""
echo "--- Jenkins WAR ---"
[ -f "$JENKINS_WAR" ] || { fail "WAR не найден: $JENKINS_WAR"; exit 1; }
war_size=$(du -sh "$JENKINS_WAR" | cut -f1)
ok "Jenkins WAR: $JENKINS_WAR ($war_size)"

if [ -f "${JENKINS_WAR}.sha256" ]; then
  sha256sum -c "${JENKINS_WAR}.sha256" 2>/dev/null && ok "SHA-256 проверен" || \
    { fail "SHA-256 не совпадает"; exit 1; }
else
  warn "Файл .sha256 не найден — пропуск проверки"
fi

# --- Пользователь и директории ---
echo ""
echo "--- Подготовка ---"
if ! id "$JENKINS_USER" &>/dev/null; then
  useradd -r -s /bin/false -d "$JENKINS_HOME" -c "Jenkins Service" "$JENKINS_USER"
  ok "Создан пользователь: $JENKINS_USER"
else
  ok "Пользователь уже существует: $JENKINS_USER"
fi
mkdir -p "$JENKINS_HOME"/{plugins,init.groovy.d,workspace} /opt/jenkins

# Копируем WAR
cp "$JENKINS_WAR" /opt/jenkins/jenkins.war
ok "WAR скопирован в /opt/jenkins/jenkins.war"

# --- Установка плагинов ---
echo ""
echo "--- Плагины ---"
if [ -d "$PLUGINS_DIR" ]; then
  plugin_count=$(find "$PLUGINS_DIR" -name "*.jpi" -o -name "*.hpi" 2>/dev/null | wc -l)
  if [ "$plugin_count" -gt 0 ]; then
    cp "$PLUGINS_DIR"/*.jpi "$JENKINS_HOME/plugins/" 2>/dev/null || true
    cp "$PLUGINS_DIR"/*.hpi "$JENKINS_HOME/plugins/" 2>/dev/null || true
    ok "Установлено плагинов: $plugin_count"
  else
    warn "Директория $PLUGINS_DIR пустая — плагины не установлены"
  fi
else
  warn "Директория плагинов не найдена: $PLUGINS_DIR"
  echo "    Подготовьте плагины: jenkins-plugin-manager --war jenkins.war --plugin-file plugins.txt --plugins-dir $PLUGINS_DIR"
fi

# --- Конфигурация JCasC (отключение мастера установки) ---
CASC_FILE="$JENKINS_HOME/jenkins.yaml"
cat > "$CASC_FILE" <<YAML
jenkins:
  numExecutors: 0
  securityRealm:
    local:
      allowsSignup: false
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false

unclassified:
  location:
    adminAddress: ""
    url: "http://$(hostname):$JENKINS_PORT/"
  dockerBuilder:
    dockerHost:
      uri: "unix:///var/run/docker.sock"
  globalLibraries:
    libraries: []

tool:
  dockerTool:
    installations:
      - name: docker
        properties:
          - installSource:
              installers:
                - fromDocker:
                    label: ""
YAML
ok "Конфигурация JCasC создана: $CASC_FILE"

# --- Groovy-скрипт: отключение Update Center ---
mkdir -p "$JENKINS_HOME/init.groovy.d"
cat > "$JENKINS_HOME/init.groovy.d/disable-update-center.groovy" <<'GROOVY'
import jenkins.model.Jenkins
import hudson.model.UpdateSite

def instance = Jenkins.getInstance()

// Отключаем Update Center
instance.getUpdateCenter().getSites().clear()
instance.save()

println("Update Center отключён для закрытого контура")
GROOVY
ok "Update Center отключён"

# --- Groovy-скрипт: настройка Docker реестра ---
cat > "$JENKINS_HOME/init.groovy.d/configure-docker-registry.groovy" <<GROOVY
import jenkins.model.Jenkins
import com.nirima.jenkins.plugins.docker.DockerCloud

// Настройка внутреннего реестра Docker
System.setProperty("hudson.plugins.dockerhub.registry", "https://$HARBOR_URL")
System.setProperty("DOCKER_REGISTRY", "$HARBOR_URL")

println("Docker реестр настроен: $HARBOR_URL")
GROOVY
ok "Реестр Docker настроен на $HARBOR_URL"

# --- Права ---
chown -R "$JENKINS_USER:$JENKINS_USER" "$JENKINS_HOME" /opt/jenkins
ok "Права установлены"

# --- systemd юнит ---
cat > /etc/systemd/system/jenkins.service <<UNIT
[Unit]
Description=Jenkins Automation Server
After=network.target docker.service
Requires=network.target

[Service]
Type=simple
User=$JENKINS_USER
Group=$JENKINS_USER
Environment=JENKINS_HOME=$JENKINS_HOME
Environment=CASC_JENKINS_CONFIG=$CASC_FILE
Environment=JAVA_HOME=$JAVA_HOME
ExecStart=$JAVA_HOME/bin/java \\
  -Djava.awt.headless=true \\
  -Dhudson.model.UpdateCenter.never=true \\
  -Dhudson.security.csrf.DefaultCrumbIssuer.EXCLUDE_SESSION_ID=true \\
  -Djenkins.install.runSetupWizard=false \\
  -Djenkins.model.Jenkins.slaveAgentPort=50000 \\
  -DhttpPort=$JENKINS_PORT \\
  -jar /opt/jenkins/jenkins.war
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable jenkins
ok "systemd юнит создан и включён"

echo ""
echo "--- Запуск ---"
systemctl start jenkins && ok "Jenkins запущен" || warn "Проверьте: journalctl -u jenkins -n 50"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "URL:          http://$(hostname):$JENKINS_PORT"
echo "Данные:       $JENKINS_HOME"
echo "Конфигурация: $CASC_FILE"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
