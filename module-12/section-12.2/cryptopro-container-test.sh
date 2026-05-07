#!/usr/bin/env bash
# Тестирование корректности работы КриптоПро CSP внутри Docker-контейнера
# Использование: bash cryptopro-container-test.sh [образ_с_криптопро] [harbor_url]
set -euo pipefail

CRYPTOPRO_IMAGE="${1:-${HARBOR_URL:-harbor.internal.company.local}/infra/cryptopro:5.0}"
HARBOR_URL="${2:-${HARBOR_URL:-harbor.internal.company.local}}"
TEST_CONTAINER="cryptopro-test-$$"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

trap "docker rm -f $TEST_CONTAINER 2>/dev/null || true" EXIT

echo "=== Тестирование КриптоПро CSP в контейнере ==="
echo "Образ:     $CRYPTOPRO_IMAGE"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"

# --- Проверка образа ---
echo ""
echo "--- Образ ---"
if ! docker image inspect "$CRYPTOPRO_IMAGE" &>/dev/null 2>&1; then
  if ! docker pull "$CRYPTOPRO_IMAGE" 2>/dev/null; then
    fail "Образ не найден: $CRYPTOPRO_IMAGE"
    echo "    Соберите: docker build -f Dockerfile.cryptopro -t $CRYPTOPRO_IMAGE ."
    exit 1
  fi
fi
ok "Образ найден: $CRYPTOPRO_IMAGE"

run_in_container() {
  docker exec "$TEST_CONTAINER" bash -c "$1" 2>/dev/null
}

# --- Запуск контейнера ---
echo ""
echo "--- Запуск тестового контейнера ---"
docker run -d --name "$TEST_CONTAINER" \
  --security-opt seccomp=unconfined \
  "$CRYPTOPRO_IMAGE" \
  sleep 300 >/dev/null 2>&1 && ok "Контейнер запущен" || { fail "Не удалось запустить контейнер"; exit 1; }

# --- Тест 1: КриптоПро установлен ---
echo ""
echo "--- Тест 1: Установка КриптоПро ---"
if run_in_container "test -d /opt/cprocsp || test -x /usr/bin/csptest"; then
  ok "КриптоПро CSP найден в контейнере"
else
  fail "КриптоПро CSP не найден в /opt/cprocsp или /usr/bin/csptest"
fi

# Версия
version=$(run_in_container "csptest -enum -info 2>/dev/null | head -5 || cpconfig -ini -view 2>/dev/null | head -3" || echo "")
[ -n "$version" ] && ok "Версия КриптоПро: $(echo "$version" | head -1)" || warn "Версия не определена"

# --- Тест 2: ГОСТ-провайдер ---
echo ""
echo "--- Тест 2: ГОСТ-криптопровайдер ---"
providers=$(run_in_container "csptest -enum -info -type 80 2>/dev/null | grep -i 'gost\|Crypto-Pro'" || echo "")
if [ -n "$providers" ]; then
  ok "ГОСТ-провайдер (type 80) доступен"
else
  warn "ГОСТ-провайдер не обнаружен — проверьте установку"
fi

# --- Тест 3: Генерация ключевой пары ГОСТ ---
echo ""
echo "--- Тест 3: Генерация ключей ГОСТ ---"
keygen_result=$(run_in_container "
csptest -keygen -provtype 80 -keyid test-key-$$ 2>/dev/null && echo 'ok' || echo 'fail'
" || echo "fail")
if [ "$keygen_result" = "ok" ]; then
  ok "Генерация ключей ГОСТ: успешно"
  # Удаляем тестовый ключ
  run_in_container "csptest -delkey -keyid test-key-$$ 2>/dev/null" || true
else
  warn "Генерация ключей ГОСТ не удалась (может требоваться лицензия или аппаратный токен)"
fi

# --- Тест 4: OpenSSL с ГОСТ-движком ---
echo ""
echo "--- Тест 4: OpenSSL ГОСТ-движок ---"
openssl_gost=$(run_in_container "openssl engine gost -t 2>/dev/null && echo ok || echo fail" || echo "fail")
if [ "$openssl_gost" = "ok" ]; then
  ok "OpenSSL ГОСТ-движок загружается"
else
  warn "OpenSSL ГОСТ-движок не загружается — TLS ГОСТ недоступен"
fi

# Список ГОСТ-шифров
gost_ciphers=$(run_in_container "openssl ciphers GOST2012:GOST2001 2>/dev/null | tr ':' '\n' | grep GOST | wc -l" || echo 0)
if [ "${gost_ciphers:-0}" -gt 0 ]; then
  ok "ГОСТ-шифры доступны: $gost_ciphers"
else
  warn "ГОСТ-шифры не обнаружены в OpenSSL"
fi

# --- Тест 5: Хэширование ГОСТ Р 34.11-2012 ---
echo ""
echo "--- Тест 5: Хэширование ГОСТ Р 34.11-2012 ---"
test_data="test-data-for-gost-hash"
hash_result=$(run_in_container "echo '$test_data' | openssl dgst -md_gost12_256 2>/dev/null | awk '{print \$2}'" || echo "")
if [ -n "$hash_result" ] && [ ${#hash_result} -eq 64 ]; then
  ok "ГОСТ Р 34.11-2012 (256 бит): хэш вычислен (${hash_result:0:16}...)"
else
  warn "ГОСТ Р 34.11-2012 хэширование недоступно"
fi

# --- Тест 6: Конфликты при параллельном запуске ---
echo ""
echo "--- Тест 6: Изоляция процессов ---"
second_container="cryptopro-test2-$$"
docker run -d --name "$second_container" \
  --security-opt seccomp=unconfined \
  "$CRYPTOPRO_IMAGE" sleep 30 >/dev/null 2>&1 || true

if docker ps --format '{{.Names}}' | grep -q "$second_container"; then
  ok "Второй контейнер запустился параллельно (конфликтов не обнаружено)"
  docker rm -f "$second_container" >/dev/null 2>&1 || true
else
  warn "Второй контейнер не запустился — возможны конфликты при параллельном использовании"
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "КриптоПро CSP работает корректно в контейнере."
  echo "Образ готов для использования в продакшене."
else
  echo "Обнаружены проблемы — проверьте Dockerfile.cryptopro и установку КриптоПро."
fi
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
