#!/usr/bin/env bash
# Запуск Hadolint с корпоративным файлом правил и вывод отчёта для GitLab CI
# Использование: bash lint-dockerfile.sh [Dockerfile] [hadolint_config]
set -euo pipefail

DOCKERFILE="${1:-Dockerfile}"
HADOLINT_CONFIG="${2:-.hadolint.yaml}"
HADOLINT_IMAGE="${HADOLINT_IMAGE:-harbor.internal.company.local/tools/hadolint:latest}"
FAIL_ON="${FAIL_ON_SEVERITY:-error}"     # error, warning, info, style
OUTPUT_FORMAT="${HADOLINT_FORMAT:-tty}"  # tty, json, checkstyle, codeclimate, gitlab_codeclimate

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Hadolint: статический анализ Dockerfile ==="
echo "Dockerfile:   $DOCKERFILE"
echo "Конфигурация: $HADOLINT_CONFIG"
echo "Уровень FAIL: $FAIL_ON"
echo "Дата:         $(date '+%Y-%m-%d %H:%M')"

# --- Проверка наличия Dockerfile ---
if [ ! -f "$DOCKERFILE" ]; then
  fail "Dockerfile не найден: $DOCKERFILE"
  exit 1
fi
ok "Dockerfile найден: $DOCKERFILE ($(wc -l < "$DOCKERFILE") строк)"

# --- Генерация корпоративного .hadolint.yaml если не существует ---
if [ ! -f "$HADOLINT_CONFIG" ]; then
  warn "Файл правил $HADOLINT_CONFIG не найден — создаётся с корпоративными настройками"
  cat > "$HADOLINT_CONFIG" <<'EOF'
failure-threshold: error
warning-threshold: warning

# Запрещённые инструкции
deny:
  - ADD  # используйте COPY вместо ADD

# Правила которые игнорируем глобально (обоснование: корпоративные зеркала)
ignore:
  - DL3008  # pin versions in apt get install
  - DL3009  # delete the apt-get lists after installing

# Доверенные реестры (только внутренний Harbor)
trustedRegistries:
  - harbor.internal.company.local

# Строгость по уровням
rules:
  - DL3007: warning  # using latest is best avoided
  - DL3025: error    # use arguments JSON notation for CMD and ENTRYPOINT
  - DL4006: error    # set the SHELL option -o pipefail before RUN with a pipe
EOF
  ok "Создан файл правил: $HADOLINT_CONFIG"
fi

# --- Запуск hadolint ---
echo ""
echo "--- Анализ ---"

# Предпочитаем локально установленный hadolint, иначе через Docker
if command -v hadolint &>/dev/null; then
  HADOLINT_CMD="hadolint"
  ok "Используется локальный hadolint: $(hadolint --version 2>/dev/null | head -1)"
elif docker image inspect "$HADOLINT_IMAGE" &>/dev/null 2>&1; then
  HADOLINT_CMD="docker run --rm -v $(pwd):/work -w /work $HADOLINT_IMAGE hadolint"
  ok "Используется hadolint из образа: $HADOLINT_IMAGE"
else
  fail "hadolint не найден: установите локально или перенесите образ $HADOLINT_IMAGE в Harbor"
  exit 1
fi

# Запускаем анализ
lint_output=$($HADOLINT_CMD --config "$HADOLINT_CONFIG" --format "$OUTPUT_FORMAT" "$DOCKERFILE" 2>&1 || true)
lint_exit=$?

if [ -n "$lint_output" ]; then
  echo "$lint_output"
  echo ""

  error_count=$(echo "$lint_output" | grep -c " error " 2>/dev/null || echo 0)
  warning_count=$(echo "$lint_output" | grep -c " warning " 2>/dev/null || echo 0)
  info_count=$(echo "$lint_output" | grep -c " info " 2>/dev/null || echo 0)

  echo "Ошибок:       $error_count"
  echo "Предупреждений: $warning_count"
  echo "Информационных: $info_count"

  if [ "$error_count" -gt 0 ]; then
    fail "Обнаружены ошибки Dockerfile: $error_count"
  elif [ "$warning_count" -gt 0 ] && [ "$FAIL_ON" = "warning" ]; then
    fail "Обнаружены предупреждения (FAIL_ON=warning): $warning_count"
  elif [ "$warning_count" -gt 0 ]; then
    warn "Предупреждений: $warning_count (не блокируют)"
  fi
else
  ok "Нарушений не обнаружено"
fi

# --- Проверка критичных паттернов вручную ---
echo ""
echo "--- Дополнительные проверки ---"

# Секреты в ARG/ENV
if grep -qiE "^(ARG|ENV)\s+(password|secret|token|key|passwd)=" "$DOCKERFILE" 2>/dev/null; then
  fail "Возможные секреты в ARG/ENV инструкциях — используйте BuildKit secret mounts"
else
  ok "Секреты в ARG/ENV не обнаружены"
fi

# Запуск от root
if ! grep -qi "^USER " "$DOCKERFILE" 2>/dev/null; then
  warn "Инструкция USER отсутствует — контейнер будет запускаться от root"
else
  ok "Инструкция USER присутствует"
fi

# Внешние источники в RUN
external_sources=$(grep -iE "^RUN.*(curl|wget).*(http|ftp).*://" "$DOCKERFILE" 2>/dev/null | grep -v "internal\|local" || true)
if [ -n "$external_sources" ]; then
  warn "Возможные обращения к внешним источникам в RUN:"
  echo "$external_sources" | head -5
else
  ok "Явных обращений к внешним источникам в RUN не обнаружено"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
