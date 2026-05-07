#!/usr/bin/env bash
# Проверка пути обновления GitLab и подготовка к обновлению
# GitLab требует последовательного прохождения промежуточных версий
# Использование: bash gitlab-upgrade-path.sh [текущая_версия] [целевая_версия]
set -euo pipefail

CURRENT_VERSION="${1:-$(gitlab-rake gitlab:env:info 2>/dev/null | grep 'GitLab version' | awk '{print $NF}' || echo '')}"
TARGET_VERSION="${2:-}"
BACKUP_DIR="${GITLAB_BACKUP_DIR:-/var/opt/gitlab/backups}"
GITLAB_CONFIG="${GITLAB_CONFIG:-/etc/gitlab/gitlab.rb}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Проверка пути обновления GitLab ==="
echo "Текущая версия:  ${CURRENT_VERSION:-(определить не удалось)}"
echo "Целевая версия:  ${TARGET_VERSION:-(не указана — только проверка текущего)}"
echo "Дата:            $(date '+%Y-%m-%d %H:%M')"

# --- Определение текущей версии ---
echo ""
echo "--- Текущая установка ---"
if command -v gitlab-rake &>/dev/null; then
  installed_version=$(gitlab-rake gitlab:env:info 2>/dev/null | grep "GitLab version" | awk '{print $NF}' || echo "")
  [ -n "$installed_version" ] && CURRENT_VERSION="$installed_version"
fi

if [ -z "$CURRENT_VERSION" ]; then
  fail "Не удалось определить текущую версию GitLab — укажите первым аргументом"
  exit 1
fi
ok "Текущая версия: $CURRENT_VERSION"

# Извлекаем мажорную и минорную версию
CURRENT_MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2)
CURRENT_PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3 | cut -d- -f1)

# --- Правила пути обновления GitLab ---
echo ""
echo "--- Путь обновления ---"
echo ""
echo "Правила обновления GitLab (официальные):"
echo "  1. Нельзя пропускать мажорные версии (14→15→16, не 14→16)"
echo "  2. Перед переходом на следующую мажорную версию — обновить"
echo "     до последнего патча текущей минорной версии"
echo "  3. Некоторые минорные версии обязательны как промежуточные:"

# Обязательные промежуточные версии (исторические данные GitLab)
declare -A REQUIRED_STOPS=(
  ["8"]="8.11.11"
  ["9"]="9.5.10"
  ["10"]="10.8.7"
  ["11"]="11.11.8"
  ["12"]="12.10.14"
  ["13"]="13.1.11 13.8.8 13.12.15"
  ["14"]="14.0.12 14.3.6 14.9.5 14.10.5"
  ["15"]="15.0.5 15.4.6 15.11.13"
  ["16"]="16.0.8 16.1.6 16.3.7 16.7.7 16.11.10"
  ["17"]="17.1.7 17.3.6 17.5.5"
)

for major in $(echo "${!REQUIRED_STOPS[@]}" | tr ' ' '\n' | sort -n); do
  if [ "$major" -ge "$CURRENT_MAJOR" ] 2>/dev/null; then
    stops="${REQUIRED_STOPS[$major]}"
    echo "  GitLab $major.x: обязательные остановки → $stops"
  fi
done

echo ""

if [ -n "$TARGET_VERSION" ]; then
  TARGET_MAJOR=$(echo "$TARGET_VERSION" | cut -d. -f1)
  TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)

  echo "  Путь: $CURRENT_VERSION → $TARGET_VERSION"
  echo ""

  if [ "$TARGET_MAJOR" -lt "$CURRENT_MAJOR" ] 2>/dev/null; then
    fail "Понижение версии GitLab не поддерживается ($CURRENT_MAJOR → $TARGET_MAJOR)"
  elif [ "$TARGET_MAJOR" -gt "$((CURRENT_MAJOR + 1))" ] 2>/dev/null; then
    fail "Нельзя перепрыгнуть через мажорную версию ($CURRENT_MAJOR → $TARGET_MAJOR)"
    echo ""
    echo "  Правильный путь:"
    for m in $(seq "$CURRENT_MAJOR" "$TARGET_MAJOR"); do
      stops="${REQUIRED_STOPS[$m]:-}"
      if [ -n "$stops" ]; then
        for stop in $stops; do
          smajor=$(echo "$stop" | cut -d. -f1)
          [ "$smajor" = "$m" ] && echo "    $m.x → $stop (обязательная остановка)"
        done
      fi
      next=$((m + 1))
      [ "$next" -le "$TARGET_MAJOR" ] && echo "    → $next.x"
    done
  else
    ok "Переход $CURRENT_VERSION → $TARGET_VERSION корректен"
  fi
fi

# --- Предварительные проверки ---
echo ""
echo "--- Предварительные проверки ---"

# 1. Резервная копия
if [ -d "$BACKUP_DIR" ]; then
  latest_backup=$(find "$BACKUP_DIR" -name "*.tar" -o -name "*_gitlab_backup.tar" \
    2>/dev/null | sort -r | head -1)
  if [ -n "$latest_backup" ]; then
    backup_age=$(( ($(date +%s) - $(stat -c %Y "$latest_backup" 2>/dev/null || echo 0)) / 3600 ))
    if [ "$backup_age" -lt 2 ]; then
      ok "Свежая резервная копия: $latest_backup (${backup_age}ч назад)"
    else
      fail "Резервная копия устарела (${backup_age}ч) — выполните gitlab-backup create"
    fi
  else
    fail "Резервная копия не найдена в $BACKUP_DIR — выполните: gitlab-backup create"
  fi
else
  warn "Директория резервных копий не найдена: $BACKUP_DIR"
fi

# 2. Состояние сервисов
if command -v gitlab-ctl &>/dev/null; then
  failed_services=$(gitlab-ctl status 2>/dev/null | grep -v "^run:" | grep -v "^ok:" | \
    grep -v "^$" | wc -l || echo 0)
  if [ "${failed_services:-0}" -eq 0 ]; then
    ok "Все сервисы GitLab работают"
  else
    warn "$failed_services сервисов GitLab не в норме — проверьте перед обновлением"
  fi
fi

# 3. Pending migrations
if command -v gitlab-rake &>/dev/null; then
  pending=$(gitlab-rake db:migrate:status 2>/dev/null | grep "down" | wc -l || echo 0)
  if [ "${pending:-0}" -eq 0 ]; then
    ok "Pending миграций нет"
  else
    fail "Pending миграций: $pending — выполните gitlab-rake db:migrate"
  fi
fi

# 4. Свободное место
if [ -d "$BACKUP_DIR" ]; then
  free_gb=$(df "$BACKUP_DIR" | awk 'NR==2{printf "%.0f", $4/1048576}')
  if [ "${free_gb:-0}" -gt 10 ]; then
    ok "Свободно на диске резервных копий: ${free_gb} ГБ"
  else
    warn "Мало свободного места: ${free_gb} ГБ (рекомендуется >10 ГБ)"
  fi
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Перед обновлением:"
echo "  1. gitlab-backup create SKIP=artifacts,builds,uploads,registry"
echo "  2. Проверьте путь обновления: https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/"
echo "  3. Скачайте пакет целевой версии в закрытый контур"
echo "  4. Примените на тестовой среде первым"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
