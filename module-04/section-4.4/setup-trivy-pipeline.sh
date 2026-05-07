#!/usr/bin/env bash
# Интеграция Trivy в конвейер GitLab CI: генерация шаблона задания и проверка конфигурации
# Использование: bash setup-trivy-pipeline.sh [имя_образа] [уровень_fail] [путь_к_db]
set -euo pipefail

IMAGE="${1:-${CI_REGISTRY_IMAGE:-harbor.internal.company.local/myapp/api}:${CI_COMMIT_SHA:-latest}}"
SEVERITY="${2:-${TRIVY_SEVERITY:-CRITICAL,HIGH}}"
TRIVY_DB_PATH="${3:-${TRIVY_DB_PATH:-/opt/trivy-db}}"
HARBOR_URL="${HARBOR_URL:-harbor.internal.company.local}"
OUTPUT_DIR="${TRIVY_OUTPUT_DIR:-.}"
GITLAB_CI_FILE="${GITLAB_CI_FILE:-.gitlab-ci.yml}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Интеграция Trivy в конвейер ==="
echo "Образ:     $IMAGE"
echo "Блокировать: $SEVERITY"
echo "База DB:   $TRIVY_DB_PATH"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"

# --- Проверка наличия Trivy ---
echo ""
echo "--- Инструменты ---"
if command -v trivy &>/dev/null; then
  ok "trivy: $(trivy --version 2>/dev/null | head -1)"
  TRIVY_BIN="trivy"
elif [ -d "$TRIVY_DB_PATH" ]; then
  ok "База данных Trivy найдена: $TRIVY_DB_PATH"
  TRIVY_BIN=""
else
  warn "trivy не найден локально — генерируется только шаблон конвейера"
  TRIVY_BIN=""
fi

# --- Проверка базы уязвимостей ---
echo ""
echo "--- База уязвимостей ---"
db_meta="$TRIVY_DB_PATH/db/metadata.json"
if [ -f "$db_meta" ]; then
  db_date=$(python3 -c "import json; d=json.load(open('$db_meta')); print(d.get('UpdatedAt','?')[:10])" 2>/dev/null || echo "?")
  ok "База уязвимостей: $db_date"

  db_epoch=$(python3 -c "
import json, datetime
d = json.load(open('$db_meta'))
dt_str = d.get('UpdatedAt','')
try:
    dt = datetime.datetime.fromisoformat(dt_str.replace('Z','+00:00'))
    print(int(dt.timestamp()))
except Exception:
    print(0)
" 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  age_days=$(( (now_epoch - db_epoch) / 86400 ))
  if [ "$age_days" -gt 30 ]; then
    fail "База уязвимостей устарела на $age_days дней (допустимо: ≤30 дней)"
  elif [ "$age_days" -gt 7 ]; then
    warn "База уязвимостей: $age_days дней (рекомендуется обновить)"
  else
    ok "Актуальность базы: $age_days дней"
  fi
else
  warn "Файл metadata.json не найден в $TRIVY_DB_PATH — проверьте путь"
fi

# --- Сканирование образа (если trivy доступен) ---
if [ -n "$TRIVY_BIN" ] && [ -n "${IMAGE:-}" ]; then
  echo ""
  echo "--- Сканирование: $IMAGE ---"
  REPORT_FILE="$OUTPUT_DIR/trivy-report-$(date +%Y%m%d%H%M%S).json"

  scan_exit=0
  $TRIVY_BIN image \
    --exit-code 1 \
    --severity "$SEVERITY" \
    --format json \
    --output "$REPORT_FILE" \
    --skip-db-update \
    --cache-dir "$TRIVY_DB_PATH" \
    --no-progress \
    "$IMAGE" 2>/dev/null || scan_exit=$?

  if [ "$scan_exit" -eq 0 ]; then
    ok "Сканирование: уязвимостей уровня $SEVERITY не найдено"
  elif [ "$scan_exit" -eq 1 ]; then
    vuln_count=$(python3 -c "
import json
report = json.load(open('$REPORT_FILE'))
total = sum(len(r.get('Vulnerabilities') or []) for r in report.get('Results',[]))
print(total)
" 2>/dev/null || echo "?")
    fail "Сканирование: найдено $vuln_count уязвимостей уровня $SEVERITY"
  else
    warn "Сканирование завершилось с кодом $scan_exit — проверьте образ и базу"
  fi

  if [ -f "$REPORT_FILE" ]; then
    ok "Отчёт сохранён: $REPORT_FILE"
  fi
fi

# --- Генерация шаблона GitLab CI ---
echo ""
echo "--- Генерация шаблона .gitlab-ci.yml ---"
TEMPLATE_FILE="$OUTPUT_DIR/trivy-scan-template.yml"

cat > "$TEMPLATE_FILE" <<YAML
# Шаблон задания Trivy для GitLab CI
# Включите в основной .gitlab-ci.yml через include:

.trivy-scan:
  stage: security
  image: \${HARBOR_URL}/tools/trivy:latest
  variables:
    TRIVY_NO_PROGRESS: "true"
    TRIVY_CACHE_DIR: /trivy-cache
    TRIVY_SKIP_DB_UPDATE: "true"
    TRIVY_SEVERITY: "$SEVERITY"
    TRIVY_EXIT_CODE: "1"
    TRIVY_FORMAT: json
    TRIVY_OUTPUT: trivy-report.json
  cache:
    key: trivy-db
    paths:
      - /trivy-cache/
  before_script:
    - trivy --version
    - ls \${TRIVY_CACHE_DIR}/db/metadata.json || (echo "База Trivy отсутствует" && exit 1)
  script:
    - |
      trivy image \\
        --exit-code \${TRIVY_EXIT_CODE} \\
        --severity \${TRIVY_SEVERITY} \\
        --format \${TRIVY_FORMAT} \\
        --output \${TRIVY_OUTPUT} \\
        --skip-db-update \\
        --cache-dir \${TRIVY_CACHE_DIR} \\
        "\${HARBOR_URL}/\${CI_PROJECT_PATH}:\${CI_COMMIT_SHA}"
  after_script:
    - |
      if [ -f trivy-report.json ]; then
        python3 -c "
import json
report = json.load(open('trivy-report.json'))
vulns = [(r.get('Target',''), v.get('VulnerabilityID',''), v.get('Severity',''), v.get('Title','')[:60])
         for r in report.get('Results',[]) for v in (r.get('Vulnerabilities') or [])]
for target, cve, sev, title in vulns[:20]:
    print(f'{sev:10} {cve:20} {target}: {title}')
if len(vulns) > 20:
    print(f'... и ещё {len(vulns)-20} уязвимостей')
"
      fi
  artifacts:
    when: always
    reports:
      container_scanning: trivy-report.json
    paths:
      - trivy-report.json
    expire_in: 90 days
  allow_failure: false

# Шаблон с файлом исключений
.trivy-scan-with-ignore:
  extends: .trivy-scan
  script:
    - |
      IGNORE_FILE=".trivyignore"
      trivy image \\
        --exit-code \${TRIVY_EXIT_CODE} \\
        --severity \${TRIVY_SEVERITY} \\
        --format \${TRIVY_FORMAT} \\
        --output \${TRIVY_OUTPUT} \\
        --skip-db-update \\
        --cache-dir \${TRIVY_CACHE_DIR} \\
        \$([ -f "\$IGNORE_FILE" ] && echo "--ignorefile \$IGNORE_FILE") \\
        "\${HARBOR_URL}/\${CI_PROJECT_PATH}:\${CI_COMMIT_SHA}"
YAML

ok "Шаблон конвейера сохранён: $TEMPLATE_FILE"
echo ""
echo "Добавьте в .gitlab-ci.yml:"
echo "  include:"
echo "    - local: '$(basename "$TEMPLATE_FILE")'"
echo ""
echo "  scan-image:"
echo "    extends: .trivy-scan"

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
