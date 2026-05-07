#!/usr/bin/env bash
# Проверка Dockerfile на соответствие внутренним стандартам безопасности
# Использование: bash lint-dockerfile.sh <Dockerfile> [--strict]
set -euo pipefail

DOCKERFILE="${1:-Dockerfile}"
STRICT="${2:-}"
PASS=0; WARN=0; FAIL=0

ok()   { echo "  [PASS] $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

[ -f "$DOCKERFILE" ] || { echo "[FAIL] Dockerfile не найден: $DOCKERFILE"; exit 1; }

echo "=== Проверка Dockerfile: $DOCKERFILE ==="
echo ""

# Базовый образ
FROM_LINE=$(grep -m1 "^FROM" "$DOCKERFILE" 2>/dev/null | head -1 || true)
echo "--- Базовый образ ---"
if echo "$FROM_LINE" | grep -qE "@sha256:[a-f0-9]{64}"; then
  ok "Базовый образ закреплён по digest"
elif echo "$FROM_LINE" | grep -qE ":latest$|^FROM [a-zA-Z]"; then
  fail "Базовый образ без явного тега (latest или без тега)"
else
  warn "Базовый образ закреплён по тегу, рекомендуется digest"
fi

# Внутренний реестр
if echo "$FROM_LINE" | grep -qE "harbor\.|registry\.internal|\.internal\."; then
  ok "Образ берётся из внутреннего реестра"
else
  warn "Образ берётся не из внутреннего реестра (harbor.internal.../...)"
fi

# USER инструкция
echo ""
echo "--- Привилегии ---"
if grep -qE "^USER " "$DOCKERFILE" 2>/dev/null; then
  user_line=$(grep "^USER" "$DOCKERFILE" | tail -1)
  if echo "$user_line" | grep -qE "USER root|USER 0"; then
    fail "Контейнер запускается от root: $user_line"
  else
    ok "Непривилегированный пользователь: $user_line"
  fi
else
  fail "Инструкция USER отсутствует — запуск от root"
fi

# COPY vs ADD
echo ""
echo "--- Лучшие практики ---"
if grep -qE "^ADD " "$DOCKERFILE" 2>/dev/null; then
  add_count=$(grep -cE "^ADD " "$DOCKERFILE" 2>/dev/null || echo 0)
  warn "ADD используется $add_count раз(а) — предпочтительно COPY"
else
  ok "ADD не используется, только COPY"
fi

# apt/yum без очистки кэша
if grep -qE "apt-get install|apt install" "$DOCKERFILE" 2>/dev/null; then
  if grep -qE "rm -rf /var/lib/apt|apt-get clean" "$DOCKERFILE" 2>/dev/null; then
    ok "Кэш apt очищается"
  else
    warn "apt-get install без очистки кэша (увеличивает размер образа)"
  fi
fi

# Секреты в ARG/ENV
echo ""
echo "--- Безопасность секретов ---"
if grep -qiE "^(ENV|ARG).*(password|passwd|secret|token|key|api_key)" "$DOCKERFILE" 2>/dev/null; then
  fail "Возможные секреты в ENV/ARG (password/secret/token/key)"
else
  ok "Секреты не обнаружены в ENV/ARG"
fi

# --no-install-recommends
if grep -qE "apt-get install" "$DOCKERFILE" 2>/dev/null; then
  if grep -qE "no-install-recommends|no-install-suggests" "$DOCKERFILE" 2>/dev/null; then
    ok "--no-install-recommends используется"
  else
    warn "apt-get install без --no-install-recommends"
  fi
fi

# HEALTHCHECK
echo ""
echo "--- Healthcheck ---"
if grep -qE "^HEALTHCHECK" "$DOCKERFILE" 2>/dev/null; then
  ok "HEALTHCHECK определён"
else
  warn "HEALTHCHECK отсутствует"
fi

# hadolint (если доступен)
echo ""
echo "--- hadolint ---"
if command -v hadolint &>/dev/null; then
  hadolint --failure-threshold error "$DOCKERFILE" 2>/dev/null && \
    ok "hadolint: нет ошибок" || \
    warn "hadolint: обнаружены предупреждения"
else
  echo "  [SKIP] hadolint не установлен"
fi

echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
elif [ "$STRICT" = "--strict" ] && [ "$WARN" -gt 0 ]; then
  exit 1
fi
