#!/usr/bin/env bash
# Установка Docker из локальных .rpm пакетов (RHEL/Rocky/AlmaLinux/РедОС).
# Использование: sudo bash install-docker-rpm.sh [директория_с_пакетами]
set -euo pipefail

PKG_DIR="${1:-./packages}"

echo "=== Установка Docker из .rpm пакетов ==="
echo "  Директория: $PKG_DIR"

[ -d "$PKG_DIR" ] || { echo "Директория $PKG_DIR не найдена"; exit 1; }
rpm_count=$(ls -1 "$PKG_DIR"/*.rpm 2>/dev/null | wc -l)
[ "$rpm_count" -gt 0 ] || { echo "Нет .rpm файлов в $PKG_DIR"; exit 1; }

# Проверка целостности
echo ""
echo "--- Проверка целостности ---"
if [ -f "$(dirname "$PKG_DIR")/SHA256SUMS" ]; then
  cd "$(dirname "$PKG_DIR")"
  sha256sum -c SHA256SUMS 2>/dev/null | grep FAILED && { echo "ОШИБКА: повреждённые пакеты!"; exit 1; } || \
    echo "[PASS] Контрольные суммы верны"
  cd - >/dev/null
fi

# container-selinux (нужен на RHEL/Rocky)
echo ""
echo "--- Предварительные зависимости ---"
if rpm -q container-selinux &>/dev/null; then
  echo "[OK] container-selinux установлен"
elif ls "$PKG_DIR"/container-selinux*.rpm &>/dev/null 2>&1; then
  rpm -ivh "$PKG_DIR"/container-selinux*.rpm 2>&1 | tail -2
  echo "[OK] container-selinux установлен из пакета"
else
  echo "[WARN] container-selinux не найден — Docker может работать некорректно с SELinux"
fi

# Установка
echo ""
echo "--- Установка Docker ---"
rpm -ivh --nodeps "$PKG_DIR"/*.rpm 2>&1 | tail -5

# Запуск
echo ""
echo "--- Запуск Docker daemon ---"
systemctl daemon-reload
systemctl start docker
systemctl enable docker

# Верификация
echo ""
echo "--- Верификация ---"
docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
if [ -n "$docker_ver" ]; then
  echo "[PASS] Docker $docker_ver запущен"
else
  echo "[FAIL] Docker daemon не отвечает"
  journalctl -u docker -n 20
  exit 1
fi

echo ""
echo "Установка завершена. Запустите verify-installation.sh для полной проверки."
