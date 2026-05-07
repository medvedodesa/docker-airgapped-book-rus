#!/usr/bin/env bash
# Сборка Docker-образа с передачей секретов через BuildKit secret mount
# Секреты не фиксируются в слоях образа и не видны в docker history
# Использование: bash build-with-secrets.sh [Dockerfile] [image_tag] [секрет_id=значение ...]
set -euo pipefail

DOCKERFILE="${1:-Dockerfile}"
IMAGE_TAG="${2:-${HARBOR_URL:-harbor.internal.company.local}/myapp/api:local}"
shift 2 || true

# Остальные аргументы — секреты в формате id=значение или id=@файл
SECRETS=("$@")

HARBOR_URL="${HARBOR_URL:-harbor.internal.company.local}"
NEXUS_URL="${NEXUS_URL:-http://nexus.internal.company.local:8081}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Временные файлы секретов — удаляются при выходе
TMPFILES=()
trap 'rm -f "${TMPFILES[@]}" 2>/dev/null' EXIT INT TERM

echo "=== Сборка образа с BuildKit secret mounts ==="
echo "Dockerfile: $DOCKERFILE"
echo "Образ:      $IMAGE_TAG"
echo "Дата:       $(date '+%Y-%m-%d %H:%M')"

# --- Проверка BuildKit ---
echo ""
echo "--- BuildKit ---"
export DOCKER_BUILDKIT=1
if docker build --help 2>/dev/null | grep -q "secret"; then
  ok "BuildKit поддерживает --secret"
else
  fail "Версия Docker не поддерживает BuildKit secrets — обновите Docker"
  exit 1
fi

# --- Dockerfile ---
echo ""
echo "--- Dockerfile ---"
[ -f "$DOCKERFILE" ] || { fail "Dockerfile не найден: $DOCKERFILE"; exit 1; }
ok "Dockerfile: $DOCKERFILE"

# Проверяем что нет ARG/ENV с секретами
if grep -qiE "^(ARG|ENV)\s+(password|token|secret|key)=" "$DOCKERFILE" 2>/dev/null; then
  fail "В Dockerfile обнаружены ARG/ENV с секретами — используйте RUN --mount=type=secret"
else
  ok "ARG/ENV секретов не обнаружено"
fi

# --- Подготовка секретов ---
echo ""
echo "--- Секреты ---"

# Секрет 1: Токен Nexus для pip/npm/maven (из переменной или Vault)
NEXUS_TOKEN_FILE=$(mktemp /tmp/nexus-token-XXXXXX)
TMPFILES+=("$NEXUS_TOKEN_FILE")

if [ -n "$VAULT_TOKEN" ]; then
  nexus_pass=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/secret/prod/nexus/readonly" 2>/dev/null | \
    python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('data',{}).get('password',''))" 2>/dev/null || echo "")
  if [ -n "$nexus_pass" ]; then
    echo "$nexus_pass" > "$NEXUS_TOKEN_FILE"
    ok "Токен Nexus получен из Vault"
  else
    echo "${NEXUS_READONLY_PASS:-readonly}" > "$NEXUS_TOKEN_FILE"
    warn "Vault недоступен — используется NEXUS_READONLY_PASS"
  fi
else
  echo "${NEXUS_READONLY_PASS:-readonly}" > "$NEXUS_TOKEN_FILE"
  warn "VAULT_TOKEN не задан — секрет берётся из NEXUS_READONLY_PASS"
fi
chmod 600 "$NEXUS_TOKEN_FILE"

# Дополнительные секреты из аргументов
SECRET_ARGS=(--secret "id=nexus_password,src=$NEXUS_TOKEN_FILE")
for secret_arg in "${SECRETS[@]}"; do
  if [[ "$secret_arg" == *"=@"* ]]; then
    sid=$(echo "$secret_arg" | cut -d= -f1)
    sfile=$(echo "$secret_arg" | cut -d@ -f2)
    SECRET_ARGS+=(--secret "id=$sid,src=$sfile")
    ok "Секрет из файла: $sid → $sfile"
  elif [[ "$secret_arg" == *"="* ]]; then
    sid=$(echo "$secret_arg" | cut -d= -f1)
    sval=$(echo "$secret_arg" | cut -d= -f2-)
    stmpfile=$(mktemp /tmp/secret-${sid}-XXXXXX)
    TMPFILES+=("$stmpfile")
    echo "$sval" > "$stmpfile"
    chmod 600 "$stmpfile"
    SECRET_ARGS+=(--secret "id=$sid,src=$stmpfile")
    ok "Секрет из аргумента: $sid"
  fi
done

# --- Сборка ---
echo ""
echo "--- Сборка ---"
BUILD_ARGS=(
  --file "$DOCKERFILE"
  --tag "$IMAGE_TAG"
  --build-arg "NEXUS_URL=$NEXUS_URL"
  --build-arg "HARBOR_URL=$HARBOR_URL"
  --progress=plain
  "${SECRET_ARGS[@]}"
)

echo "Команда: docker build ${BUILD_ARGS[*]}"
echo ""

if docker build "${BUILD_ARGS[@]}" . 2>&1; then
  ok "Сборка завершена: $IMAGE_TAG"
else
  fail "Сборка завершилась с ошибкой"
  exit 1
fi

# --- Проверка: секреты не в слоях ---
echo ""
echo "--- Проверка: секреты не попали в образ ---"
history_output=$(docker history --no-trunc "$IMAGE_TAG" --format '{{.CreatedBy}}' 2>/dev/null)

secret_leaked=false
for pattern in "password" "token" "secret" "nexus_pass" "api_key"; do
  if echo "$history_output" | grep -qi "$pattern="; then
    fail "Возможная утечка секрета в истории слоёв: паттерн '$pattern'"
    secret_leaked=true
  fi
done
$secret_leaked || ok "Секреты не обнаружены в docker history"

# --- Сканирование Trivy ---
echo ""
echo "--- Сканирование Trivy ---"
TRIVY_DB="${TRIVY_DB_PATH:-/opt/trivy-db}"
if command -v trivy &>/dev/null && [ -d "$TRIVY_DB" ]; then
  if trivy image \
      --exit-code 0 \
      --severity HIGH,CRITICAL \
      --format table \
      --skip-db-update \
      --cache-dir "$TRIVY_DB" \
      --no-progress \
      "$IMAGE_TAG" 2>/dev/null; then
    ok "Trivy-сканирование выполнено"
  else
    warn "Trivy вернул предупреждения"
  fi
else
  warn "Trivy или база уязвимостей недоступны — пропуск сканирования"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Образ: $IMAGE_TAG"
echo ""
echo "Пример Dockerfile с secret mount:"
cat <<'DOCKERFILE_EXAMPLE'
# syntax=docker/dockerfile:1
FROM python:3.12-slim

ARG NEXUS_URL=http://nexus.internal.company.local:8081

# Правильно: секрет монтируется только во время RUN, не попадает в образ
RUN --mount=type=secret,id=nexus_password \
    pip install \
      --index-url "http://readonly:$(cat /run/secrets/nexus_password)@${NEXUS_URL#http://}/repository/pypi-proxy/simple/" \
      --trusted-host $(echo $NEXUS_URL | sed 's|http://||' | cut -d: -f1) \
      -r requirements.txt
DOCKERFILE_EXAMPLE

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
