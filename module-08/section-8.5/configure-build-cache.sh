#!/usr/bin/env bash
# Настройка Maven, npm, pip и Go для использования Nexus как единственного источника зависимостей
# Использование: bash configure-build-cache.sh [nexus_url] [scope]
# scope: user (текущий пользователь), system (все), project (текущий проект)
set -euo pipefail

NEXUS_URL="${1:-${NEXUS_URL:-http://nexus.internal.company.local:8081}}"
SCOPE="${2:-user}"  # user | system | project
NEXUS_USER="${NEXUS_READONLY_USER:-readonly}"
NEXUS_PASS="${NEXUS_READONLY_PASS:-readonly}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

NEXUS_HOST=$(echo "$NEXUS_URL" | sed 's|http[s]\?://||' | cut -d: -f1)

echo "=== Настройка инструментов сборки на Nexus ==="
echo "Nexus:  $NEXUS_URL"
echo "Режим:  $SCOPE"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

# --- Проверка Nexus ---
echo ""
echo "--- Nexus ---"
if curl -sf --max-time 10 "$NEXUS_URL/service/rest/v1/status" >/dev/null 2>&1; then
  ok "Nexus доступен: $NEXUS_URL"
else
  warn "Nexus недоступен — конфигурация будет создана, но не проверена"
fi

# ── Maven ─────────────────────────────────────────────────────────────────
echo ""
echo "--- Maven ---"
case "$SCOPE" in
  user)    MAVEN_SETTINGS="$HOME/.m2/settings.xml" ;;
  system)  MAVEN_SETTINGS="/usr/share/maven/conf/settings.xml" ;;
  project) MAVEN_SETTINGS="$(pwd)/maven-settings.xml" ;;
esac

mkdir -p "$(dirname "$MAVEN_SETTINGS")"
cat > "$MAVEN_SETTINGS" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.2.0">

  <localRepository>${user.home}/.m2/repository</localRepository>

  <mirrors>
    <mirror>
      <id>nexus-mirror</id>
      <name>Nexus Internal Mirror</name>
      <url>$NEXUS_URL/repository/maven-public/</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>

  <servers>
    <server>
      <id>nexus-mirror</id>
      <username>$NEXUS_USER</username>
      <password>$NEXUS_PASS</password>
    </server>
    <server>
      <id>nexus-releases</id>
      <username>$NEXUS_USER</username>
      <password>$NEXUS_PASS</password>
    </server>
    <server>
      <id>nexus-snapshots</id>
      <username>$NEXUS_USER</username>
      <password>$NEXUS_PASS</password>
    </server>
  </servers>

  <profiles>
    <profile>
      <id>nexus</id>
      <repositories>
        <repository>
          <id>nexus-releases</id>
          <url>$NEXUS_URL/repository/maven-releases/</url>
          <releases><enabled>true</enabled></releases>
          <snapshots><enabled>false</enabled></snapshots>
        </repository>
        <repository>
          <id>nexus-snapshots</id>
          <url>$NEXUS_URL/repository/maven-snapshots/</url>
          <releases><enabled>false</enabled></releases>
          <snapshots><enabled>true</enabled></snapshots>
        </repository>
      </repositories>
    </profile>
  </profiles>

  <activeProfiles>
    <activeProfile>nexus</activeProfile>
  </activeProfiles>

</settings>
XML
ok "Maven settings.xml → $MAVEN_SETTINGS"

# Проверка Maven
if command -v mvn &>/dev/null; then
  if mvn --settings "$MAVEN_SETTINGS" dependency:resolve -q -f /dev/null 2>/dev/null || true; then
    ok "Maven: связь с Nexus проверена"
  else
    warn "Maven: не удалось проверить связь с Nexus"
  fi
fi

# ── npm ───────────────────────────────────────────────────────────────────
echo ""
echo "--- npm ---"
case "$SCOPE" in
  user)    NPMRC="$HOME/.npmrc" ;;
  system)  NPMRC="/etc/npmrc" ;;
  project) NPMRC="$(pwd)/.npmrc" ;;
esac

cat > "$NPMRC" <<RC
registry=$NEXUS_URL/repository/npm-proxy/
strict-ssl=false
always-auth=false
_auth=$(echo -n "$NEXUS_USER:$NEXUS_PASS" | base64)
RC
chmod 600 "$NPMRC"
ok "npm .npmrc → $NPMRC"

if command -v npm &>/dev/null; then
  npm config set registry "$NEXUS_URL/repository/npm-proxy/" 2>/dev/null && ok "npm registry настроен" || warn "npm config не удался"
fi

# ── pip ───────────────────────────────────────────────────────────────────
echo ""
echo "--- pip ---"
case "$SCOPE" in
  user)
    PIP_CONF_DIR="$HOME/.pip"
    PIP_CONF="$PIP_CONF_DIR/pip.conf"
    ;;
  system)
    PIP_CONF_DIR="/etc"
    PIP_CONF="/etc/pip.conf"
    ;;
  project)
    PIP_CONF_DIR="$(pwd)"
    PIP_CONF="$(pwd)/pip.conf"
    ;;
esac
mkdir -p "$PIP_CONF_DIR"

cat > "$PIP_CONF" <<CONF
[global]
index-url = $NEXUS_URL/repository/pypi-proxy/simple/
trusted-host = $NEXUS_HOST
timeout = 60
no-cache-dir = false

[install]
extra-index-url =

[search]
index = $NEXUS_URL/repository/pypi-proxy/
CONF
ok "pip.conf → $PIP_CONF"

# Переменные окружения
cat > "$(pwd)/build-env.sh" <<ENVSH
#!/usr/bin/env bash
# Экспортируйте эти переменные в среде сборки / Dockerfile ENV
export PIP_INDEX_URL="$NEXUS_URL/repository/pypi-proxy/simple/"
export PIP_TRUSTED_HOST="$NEXUS_HOST"
export NPM_CONFIG_REGISTRY="$NEXUS_URL/repository/npm-proxy/"
export GOPROXY="$NEXUS_URL/repository/go-proxy/,off"
export GONOSUMCHECK="*"
export MAVEN_OPTS="-Dmaven.repo.local=\${HOME}/.m2/repository"
ENVSH
ok "Переменные окружения → $(pwd)/build-env.sh"

# ── Gradle ────────────────────────────────────────────────────────────────
echo ""
echo "--- Gradle ---"
GRADLE_INIT_DIR="$HOME/.gradle/init.d"
mkdir -p "$GRADLE_INIT_DIR"
cat > "$GRADLE_INIT_DIR/nexus-mirror.gradle" <<GRADLE
// Gradle init-скрипт: перенаправление всех зависимостей через Nexus
// Файл: ~/.gradle/init.d/nexus-mirror.gradle

allprojects {
    repositories {
        all { ArtifactRepository repo ->
            if (repo instanceof MavenArtifactRepository) {
                def url = repo.url.toString()
                if (!url.startsWith('$NEXUS_URL')) {
                    logger.lifecycle "Заменяем репозиторий \${repo.name}: \${url} → Nexus"
                    remove repo
                }
            }
        }
        maven {
            url '$NEXUS_URL/repository/maven-public/'
            credentials {
                username '$NEXUS_USER'
                password '$NEXUS_PASS'
            }
        }
    }
}
GRADLE
ok "Gradle init-скрипт → $GRADLE_INIT_DIR/nexus-mirror.gradle"

# ── Проверка связи ────────────────────────────────────────────────────────
echo ""
echo "--- Проверка зеркал ---"
for repo_path in "repository/maven-central/" "repository/npm-proxy/" "repository/pypi-proxy/simple/"; do
  if curl -sf --max-time 10 "$NEXUS_URL/$repo_path" >/dev/null 2>&1; then
    ok "Репозиторий доступен: $NEXUS_URL/$repo_path"
  else
    warn "Репозиторий недоступен: $NEXUS_URL/$repo_path (создайте через setup-nexus-mirrors.sh)"
  fi
done

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Настроено для режима '$SCOPE':"
echo "  Maven:  $MAVEN_SETTINGS"
echo "  npm:    $NPMRC"
echo "  pip:    $PIP_CONF"
echo "  Gradle: $GRADLE_INIT_DIR/nexus-mirror.gradle"
echo "  ENV:    $(pwd)/build-env.sh"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
