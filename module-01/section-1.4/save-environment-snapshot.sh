#!/usr/bin/env bash
# Документирование версий установленных компонентов (базовая линия для аудита)
set -euo pipefail

OUTPUT="${1:-/var/log/docker-environment-$(date +%Y%m%d).txt}"

echo "=== Снимок окружения Docker ===" | tee "$OUTPUT"
echo "Дата: $(date)" | tee -a "$OUTPUT"
echo "Хост: $(hostname)" | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

section() { echo "--- $1 ---" | tee -a "$OUTPUT"; }

section "Операционная система"
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" | tee -a "$OUTPUT" || uname -s | tee -a "$OUTPUT"
uname -r | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

section "Docker"
if command -v docker &>/dev/null; then
  docker version 2>/dev/null | tee -a "$OUTPUT"
  echo "" | tee -a "$OUTPUT"
  docker info 2>/dev/null | grep -E '(Server Version|Storage Driver|Logging Driver|Cgroup|Operating System|Kernel Version|Total Memory|Docker Root Dir)' | tee -a "$OUTPUT"
fi
echo "" | tee -a "$OUTPUT"

section "Запущенные контейнеры"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

section "Docker-сети"
docker network ls 2>/dev/null | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

section "Параметры ядра"
for p in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables \
          fs.inotify.max_user_watches; do
  sysctl "$p" 2>/dev/null | tee -a "$OUTPUT"
done
echo "" | tee -a "$OUTPUT"

section "Дисковое пространство"
df -h | tee -a "$OUTPUT"
echo "" | tee -a "$OUTPUT"

section "SELinux/AppArmor"
getenforce 2>/dev/null | tee -a "$OUTPUT" || aa-status --enabled 2>/dev/null && echo "AppArmor enabled" | tee -a "$OUTPUT" || echo "MAC не обнаружен" | tee -a "$OUTPUT"

echo ""
echo "Снимок сохранён: $OUTPUT"
