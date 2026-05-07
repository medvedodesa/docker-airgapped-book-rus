#!/usr/bin/env bash
# Настройка Nexus Repository OSS с зеркалами Maven, npm, PyPI для конвейеров закрытого контура
# Использование: bash setup-nexus-mirrors.sh [nexus_url] [admin_pass]
set -euo pipefail

NEXUS_URL="${1:-${NEXUS_URL:-http://nexus.internal.company.local:8081}}"
NEXUS_ADMIN_PASS="${2:-${NEXUS_ADMIN_PASS:-admin123}}"
OUTPUT_CONFIGS="${NEXUS_CONFIGS_DIR:-./nexus-mirror-configs}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sf --max-time 30 -u "admin:$NEXUS_ADMIN_PASS" \
      -H "Content-Type: application/json" \
      -X "$method" "$NEXUS_URL/service/rest/v1/$path" -d "$data"
  else
    curl -sf --max-time 30 -u "admin:$NEXUS_ADMIN_PASS" \
      -X "$method" "$NEXUS_URL/service/rest/v1/$path"
  fi
}

echo "=== Настройка зеркал Nexus Repository ==="
echo "Nexus: $NEXUS_URL"
echo "Дата:  $(date '+%Y-%m-%d %H:%M')"
mkdir -p "$OUTPUT_CONFIGS"

# --- Проверка доступности ---
echo ""
echo "--- Nexus ---"
if curl -sf --max-time 10 -u "admin:$NEXUS_ADMIN_PASS" "$NEXUS_URL/service/rest/v1/status" >/dev/null 2>&1; then
  nexus_ver=$(curl -sf -u "admin:$NEXUS_ADMIN_PASS" "$NEXUS_URL/service/rest/v1/status" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('edition','?'))" 2>/dev/null || echo "?")
  ok "Nexus доступен ($nexus_ver)"
else
  fail "Nexus недоступен: $NEXUS_URL"
  exit 1
fi

create_proxy() {
  local name="$1" format="$2" remote_url="$3" extra="${4:-}"
  local payload
  payload=$(python3 -c "
import json
repo = {
  'name': '$name',
  'online': True,
  'storage': {
    'blobStoreName': 'default',
    'strictContentTypeValidation': True
  },
  'proxy': {
    'remoteUrl': '$remote_url',
    'contentMaxAge': 1440,
    'metadataMaxAge': 1440
  },
  'negativeCache': {'enabled': True, 'timeToLive': 1440},
  'httpClient': {
    'blocked': False,
    'autoBlock': True,
    'connection': {'retries': 2, 'timeout': 20}
  }
}
$extra
print(json.dumps(repo))
")
  result=$(api POST "repositories/$format/proxy" "$payload" 2>/dev/null || echo "exists")
  if [ "$result" = "exists" ] || [ -z "$result" ]; then
    warn "Репозиторий $name: уже существует или ошибка создания"
  else
    ok "Репозиторий создан: $name → $remote_url"
  fi
}

# --- Maven ---
echo ""
echo "--- Maven (Java) ---"
create_proxy "maven-central" "maven2" "https://repo1.maven.org/maven2/" \
  "repo['maven'] = {'versionPolicy': 'RELEASE', 'layoutPolicy': 'STRICT'}"
create_proxy "maven-snapshots" "maven2" "https://repo1.maven.org/maven2/" \
  "repo['maven'] = {'versionPolicy': 'SNAPSHOT', 'layoutPolicy': 'PERMISSIVE'}"

# Maven settings.xml
cat > "$OUTPUT_CONFIGS/maven-settings.xml" <<XML
<!-- Maven settings.xml для закрытого контура -->
<!-- Скопируйте в ~/.m2/settings.xml или в директорию сборки -->
<settings>
  <mirrors>
    <mirror>
      <id>nexus-central</id>
      <name>Nexus Maven Mirror</name>
      <url>$NEXUS_URL/repository/maven-central/</url>
      <mirrorOf>central</mirrorOf>
    </mirror>
    <mirror>
      <id>nexus-all</id>
      <name>Nexus All Repos</name>
      <url>$NEXUS_URL/repository/maven-public/</url>
      <mirrorOf>*</mirrorOf>
    </mirror>
  </mirrors>
  <servers>
    <server>
      <id>nexus-central</id>
      <username>readonly</username>
      <password>readonly</password>
    </server>
  </servers>
</settings>
XML
ok "maven-settings.xml → $OUTPUT_CONFIGS/maven-settings.xml"

# --- npm ---
echo ""
echo "--- npm (Node.js) ---"
create_proxy "npm-proxy" "npm" "https://registry.npmjs.org/"

cat > "$OUTPUT_CONFIGS/.npmrc" <<RC
# .npmrc для закрытого контура
registry=$NEXUS_URL/repository/npm-proxy/
strict-ssl=false
RC
ok ".npmrc → $OUTPUT_CONFIGS/.npmrc"

# --- PyPI ---
echo ""
echo "--- PyPI (Python) ---"
create_proxy "pypi-proxy" "pypi" "https://pypi.org/"

cat > "$OUTPUT_CONFIGS/pip.conf" <<CONF
# pip.conf для закрытого контура
# Скопируйте в /etc/pip.conf или $HOME/.pip/pip.conf
[global]
index-url = $NEXUS_URL/repository/pypi-proxy/simple/
trusted-host = $(echo "$NEXUS_URL" | sed 's|http[s]\?://||' | cut -d: -f1)
timeout = 60
CONF
ok "pip.conf → $OUTPUT_CONFIGS/pip.conf"

cat > "$OUTPUT_CONFIGS/Dockerfile.pip-snippet" <<'DOCKERFILE'
# Фрагмент Dockerfile: использование Nexus как источника pip-пакетов
# Добавьте в свой Dockerfile перед командами pip install
ENV PIP_INDEX_URL=NEXUS_PYPI_URL/simple/
ENV PIP_TRUSTED_HOST=NEXUS_HOST
DOCKERFILE
sed -i "s|NEXUS_PYPI_URL|$NEXUS_URL/repository/pypi-proxy|g" "$OUTPUT_CONFIGS/Dockerfile.pip-snippet"
sed -i "s|NEXUS_HOST|$(echo "$NEXUS_URL" | sed 's|http[s]\?://||' | cut -d: -f1)|g" "$OUTPUT_CONFIGS/Dockerfile.pip-snippet"

# --- Go modules ---
echo ""
echo "--- Go Modules ---"
cat > "$OUTPUT_CONFIGS/go-env-snippet.sh" <<'SH'
#!/usr/bin/env bash
# Настройка Go для использования Nexus (Athens) в закрытом контуре
# Добавьте в ~/.bashrc, ~/.profile или в Dockerfile ENV
export GOPROXY=NEXUS_URL/repository/go-proxy/,direct
export GONOSUMCHECK=*
export GOFLAGS=-mod=mod
SH
sed -i "s|NEXUS_URL|$NEXUS_URL|g" "$OUTPUT_CONFIGS/go-env-snippet.sh"
warn "Go-прокси: Nexus поддерживает Go только в Pro-версии; для OSS используйте Athens"

# --- Проверка созданных репозиториев ---
echo ""
echo "--- Проверка репозиториев ---"
repos=$(api GET "repositories" 2>/dev/null | python3 -c "
import json,sys
repos = json.load(sys.stdin)
proxies = [r['name'] for r in repos if r.get('type') == 'proxy']
print(f'Прокси-репозиториев: {len(proxies)}')
for p in proxies:
    print(f'  {p}')
" 2>/dev/null || echo "Не удалось получить список")
echo "$repos"

# --- GitLab CI шаблон ---
echo ""
cat > "$OUTPUT_CONFIGS/gitlab-ci-nexus-vars.yml" <<YAML
# Переменные GitLab CI для использования Nexus-зеркал
# Включите через variables: в вашем .gitlab-ci.yml

variables:
  # Maven
  MAVEN_OPTS: "-Dmaven.repo.local=.m2/repository"
  MAVEN_CLI_OPTS: "--settings $OUTPUT_CONFIGS/maven-settings.xml --batch-mode"

  # npm
  NPM_CONFIG_REGISTRY: "$NEXUS_URL/repository/npm-proxy/"

  # pip
  PIP_INDEX_URL: "$NEXUS_URL/repository/pypi-proxy/simple/"
  PIP_TRUSTED_HOST: "$(echo "$NEXUS_URL" | sed 's|http[s]\?://||' | cut -d: -f1)"

  # Go
  GOPROXY: "$NEXUS_URL/repository/go-proxy/"
YAML
ok "GitLab CI переменные → $OUTPUT_CONFIGS/gitlab-ci-nexus-vars.yml"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Конфигурационные файлы для конвейеров: $OUTPUT_CONFIGS/"
ls -1 "$OUTPUT_CONFIGS/"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
