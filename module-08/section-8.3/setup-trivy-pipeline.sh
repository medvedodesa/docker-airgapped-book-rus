#!/usr/bin/env bash
# Настройка Trivy в конвейере CI/CD: шаблон stage для GitLab/TeamCity
# Использование: bash setup-trivy-pipeline.sh <harbor_host> [db_dir]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
TRIVY_DB_DIR="${2:-/opt/trivy-db}"
OUTPUT_DIR="${3:-/etc/ci-templates}"

echo "=== Настройка Trivy в конвейере CI/CD ==="
echo "  Harbor:  $HARBOR_HOST"
echo "  DB:      $TRIVY_DB_DIR"

mkdir -p "$OUTPUT_DIR"

# GitLab CI шаблон
cat > "$OUTPUT_DIR/trivy-scan.gitlab-ci.yml" << YAML
# Шаблон Trivy для GitLab CI (изолированная среда)
# Включите в .gitlab-ci.yml: include: { local: '.gitlab/trivy-scan.yml' }

.trivy_scan:
  image: ${HARBOR_HOST}/security/trivy:latest
  variables:
    TRIVY_NO_PROGRESS: "true"
    TRIVY_OFFLINE_SCAN: "true"
    TRIVY_DB_REPOSITORY: "file://${TRIVY_DB_DIR}"
    TRIVY_EXIT_CODE: "1"
    TRIVY_SEVERITY: "CRITICAL,HIGH"
    TRIVY_FORMAT: "json"
  script:
    - trivy image
        --no-progress
        --offline-scan
        --db-repository "file://${TRIVY_DB_DIR}"
        --exit-code "\$TRIVY_EXIT_CODE"
        --severity "\$TRIVY_SEVERITY"
        --format "\$TRIVY_FORMAT"
        --output trivy-results.json
        "\${IMAGE_TO_SCAN:-\$CI_REGISTRY_IMAGE:\$CI_COMMIT_SHA}"
    - trivy image
        --no-progress
        --offline-scan
        --db-repository "file://${TRIVY_DB_DIR}"
        --exit-code 0
        --severity "\$TRIVY_SEVERITY"
        --format table
        "\${IMAGE_TO_SCAN:-\$CI_REGISTRY_IMAGE:\$CI_COMMIT_SHA}"
  artifacts:
    when: always
    paths:
      - trivy-results.json
    expire_in: 7 days
  allow_failure: false

trivy-scan:
  extends: .trivy_scan
  stage: security
  needs: ["build"]
YAML

echo "  [OK] $OUTPUT_DIR/trivy-scan.gitlab-ci.yml"

# Скрипт проверки актуальности БД
cat > "$OUTPUT_DIR/check-trivy-db.sh" << 'CHECKSCRIPT'
#!/usr/bin/env bash
DB_DIR="${TRIVY_DB_DIR:-/opt/trivy-db}"
MAX_AGE_DAYS=7

if [ ! -f "$DB_DIR/metadata.json" ]; then
  echo "[FAIL] База Trivy не найдена: $DB_DIR/metadata.json"
  exit 1
fi

db_date=$(stat -c %Y "$DB_DIR/metadata.json" 2>/dev/null || stat -f %m "$DB_DIR/metadata.json" 2>/dev/null)
now=$(date +%s)
age_days=$(( (now - db_date) / 86400 ))

if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
  echo "[WARN] База Trivy устарела: $age_days дней (порог: $MAX_AGE_DAYS)"
  exit 1
else
  echo "[OK] База Trivy актуальна: $age_days дней"
fi
CHECKSCRIPT
chmod +x "$OUTPUT_DIR/check-trivy-db.sh"
echo "  [OK] $OUTPUT_DIR/check-trivy-db.sh"

# Проверка наличия БД
echo ""
echo "--- Проверка базы уязвимостей ---"
if [ -f "$TRIVY_DB_DIR/metadata.json" ]; then
  db_updated=$(python3 -c "
import json
d=json.load(open('$TRIVY_DB_DIR/metadata.json'))
print(d.get('UpdatedAt', 'неизвестно'))
" 2>/dev/null || echo "неизвестно")
  echo "  [OK] База найдена, обновлена: $db_updated"
else
  echo "  [WARN] База не найдена в $TRIVY_DB_DIR"
  echo "  Обновление: bash update-trivy-db.sh"
fi

echo ""
echo "=== Шаблоны созданы в $OUTPUT_DIR ==="
