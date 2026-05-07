#!/usr/bin/env bash
# Перенос distroless-образов из gcr.io в Harbor с проверкой дайджестов и сканированием Trivy
# Использование: bash transfer-distroless-images.sh [harbor_url] [harbor_user] [harbor_pass]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-harbor.internal.company.local}}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
TRIVY_DB="${TRIVY_DB_PATH:-/opt/trivy-db}"
FAIL_ON_CRITICAL="${FAIL_ON_CRITICAL:-true}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

# Список distroless-образов для переноса
# Формат: "исходный_образ|целевой_путь_в_harbor"
DISTROLESS_IMAGES=(
  "gcr.io/distroless/java21-debian12:latest|gcr.io/distroless/java21-debian12:latest"
  "gcr.io/distroless/java17-debian12:latest|gcr.io/distroless/java17-debian12:latest"
  "gcr.io/distroless/java11-debian12:latest|gcr.io/distroless/java11-debian12:latest"
  "gcr.io/distroless/python3-debian12:latest|gcr.io/distroless/python3-debian12:latest"
  "gcr.io/distroless/nodejs20-debian12:latest|gcr.io/distroless/nodejs20-debian12:latest"
  "gcr.io/distroless/base-debian12:latest|gcr.io/distroless/base-debian12:latest"
  "gcr.io/distroless/static-debian12:latest|gcr.io/distroless/static-debian12:latest"
  "gcr.io/distroless/cc-debian12:latest|gcr.io/distroless/cc-debian12:latest"
)

echo "=== Перенос distroless-образов в Harbor ==="
echo "Harbor:  $HARBOR_URL"
echo "Образов: ${#DISTROLESS_IMAGES[@]}"
echo "Дата:    $(date '+%Y-%m-%d %H:%M')"
echo ""
echo "ВНИМАНИЕ: Запустите на машине с доступом в интернет."
echo "После переноса — перенесите файлы в закрытый контур."

# --- Аутентификация в Harbor ---
echo ""
echo "--- Аутентификация ---"
if [ -n "$HARBOR_PASS" ]; then
  echo "$HARBOR_PASS" | docker login "$HARBOR_URL" -u "$HARBOR_USER" --password-stdin >/dev/null 2>&1 \
    && ok "Авторизован в $HARBOR_URL" \
    || { fail "Авторизация в Harbor не удалась"; exit 1; }
else
  warn "HARBOR_PASS не задан — предполагается что авторизация уже выполнена"
fi

# Создаём проект gcr.io в Harbor если не существует
AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
curl -sf -X POST -H "Authorization: Basic $AUTH" \
  -H "Content-Type: application/json" \
  "https://$HARBOR_URL/api/v2.0/projects" \
  -d '{"project_name":"gcr.io","public":false}' >/dev/null 2>&1 || true

# --- Перенос каждого образа ---
echo ""
echo "--- Перенос образов ---"
TRANSFER_LOG="distroless-transfer-$(date +%Y%m%d).log"

for img_pair in "${DISTROLESS_IMAGES[@]}"; do
  SOURCE=$(echo "$img_pair" | cut -d'|' -f1)
  TARGET_PATH=$(echo "$img_pair" | cut -d'|' -f2)
  TARGET="$HARBOR_URL/$TARGET_PATH"

  echo ""
  echo "  ── $SOURCE"

  # 1. Проверяем существует ли уже в Harbor
  if docker manifest inspect "$TARGET" &>/dev/null 2>&1; then
    warn "  Уже в Harbor: $TARGET — пропуск (используйте --force для перезаписи)"
    continue
  fi

  # 2. Загружаем образ
  echo "  Загрузка..."
  if ! docker pull "$SOURCE" 2>/dev/null; then
    fail "  Не удалось загрузить: $SOURCE"
    continue
  fi

  # 3. Фиксируем дайджест SHA256
  DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$SOURCE" 2>/dev/null | cut -d@ -f2 || echo "")
  if [ -n "$DIGEST" ]; then
    ok "  Дайджест: ${DIGEST:0:20}..."
  else
    warn "  Дайджест не определён"
  fi

  # 4. Сканирование Trivy
  echo "  Сканирование Trivy..."
  trivy_ok=true
  if command -v trivy &>/dev/null && [ -d "$TRIVY_DB" ]; then
    critical_count=$(trivy image \
      --exit-code 0 \
      --severity CRITICAL \
      --format json \
      --skip-db-update \
      --cache-dir "$TRIVY_DB" \
      --no-progress \
      "$SOURCE" 2>/dev/null | \
      python3 -c "
import json,sys
report = json.load(sys.stdin)
total = sum(len([v for v in (r.get('Vulnerabilities') or []) if v.get('Severity') == 'CRITICAL'])
            for r in report.get('Results',[]))
print(total)
" 2>/dev/null || echo 0)

    if [ "${critical_count:-0}" -gt 0 ]; then
      fail "  Trivy: $critical_count CRITICAL уязвимостей — образ не перенесён"
      [ "$FAIL_ON_CRITICAL" = "true" ] && continue
    else
      ok "  Trivy: CRITICAL уязвимостей не найдено"
    fi
  else
    warn "  Trivy недоступен — перенос без сканирования"
  fi

  # 5. Тегируем и пушим в Harbor
  docker tag "$SOURCE" "$TARGET"
  if docker push "$TARGET" 2>/dev/null; then
    ok "  Загружен в Harbor: $TARGET"
    echo "  $SOURCE → $TARGET  digest=${DIGEST:-?}" >> "$TRANSFER_LOG"
  else
    fail "  Ошибка загрузки в Harbor: $TARGET"
  fi

  # 6. Удаляем локальную копию (экономим место)
  docker rmi "$SOURCE" "$TARGET" >/dev/null 2>&1 || true

done

# --- Отчёт ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Журнал переноса: $TRANSFER_LOG"
echo ""
echo "После переноса в закрытый контур:"
echo "  1. Обновите дайджесты в Dockerfile:"
echo "     FROM $HARBOR_URL/gcr.io/distroless/java21-debian12@sha256:<digest>"
echo "  2. Проверьте список: docker images | grep distroless"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
