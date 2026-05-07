#!/usr/bin/env bash
# Отчёт о ресурсах инфраструктуры: диски, память, CPU, Docker
# Использование: bash capacity-report.sh [--csv]
set -euo pipefail

FORMAT="${1:-text}"
REPORT_FILE="/tmp/capacity-report-$(date +%Y%m%d).txt"

{
echo "=== Отчёт о ресурсах: $(date '+%Y-%m-%d %H:%M') ==="
echo "  Хост: $(hostname)"
echo ""

# CPU
echo "--- CPU ---"
cpu_count=$(nproc 2>/dev/null || grep -c processor /proc/cpuinfo)
load=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | tr -d ',')
echo "  Ядер: $cpu_count"
echo "  Load average (1m): $load"

# Память
echo ""
echo "--- Память ---"
total_mem=$(free -h | awk '/^Mem:/{print $2}')
used_mem=$(free -h  | awk '/^Mem:/{print $3}')
free_mem=$(free -h  | awk '/^Mem:/{print $7}')
used_pct=$(free | awk '/^Mem:/{printf "%.0f", $3/$2*100}')
echo "  Всего:     $total_mem"
echo "  Используется: $used_mem ($used_pct%)"
echo "  Доступно:  $free_mem"

# Диск
echo ""
echo "--- Диск ---"
df -h --output=source,size,used,avail,pcent,target 2>/dev/null | \
  grep -vE "tmpfs|devtmpfs|overlay|Filesystem" | \
  while read -r src size used avail pct mnt; do
    pct_num=${pct/\%/}
    status=$( [ "${pct_num:-0}" -ge 85 ] && echo "WARN" || echo "OK")
    printf "  [%s] %-20s  %s/%s (%s) → %s\n" "$status" "$src" "$used" "$size" "$pct" "$mnt"
  done

# Docker
echo ""
echo "--- Docker ---"
docker_dir_size=$(du -sh /var/lib/docker 2>/dev/null | cut -f1 || echo "н/д")
echo "  /var/lib/docker: $docker_dir_size"

containers_total=$(docker ps -a -q 2>/dev/null | wc -l)
containers_run=$(docker ps -q 2>/dev/null | wc -l)
images_count=$(docker images -q 2>/dev/null | wc -l)
volumes_count=$(docker volume ls -q 2>/dev/null | wc -l)
echo "  Контейнеры:    $containers_run запущено / $containers_total всего"
echo "  Образы:        $images_count"
echo "  Тома:          $volumes_count"

# docker system df
echo ""
docker system df 2>/dev/null | sed 's/^/  /' || true

# Swarm
echo ""
echo "--- Swarm ---"
if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q "active"; then
  node_count=$(docker node ls -q 2>/dev/null | wc -l)
  service_count=$(docker service ls -q 2>/dev/null | wc -l)
  echo "  Узлов Swarm:   $node_count"
  echo "  Сервисов:      $service_count"
  echo ""
  docker service ls --format "  {{.Name}}\t{{.Replicas}}\t{{.Image}}" 2>/dev/null | head -20
fi

echo ""
echo "=== Конец отчёта ==="
} | tee "$REPORT_FILE"

echo ""
echo "Отчёт сохранён: $REPORT_FILE"
