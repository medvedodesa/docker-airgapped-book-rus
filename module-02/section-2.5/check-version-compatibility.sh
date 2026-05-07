#!/usr/bin/env bash
# Проверка совместимости версий docker-ce, containerd.io, runc перед обновлением
set -euo pipefail

TARGET_DOCKER="${1:-}"   # ожидаемая целевая версия, например 26.1.4
TARGET_CONTAINERD="${2:-}"

echo "=== Проверка совместимости версий Docker ==="
echo

echo "--- Текущие версии ---"
docker_current=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "не установлен")
containerd_current=$(containerd --version 2>/dev/null | awk '{print $3}' || echo "не установлен")
runc_current=$(runc --version 2>/dev/null | head -1 | awk '{print $3}' || echo "не установлен")

echo "docker-ce:      $docker_current"
echo "containerd.io:  $containerd_current"
echo "runc:           $runc_current"
echo

echo "--- Проверка зависимостей пакетов ---"
if command -v dpkg &>/dev/null; then
  dpkg -l docker-ce containerd.io 2>/dev/null | grep -E "^ii" | awk '{print $2, $3}' || true
elif command -v rpm &>/dev/null; then
  rpm -qa docker-ce containerd.io 2>/dev/null || true
fi

if [ -n "$TARGET_DOCKER" ]; then
  echo
  echo "--- Целевая версия: docker-ce $TARGET_DOCKER ---"
  echo "Для проверки зависимостей целевого пакета используйте:"
  echo "  apt-cache show docker-ce=$TARGET_DOCKER | grep Depends"
  echo "или проверьте Nexus/локальный репозиторий"
fi

echo
echo "--- Известные уязвимости (offline базы CVE) ---"
CVE_DB="${CVE_DB_PATH:-/opt/cve-data}"
if [ -d "$CVE_DB" ]; then
  echo "Проверка по локальной базе CVE в $CVE_DB"
  for component in docker-ce containerd runc; do
    hits=$(grep -r "$component" "$CVE_DB" 2>/dev/null | grep -i "critical\|high" | wc -l || true)
    echo "  $component: $hits записей CRITICAL/HIGH"
  done
else
  echo "Локальная база CVE не найдена ($CVE_DB)"
  echo "Для офлайн-проверки скачайте NVD JSON feeds и распакуйте в $CVE_DB"
  echo "  nvd.nist.gov/vuln/data-feeds → nvdcve-1.1-recent.json.gz"
fi

echo
echo "=== Проверка завершена — сохраните вывод как артефакт перед обновлением ==="
