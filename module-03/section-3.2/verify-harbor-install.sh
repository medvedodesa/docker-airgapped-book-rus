#!/usr/bin/env bash
# Комплексная верификация установки Harbor: сервисы, TLS, API, push/pull
# Использование: bash verify-harbor-install.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
TEST_IMAGE="${HARBOR_TEST_IMAGE:-hello-world:latest}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

HARBOR_HOST=$(echo "$HARBOR_URL" | sed 's|https\?://||' | cut -d/ -f1)

echo "=== Верификация установки Harbor ==="
echo "Реестр: $HARBOR_URL"
echo "Хост:   $HARBOR_HOST"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

# --- Контейнеры Harbor ---
echo ""
echo "--- Статус контейнеров ---"
expected_services="harbor-core harbor-db harbor-jobservice harbor-log harbor-portal nginx registryctl"
for svc in $expected_services; do
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "$svc"; then
    ok "Контейнер $svc: запущен"
  else
    fail "Контейнер $svc: не найден"
  fi
done

# --- TLS ---
echo ""
echo "--- TLS-сертификат ---"
cert_info=$(echo | openssl s_client -connect "$HARBOR_HOST:443" -servername "$HARBOR_HOST" 2>/dev/null | openssl x509 -noout -dates 2>/dev/null || echo "")
if [ -n "$cert_info" ]; then
  not_after=$(echo "$cert_info" | grep notAfter | cut -d= -f2)
  ok "TLS-сертификат действителен до: $not_after"
  exp_epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  days_left=$(( (exp_epoch - now_epoch) / 86400 ))
  if [ "$days_left" -lt 30 ]; then
    warn "Сертификат истекает через $days_left дней"
  else
    ok "До истечения сертификата: $days_left дней"
  fi
else
  fail "Не удалось получить TLS-сертификат для $HARBOR_HOST:443"
fi

# --- API ---
echo ""
echo "--- Harbor API ---"
AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() { curl -sf --max-time 10 -H "Authorization: Basic $AUTH" "$HARBOR_URL/api/v2.0/$1" 2>/dev/null; }

if api "ping" >/dev/null 2>&1; then
  ok "API /ping отвечает"
else
  fail "API /ping не отвечает"
fi

version=$(api "systeminfo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('harbor_version','?'))" 2>/dev/null || echo "?")
ok "Версия Harbor: $version"

# --- Docker login ---
echo ""
echo "--- Docker аутентификация ---"
if echo "$HARBOR_PASS" | docker login "$HARBOR_HOST" -u "$HARBOR_USER" --password-stdin >/dev/null 2>&1; then
  ok "docker login $HARBOR_HOST: успешно"
else
  fail "docker login $HARBOR_HOST: ошибка аутентификации"
fi

# --- Push/Pull тестового образа ---
echo ""
echo "--- Тест push/pull ---"
TEST_REPO="$HARBOR_HOST/library/verify-test"
TEST_TAG="$TEST_REPO:$(date +%s)"

if docker images "$TEST_IMAGE" --format '{{.ID}}' | grep -q .; then
  docker tag "$TEST_IMAGE" "$TEST_TAG" 2>/dev/null

  if docker push "$TEST_TAG" >/dev/null 2>&1; then
    ok "docker push: успешно ($TEST_TAG)"
  else
    warn "docker push не выполнен — проект library может не существовать"
  fi

  if docker pull "$TEST_TAG" >/dev/null 2>&1; then
    ok "docker pull: успешно"
    docker rmi "$TEST_TAG" >/dev/null 2>&1 || true
  else
    warn "docker pull не выполнен"
  fi
else
  warn "Тестовый образ $TEST_IMAGE отсутствует локально — пропуск push/pull теста"
fi

# --- Сканирование ---
echo ""
echo "--- Сканер уязвимостей ---"
scanner=$(api "scanners" 2>/dev/null | python3 -c "
import json,sys
scanners = json.load(sys.stdin)
for s in scanners:
    if s.get('is_default'): print(s.get('name','?'))
" 2>/dev/null || echo "")
if [ -n "$scanner" ]; then
  ok "Сканер по умолчанию: $scanner"
else
  warn "Сканер по умолчанию не настроен"
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
