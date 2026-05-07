#!/usr/bin/env bash
# Проверка совместимости версий docker-ce и containerd.io между машиной-источником и целевым хостом
# Использование: bash check-version-compatibility.sh [файл_версий_источника]
set -euo pipefail

VERSIONS_FILE="${1:-bundle-versions.txt}"

PASS=0; FAIL=0; WARN=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }

echo "=== Проверка совместимости версий ==="
echo "Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"

# --- Версия ОС ---
echo ""
echo "--- Операционная система ---"
if [ -f /etc/os-release ]; then
  . /etc/os-release
  ok "ОС: $PRETTY_NAME"
  echo "    ID: $ID  VERSION_ID: ${VERSION_ID:-unknown}"
else
  fail "Файл /etc/os-release не найден — не удаётся определить дистрибутив"
fi

# --- Версии установленного Docker ---
echo ""
echo "--- Установленные компоненты Docker ---"
if command -v docker &>/dev/null; then
  docker_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "недоступен")
  ok "docker: $docker_ver"
else
  warn "docker не установлен или демон не запущен"
  docker_ver="не установлен"
fi

if command -v containerd &>/dev/null; then
  ct_ver=$(containerd --version 2>/dev/null | awk '{print $3}' | tr -d 'v')
  ok "containerd: $ct_ver"
else
  warn "containerd не найден в PATH"
  ct_ver="не найден"
fi

# --- Сравнение с пакетами в бандле ---
echo ""
echo "--- Пакеты в передаточном бандле ---"
if [ -f "$VERSIONS_FILE" ]; then
  while IFS='=' read -r pkg ver; do
    [[ "$pkg" =~ ^# ]] && continue
    [[ -z "$pkg" ]] && continue
    echo "    $pkg = $ver"
  done < "$VERSIONS_FILE"
  ok "Файл версий прочитан: $VERSIONS_FILE"
else
  warn "Файл версий не найден: $VERSIONS_FILE — ручная проверка совместимости"
  echo "    Ожидаемый формат файла:"
  echo "    docker-ce=26.1.4"
  echo "    containerd.io=1.6.33"
fi

# --- Проверка совместимости мажорных версий ---
echo ""
echo "--- Совместимость мажорных версий ---"
if [ -f "$VERSIONS_FILE" ] && [ "$docker_ver" != "не установлен" ]; then
  bundle_docker=$(grep '^docker-ce=' "$VERSIONS_FILE" 2>/dev/null | cut -d= -f2 || echo "")
  if [ -n "$bundle_docker" ]; then
    installed_major=$(echo "$docker_ver" | cut -d. -f1)
    bundle_major=$(echo "$bundle_docker" | cut -d. -f1)
    if [ "$installed_major" = "$bundle_major" ]; then
      ok "Мажорная версия docker-ce совпадает: $installed_major.x"
    else
      fail "Мажорная версия docker-ce не совпадает: установлен $docker_ver, в бандле $bundle_docker"
    fi
  fi
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Статус: НЕСОВМЕСТИМО — исправьте FAIL перед переносом бандла"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo "Статус: ПРЕДУПРЕЖДЕНИЯ — проверьте WARN вручную"
  exit 0
else
  echo "Статус: СОВМЕСТИМО"
  exit 0
fi
