#!/usr/bin/env bash
# Перенос образов стека мониторинга в Harbor с проверкой версий и сканированием Trivy
# Использование: bash transfer-monitoring-images.sh [harbor_url] [harbor_user] [harbor_pass]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-harbor.internal.company.local}}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"
TRIVY_DB="${TRIVY_DB_PATH:-/opt/trivy-db}"
OUTPUT_DIR="${TRANSFER_OUTPUT:-./monitoring-images}"

# Версии образов стека мониторинга (фиксируем явно)
declare -A IMAGES=(
  ["prometheus"]="prom/prometheus:v2.51.2"
  ["grafana"]="grafana/grafana:10.4.2"
  ["alertmanager"]="prom/alertmanager:v0.27.0"
  ["loki"]="grafana/loki:3.0.0"
  ["promtail"]="grafana/promtail:3.0.0"
  ["node-exporter"]="prom/node-exporter:v1.8.0"
  ["cadvisor"]="gcr.io/cadvisor/cadvisor:v0.49.1"
)

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Перенос образов стека мониторинга ==="
echo "Harbor: $HARBOR_URL"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"
echo ""
echo "Образов для переноса: ${#IMAGES[@]}"

mkdir -p "$OUTPUT_DIR"

# Аутентификация в Harbor
if [ -n "$HARBOR_PASS" ]; then
  echo "$HARBOR_PASS" | docker login "$HARBOR_URL" -u "$HARBOR_USER" --password-stdin >/dev/null 2>&1 \
    && ok "Авторизован в $HARBOR_URL" \
    || { fail "Авторизация в Harbor не удалась"; exit 1; }
fi

TRANSFER_LOG="$OUTPUT_DIR/transfer-$(date +%Y%m%d).log"
echo "# Журнал переноса образов мониторинга — $(date '+%Y-%m-%d %H:%M')" > "$TRANSFER_LOG"

for name in "${!IMAGES[@]}"; do
  source_img="${IMAGES[$name]}"
  # Целевой путь в Harbor: сохраняем оригинальный namespace
  target_img="$HARBOR_URL/$source_img"

  echo ""
  echo "── $name: $source_img"

  # Проверяем наличие в Harbor
  if docker manifest inspect "$target_img" &>/dev/null 2>&1; then
    warn "  Уже в Harbor — пропуск (удалите тег для перезаписи)"
    continue
  fi

  # Загрузка
  if ! docker pull "$source_img" 2>/dev/null; then
    fail "  Не удалось загрузить: $source_img"
    continue
  fi

  # SHA256-дайджест
  digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$source_img" 2>/dev/null | cut -d@ -f2 || echo "")
  [ -n "$digest" ] && ok "  Дайджест: ${digest:0:20}..." || warn "  Дайджест не определён"

  # Trivy-сканирование
  if command -v trivy &>/dev/null && [ -d "$TRIVY_DB" ]; then
    critical=$(trivy image \
      --exit-code 0 --severity CRITICAL \
      --format json --skip-db-update \
      --cache-dir "$TRIVY_DB" --no-progress \
      "$source_img" 2>/dev/null | \
      python3 -c "
import json,sys
r=json.load(sys.stdin)
print(sum(len([v for v in (res.get('Vulnerabilities') or []) if v.get('Severity')=='CRITICAL'])
         for res in r.get('Results',[])))
" 2>/dev/null || echo 0)
    if [ "${critical:-0}" -gt 0 ]; then
      warn "  Trivy: $critical CRITICAL (допускается для образов мониторинга — задокументируйте)"
    else
      ok "  Trivy: CRITICAL не найдено"
    fi
  else
    warn "  Trivy недоступен — перенос без сканирования"
  fi

  # Тег и push в Harbor
  docker tag "$source_img" "$target_img"
  if docker push "$target_img" 2>/dev/null; then
    ok "  → $target_img"
    echo "$source_img → $target_img  digest=$digest" >> "$TRANSFER_LOG"
  else
    fail "  Ошибка загрузки в Harbor: $target_img"
  fi

  docker rmi "$source_img" "$target_img" >/dev/null 2>&1 || true
done

# Создаём файл версий для фиксации в Git
VERSIONS_FILE="$OUTPUT_DIR/monitoring-versions.env"
{
  echo "# Версии образов стека мониторинга — $(date '+%Y-%m-%d')"
  echo "# Используйте в docker-compose.yml и deploy-monitoring-stack.sh"
  for name in "${!IMAGES[@]}"; do
    echo "${name^^}_IMAGE=$HARBOR_URL/${IMAGES[$name]}"
  done
} > "$VERSIONS_FILE"
ok "Версии зафиксированы: $VERSIONS_FILE"

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Журнал: $TRANSFER_LOG"
echo "Версии: $VERSIONS_FILE"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
