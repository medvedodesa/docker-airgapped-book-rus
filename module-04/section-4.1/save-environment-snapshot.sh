#!/usr/bin/env bash
# Снимок текущей конфигурации безопасности хоста и Docker
# Используется для сравнения с предыдущим состоянием при аудите
# Использование: bash save-environment-snapshot.sh [выходной_файл]
set -euo pipefail

OUTPUT="${1:-security-snapshot-$(hostname)-$(date +%Y%m%d).txt}"

{
echo "=== Снимок конфигурации безопасности ==="
echo "Хост: $(hostname)"
echo "Дата: $(date)"
echo "ОС:   $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
echo ""

# --- Docker ---
echo "=== Docker ==="
docker version 2>/dev/null || echo "Docker недоступен"
echo ""
echo "--- daemon.json ---"
cat /etc/docker/daemon.json 2>/dev/null || echo "(файл отсутствует)"
echo ""
echo "--- Запущенные контейнеры ---"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
echo ""
echo "--- Привилегированные контейнеры ---"
docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} privileged={{.HostConfig.Privileged}}' 2>/dev/null | grep -v 'privileged=false' || echo "(нет)"
echo ""
echo "--- Контейнеры с --network host ---"
docker ps -q 2>/dev/null | xargs -r docker inspect --format '{{.Name}} network={{.HostConfig.NetworkMode}}' 2>/dev/null | grep 'network=host' || echo "(нет)"

# --- SELinux / AppArmor ---
echo ""
echo "=== MAC (SELinux / AppArmor) ==="
if command -v getenforce &>/dev/null; then
  echo "SELinux: $(getenforce 2>/dev/null)"
  sestatus 2>/dev/null | grep -E 'SELinux status|Current mode|Policy' || true
elif command -v aa-status &>/dev/null; then
  echo "AppArmor: $(aa-status --enabled 2>/dev/null && echo enabled || echo disabled)"
else
  echo "Ни SELinux, ни AppArmor не обнаружены"
fi

# --- Docker group ---
echo ""
echo "=== Группа docker ==="
getent group docker 2>/dev/null || echo "Группа docker не найдена"
echo "Члены группы docker (риск эскалации привилегий):"
getent group docker 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$' | sed 's/^/  /' || true

# --- Docker socket ---
echo ""
echo "=== Docker socket ==="
ls -la /var/run/docker.sock 2>/dev/null || echo "Docker socket не найден"
echo "Процессы с доступом к socket:"
lsof /var/run/docker.sock 2>/dev/null | awk 'NR>1{print $1, $2, $3}' | sort -u | head -10 || true

# --- Открытые порты Docker API ---
echo ""
echo "=== Docker API (удалённый доступ) ==="
ss -tnlp 2>/dev/null | grep -E ':2375|:2376|:2377' || echo "Docker API на внешних портах не обнаружен (корректно)"

# --- Ядро и параметры ---
echo ""
echo "=== Параметры ядра ==="
for param in net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward user.max_user_namespaces; do
  echo "  $param = $(sysctl -n "$param" 2>/dev/null || echo '?')"
done

# --- Образы ---
echo ""
echo "=== Образы Docker ==="
docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}' 2>/dev/null | head -20 || true
echo "Итого образов: $(docker images -q 2>/dev/null | wc -l)"

echo ""
echo "=== Конец снимка ==="
echo "Файл: $OUTPUT"

} | tee "$OUTPUT"

echo ""
echo "Снимок сохранён: $OUTPUT"
echo "Сравнение с предыдущим снимком: diff <предыдущий_файл> $OUTPUT"
