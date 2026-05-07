#!/usr/bin/env bash
# Запуск Docker Bench for Security из локального Harbor-образа (офлайн)
# CIS Docker Benchmark — проверка конфигурации хоста и Docker daemon
# Использование: bash docker-bench-offline.sh [harbor-host] [выходной_файл]
set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.internal}"
BENCH_IMAGE="${1:-${HARBOR_HOST}/security/docker-bench-security:latest}"
OUTPUT_FILE="${2:-docker-bench-$(hostname)-$(date +%Y%m%d).txt}"

echo "=== Docker Bench for Security (офлайн) ==="
echo "Хост: $(hostname)  |  Дата: $(date)"
echo "Образ: $BENCH_IMAGE"
echo "Отчёт: $OUTPUT_FILE"
echo ""

# --- Проверка доступности образа ---
echo "--- Проверка образа ---"
if ! docker image inspect "$BENCH_IMAGE" &>/dev/null; then
  echo "[WARN] Образ $BENCH_IMAGE не найден локально."
  echo "  Загрузите его в Harbor перед запуском:"
  echo "  1. На машине с интернетом:"
  echo "     docker pull docker/docker-bench-security"
  echo "     docker save docker/docker-bench-security | gzip > docker-bench.tar.gz"
  echo "  2. Перенесите в закрытый контур и загрузите:"
  echo "     docker load < docker-bench.tar.gz"
  echo "     docker tag docker/docker-bench-security ${HARBOR_HOST}/security/docker-bench-security:latest"
  echo "     docker push ${HARBOR_HOST}/security/docker-bench-security:latest"
  echo ""

  # Попытка использовать локальный образ без тега Harbor
  if docker image inspect docker/docker-bench-security &>/dev/null; then
    BENCH_IMAGE="docker/docker-bench-security"
    echo "[INFO] Используем локальный образ: $BENCH_IMAGE"
  else
    echo "[FAIL] Образ Docker Bench не найден. Выход."
    exit 1
  fi
fi
echo "[PASS] Образ найден: $BENCH_IMAGE"

echo ""

# --- Запуск Docker Bench ---
echo "--- Запуск Docker Bench for Security ---"
echo "  Проверка займёт 1-3 минуты..."
echo ""

docker run --rm \
  --net host \
  --pid host \
  --userns host \
  --cap-add audit_control \
  -e DOCKER_CONTENT_TRUST="$DOCKER_CONTENT_TRUST" \
  -v /etc:/etc:ro \
  -v /usr/bin/containerd:/usr/bin/containerd:ro \
  -v /usr/bin/runc:/usr/bin/runc:ro \
  -v /usr/lib/systemd:/usr/lib/systemd:ro \
  -v /var/lib:/var/lib:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --label docker_bench_security \
  "$BENCH_IMAGE" \
  2>/dev/null | tee "$OUTPUT_FILE"

echo ""

# --- Анализ результатов ---
echo ""
echo "--- Итоги по категориям ---"
if [ -f "$OUTPUT_FILE" ]; then
  pass_count=$(grep -c '^\[PASS\]' "$OUTPUT_FILE" || true)
  warn_count=$(grep -c '^\[WARN\]' "$OUTPUT_FILE" || true)
  info_count=$(grep -c '^\[INFO\]' "$OUTPUT_FILE" || true)
  note_count=$(grep -c '^\[NOTE\]' "$OUTPUT_FILE" || true)

  echo "  [PASS]: $pass_count"
  echo "  [WARN]: $warn_count"
  echo "  [INFO]: $info_count"
  echo "  [NOTE]: $note_count"
  echo ""

  # Выводим предупреждения отдельно для наглядности
  if [ "${warn_count:-0}" -gt 0 ]; then
    echo "--- Предупреждения (требуют внимания) ---"
    grep '^\[WARN\]' "$OUTPUT_FILE" | head -20
    [ "$warn_count" -gt 20 ] && echo "  ... и ещё $((warn_count - 20)) предупреждений в $OUTPUT_FILE"
  fi
fi

echo ""
echo "=== Отчёт сохранён: $OUTPUT_FILE ==="
echo "Артефакт R-4.2: сохраните файл с датой для аудита."
