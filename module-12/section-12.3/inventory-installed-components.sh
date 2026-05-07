#!/usr/bin/env bash
# Инвентаризация установленных компонентов Docker-инфраструктуры
# Формирует технический паспорт для аттестационной документации
# Использование: bash inventory-installed-components.sh [выходной_файл]
set -euo pipefail

OUTPUT="${1:-inventory-$(hostname)-$(date +%Y%m%d).txt}"

{
echo "=== Технический паспорт Docker-инфраструктуры ==="
echo "Хост: $(hostname)"
echo "Дата: $(date)"
echo "ОС:   $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || uname -sr)"
echo ""

# --- Ядро и ОС ---
echo "================================================================"
echo "ОПЕРАЦИОННАЯ СИСТЕМА"
echo "================================================================"
uname -r
cat /etc/os-release 2>/dev/null || true
echo ""

# --- Docker ---
echo "================================================================"
echo "DOCKER ENGINE"
echo "================================================================"
if command -v docker &>/dev/null; then
  docker version 2>/dev/null || echo "Docker daemon недоступен"
  echo ""
  echo "--- daemon.json ---"
  cat /etc/docker/daemon.json 2>/dev/null || echo "(файл отсутствует)"
  echo ""
  echo "--- Storage driver ---"
  docker info --format 'StorageDriver: {{.Driver}}' 2>/dev/null || true
  echo "--- Logging driver ---"
  docker info --format 'LoggingDriver: {{.LoggingDriver}}' 2>/dev/null || true
else
  echo "Docker не установлен"
fi

# --- containerd ---
echo ""
echo "================================================================"
echo "CONTAINERD"
echo "================================================================"
if command -v containerd &>/dev/null; then
  containerd --version 2>/dev/null || true
else
  echo "containerd не найден"
fi

# --- Harbor ---
echo ""
echo "================================================================"
echo "HARBOR"
echo "================================================================"
for harbor_dir in /opt/harbor /home/harbor /data/harbor; do
  if [ -f "$harbor_dir/harbor.yml" ]; then
    echo "Директория установки: $harbor_dir"
    grep -E '^hostname:|version:' "$harbor_dir/harbor.yml" 2>/dev/null || true
    if [ -f "$harbor_dir/common/config/harbor.cfg" ]; then
      grep 'hostname' "$harbor_dir/common/config/harbor.cfg" 2>/dev/null | head -3 || true
    fi
    # Версия из docker-compose
    grep -m1 'image:.*harbor' "$harbor_dir/docker-compose.yml" 2>/dev/null | head -3 || true
    break
  fi
done

# Через API Harbor (если доступен)
if command -v curl &>/dev/null; then
  harbor_api=$(curl -sk "https://harbor.internal/api/v2.0/systeminfo" 2>/dev/null | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('harbor_version',''))" 2>/dev/null || true)
  [ -n "$harbor_api" ] && echo "Версия Harbor (API): $harbor_api"
fi

# --- GitLab ---
echo ""
echo "================================================================"
echo "GITLAB"
echo "================================================================"
if command -v gitlab-rake &>/dev/null; then
  gitlab-rake gitlab:version 2>/dev/null | head -5 || true
elif command -v docker &>/dev/null; then
  gitlab_ver=$(docker exec gitlab gitlab-rake gitlab:version 2>/dev/null | head -3 || true)
  [ -n "$gitlab_ver" ] && echo "$gitlab_ver" || echo "GitLab контейнер недоступен"
else
  echo "GitLab не обнаружен"
fi

# --- Vault ---
echo ""
echo "================================================================"
echo "VAULT"
echo "================================================================"
if command -v vault &>/dev/null; then
  vault version 2>/dev/null || true
  vault status 2>/dev/null | grep -E 'Version|Sealed|HA|Storage' || true
else
  echo "Vault не найден в PATH"
fi

# --- Prometheus / Grafana / Loki ---
echo ""
echo "================================================================"
echo "МОНИТОРИНГ"
echo "================================================================"
if command -v docker &>/dev/null; then
  for svc in prometheus grafana loki promtail alertmanager; do
    ver=$(docker ps --filter "name=$svc" --format '{{.Image}}' 2>/dev/null | head -1)
    [ -n "$ver" ] && echo "  $svc: $ver" || echo "  $svc: не запущен"
  done
fi

# --- Trivy ---
echo ""
echo "================================================================"
echo "TRIVY"
echo "================================================================"
if command -v trivy &>/dev/null; then
  trivy --version 2>/dev/null | head -2 || true
else
  echo "Trivy не найден"
fi

# --- Сетевые интерфейсы ---
echo ""
echo "================================================================"
echo "СЕТЕВЫЕ ИНТЕРФЕЙСЫ"
echo "================================================================"
ip addr show 2>/dev/null | grep -E 'inet |^[0-9]+:' | grep -v '127.0.0.1' || true

# --- Docker-сети ---
echo ""
echo "================================================================"
echo "DOCKER СЕТИ"
echo "================================================================"
if command -v docker &>/dev/null; then
  docker network ls 2>/dev/null || true
fi

# --- Хосты Docker (из /etc/hosts) ---
echo ""
echo "================================================================"
echo "ХОСТЫ (из /etc/hosts — внутренняя DNS)"
echo "================================================================"
grep -v '^#\|^$\|127.0.0.1\|::1' /etc/hosts 2>/dev/null || true

echo ""
echo "================================================================"
echo "Конец инвентаризации"
echo "Файл: $OUTPUT"
echo "================================================================"

} | tee "$OUTPUT"

echo ""
echo "Инвентаризация сохранена: $OUTPUT"
echo "Используйте как основу для технического паспорта (Раздел 12.3)."
