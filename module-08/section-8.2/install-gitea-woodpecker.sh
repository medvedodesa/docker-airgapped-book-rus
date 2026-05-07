#!/usr/bin/env bash
# Развёртывание Gitea и Woodpecker CI через Docker Compose для закрытого контура
# Использование: bash install-gitea-woodpecker.sh [harbor_url] [domain] [admin_pass]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-harbor.internal.company.local}}"
DOMAIN="${2:-${GITEA_DOMAIN:-git.internal.company.local}}"
ADMIN_PASS="${3:-${GITEA_ADMIN_PASS:-$(openssl rand -base64 16)}}"
INSTALL_DIR="${INSTALL_DIR:-/opt/gitea-woodpecker}"
GITEA_PORT="${GITEA_PORT:-3000}"
WOODPECKER_PORT="${WOODPECKER_PORT:-8000}"
GITEA_VERSION="${GITEA_VERSION:-1.21}"
WOODPECKER_VERSION="${WOODPECKER_VERSION:-2.3}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Развёртывание Gitea + Woodpecker CI ==="
echo "Harbor:     $HARBOR_URL"
echo "Домен:      $DOMAIN"
echo "Каталог:    $INSTALL_DIR"
echo "Дата:       $(date '+%Y-%m-%d %H:%M')"

# --- Проверка образов в Harbor ---
echo ""
echo "--- Образы в Harbor ---"
for img in "gitea/gitea:$GITEA_VERSION" "woodpeckerci/woodpecker-server:v$WOODPECKER_VERSION" "woodpeckerci/woodpecker-agent:v$WOODPECKER_VERSION"; do
  if docker manifest inspect "$HARBOR_URL/$img" &>/dev/null 2>&1; then
    ok "Образ найден: $HARBOR_URL/$img"
  elif docker manifest inspect "$img" &>/dev/null 2>&1; then
    warn "Образ в публичном реестре: $img (переносите в Harbor)"
  else
    warn "Образ не найден: $img — перенесите перед запуском"
  fi
done

# --- Создание директорий ---
echo ""
echo "--- Подготовка ---"
mkdir -p "$INSTALL_DIR"/{gitea-data,woodpecker-data,postgres-data}
ok "Директории созданы: $INSTALL_DIR"

# --- Секрет Woodpecker ---
AGENT_SECRET=$(openssl rand -hex 32)
ok "Woodpecker agent secret сгенерирован"

# --- Docker Compose ---
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
cat > "$COMPOSE_FILE" <<YAML
# Gitea + Woodpecker CI для закрытого контура
# Версия: $(date '+%Y-%m-%d')

services:

  postgres:
    image: $HARBOR_URL/library/postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: gitea
      POSTGRES_USER: gitea
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:-gitea_secure_pass}
    volumes:
      - $INSTALL_DIR/postgres-data:/var/lib/postgresql/data
    networks:
      - gitea-net
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "gitea"]
      interval: 10s
      timeout: 5s
      retries: 5

  gitea:
    image: $HARBOR_URL/gitea/gitea:$GITEA_VERSION
    restart: unless-stopped
    environment:
      USER_UID: 1000
      USER_GID: 1000
      GITEA__database__DB_TYPE: postgres
      GITEA__database__HOST: postgres:5432
      GITEA__database__NAME: gitea
      GITEA__database__USER: gitea
      GITEA__database__PASSWD: \${POSTGRES_PASSWORD:-gitea_secure_pass}
      GITEA__server__DOMAIN: $DOMAIN
      GITEA__server__ROOT_URL: https://$DOMAIN
      GITEA__server__HTTP_PORT: $GITEA_PORT
      GITEA__service__DISABLE_REGISTRATION: "true"
      GITEA__service__REQUIRE_SIGNIN_VIEW: "true"
      GITEA__webhook__ALLOWED_HOST_LIST: woodpecker
      GITEA__repository__DEFAULT_PRIVATE: "true"
      GITEA__mailer__ENABLED: "false"
      # Отключаем внешние зависимости
      GITEA__ui__EXPLORE_PAGING_NUM: 20
      GITEA__server__OFFLINE_MODE: "true"
    ports:
      - "${GITEA_PORT}:${GITEA_PORT}"
      - "2222:22"
    volumes:
      - $INSTALL_DIR/gitea-data:/data
    depends_on:
      postgres:
        condition: service_healthy
    networks:
      - gitea-net
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:$GITEA_PORT/api/v1/nodeinfo"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s

  woodpecker-server:
    image: $HARBOR_URL/woodpeckerci/woodpecker-server:v$WOODPECKER_VERSION
    restart: unless-stopped
    environment:
      WOODPECKER_OPEN: "false"
      WOODPECKER_HOST: https://$DOMAIN
      WOODPECKER_GITEA: "true"
      WOODPECKER_GITEA_URL: http://gitea:$GITEA_PORT
      WOODPECKER_GITEA_CLIENT: \${GITEA_OAUTH_CLIENT:-}
      WOODPECKER_GITEA_SECRET: \${GITEA_OAUTH_SECRET:-}
      WOODPECKER_AGENT_SECRET: $AGENT_SECRET
      WOODPECKER_DATABASE_DRIVER: sqlite3
      WOODPECKER_DATABASE_DATASOURCE: /var/lib/woodpecker/woodpecker.sqlite
      WOODPECKER_LOG_LEVEL: info
    ports:
      - "${WOODPECKER_PORT}:8000"
      - "9000:9000"
    volumes:
      - $INSTALL_DIR/woodpecker-data:/var/lib/woodpecker
    depends_on:
      gitea:
        condition: service_healthy
    networks:
      - gitea-net

  woodpecker-agent:
    image: $HARBOR_URL/woodpeckerci/woodpecker-agent:v$WOODPECKER_VERSION
    restart: unless-stopped
    environment:
      WOODPECKER_SERVER: woodpecker-server:9000
      WOODPECKER_AGENT_SECRET: $AGENT_SECRET
      WOODPECKER_BACKEND: docker
      WOODPECKER_BACKEND_DOCKER_NETWORK: gitea-net
      DOCKER_HOST: "unix:///var/run/docker.sock"
      # Запрещаем образы не из Harbor
      WOODPECKER_BACKEND_DOCKER_ENABLE_IMAGE_FILTER: "true"
      WOODPECKER_BACKEND_DOCKER_IMAGE_FILTER: "$HARBOR_URL/*"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    depends_on:
      - woodpecker-server
    networks:
      - gitea-net

networks:
  gitea-net:
    driver: bridge
    internal: false
    ipam:
      config:
        - subnet: 172.25.0.0/24
YAML

ok "docker-compose.yml создан: $COMPOSE_FILE"

# --- .env файл ---
cat > "$INSTALL_DIR/.env" <<ENV
POSTGRES_PASSWORD=$(openssl rand -base64 20 | tr -d '+=/')
GITEA_OAUTH_CLIENT=
GITEA_OAUTH_SECRET=
ENV
chmod 600 "$INSTALL_DIR/.env"
ok ".env файл создан (настройте OAuth после запуска Gitea)"

# --- Запуск ---
echo ""
echo "--- Запуск ---"
docker compose -f "$COMPOSE_FILE" --env-file "$INSTALL_DIR/.env" up -d \
  && ok "Контейнеры запущены" \
  || fail "Ошибка запуска — проверьте docker compose logs"

# --- Ожидание готовности ---
echo ""
echo "--- Ожидание готовности Gitea ---"
for i in $(seq 1 30); do
  if curl -sf "http://localhost:$GITEA_PORT/api/v1/nodeinfo" >/dev/null 2>&1; then
    ok "Gitea готов (попытка $i)"
    break
  fi
  sleep 3
  [ "$i" -eq 30 ] && warn "Gitea не ответил за 90 секунд — проверьте логи"
done

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Gitea:     http://$(hostname):$GITEA_PORT  (первый запуск — форма настройки)"
echo "Woodpecker: http://$(hostname):$WOODPECKER_PORT"
echo ""
echo "Следующие шаги:"
echo "1. Откройте Gitea, создайте администратора: admin / $ADMIN_PASS"
echo "2. Создайте OAuth2-приложение в Gitea для Woodpecker"
echo "3. Добавьте Client ID и Secret в $INSTALL_DIR/.env"
echo "4. Перезапустите: docker compose -f $COMPOSE_FILE restart woodpecker-server"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
