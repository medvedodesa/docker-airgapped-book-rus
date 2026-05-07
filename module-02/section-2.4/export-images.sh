#!/usr/bin/env bash
# Экспорт набора Docker-образов в датированные архивы с контрольными суммами
# Использование: bash export-images.sh [выходная_директория] [образ1] [образ2] ...
set -euo pipefail

OUTPUT_DIR="${1:-/tmp/docker-images-$(date +%Y%m%d)}"
shift || true

# Список образов по умолчанию (инфраструктура)
if [ $# -eq 0 ]; then
  IMAGES=(
    "goharbor/harbor-core:v2.10.1"
    "goharbor/harbor-portal:v2.10.1"
    "goharbor/nginx-photon:v2.10.1"
    "goharbor/registry-photon:v2.10.1"
    "goharbor/trivy-adapter-photon:v2.10.1"
    "prom/prometheus:v2.51.0"
    "grafana/grafana:10.4.0"
    "prom/alertmanager:v0.27.0"
    "grafana/loki:2.9.5"
    "prom/node-exporter:v1.7.0"
    "gcr.io/cadvisor/cadvisor:v0.49.1"
    "ubuntu:22.04"
    "alpine:3.19"
  )
else
  IMAGES=("$@")
fi

mkdir -p "$OUTPUT_DIR"
DATE=$(date +%Y%m%d)

echo "=== Экспорт Docker-образов ==="
echo "  Образов: ${#IMAGES[@]} | Директория: $OUTPUT_DIR | Дата: $DATE"
echo ""

total_size=0
for img in "${IMAGES[@]}"; do
  fname=$(echo "$img" | tr ':/@' '___').tar.gz
  filepath="$OUTPUT_DIR/$fname"
  echo "  -> $img"

  # Проверяем что образ есть локально
  if ! docker image inspect "$img" &>/dev/null 2>&1; then
    echo "     [WARN] Образ не найден локально, пропускаем"
    continue
  fi

  docker save "$img" | gzip > "$filepath"
  size=$(du -sh "$filepath" | awk '{print $1}')
  echo "     $fname ($size)"
done

# Контрольные суммы
echo ""
echo "--- Контрольные суммы ---"
cd "$OUTPUT_DIR"
find . -name "*.tar.gz" | sort | xargs sha256sum > "SHA256SUMS-$DATE"
echo "  SHA256SUMS-$DATE: $(wc -l < "SHA256SUMS-$DATE") файлов"

# Манифест
echo ""
echo "--- Манифест ---"
cat > "MANIFEST-$DATE.txt" << EOF
Docker Images Export Manifest
Date: $(date)
Host: $(hostname)
Images:
$(for img in "${IMAGES[@]}"; do echo "  - $img"; done)
EOF

echo ""
echo "=== Итог ==="
du -sh "$OUTPUT_DIR"
echo "Директория: $OUTPUT_DIR"
