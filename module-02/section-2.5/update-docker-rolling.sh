#!/usr/bin/env bash
# Последовательное обновление Docker Engine на нескольких хостах (rolling update)
# Использование: update-docker-rolling.sh hosts.txt /path/to/packages/
set -euo pipefail

HOSTS_FILE="${1:-hosts.txt}"
PACKAGES_DIR="${2:-.}"
LOG_FILE="update-docker-rolling-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

if [ ! -f "$HOSTS_FILE" ]; then
  echo "Файл с хостами не найден: $HOSTS_FILE"
  echo "Формат: один хост на строку (user@host)"
  exit 1
fi

HOSTS=()
while IFS= read -r host; do
  [[ "$host" =~ ^#|^$ ]] && continue
  HOSTS+=("$host")
done < "$HOSTS_FILE"

log "Rolling update для ${#HOSTS[@]} хостов"
log "Пакеты: $PACKAGES_DIR"
log "Журнал: $LOG_FILE"

for host in "${HOSTS[@]}"; do
  log "=== Начало обновления: $host ==="

  # Проверить доступность
  if ! ssh -o ConnectTimeout=10 "$host" true 2>/dev/null; then
    log "FAIL: $host недоступен — пропуск"
    continue
  fi

  # Сохранить список контейнеров до обновления
  log "$host: сохранение состояния контейнеров..."
  ssh "$host" "docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'" >> "$LOG_FILE" 2>&1 || true

  # Скопировать пакеты
  log "$host: копирование пакетов..."
  scp "$PACKAGES_DIR"/*.deb "$host:/tmp/docker-update/" 2>>"$LOG_FILE" || {
    log "FAIL: $host — ошибка копирования пакетов"
    continue
  }

  # Обновить пакеты
  log "$host: установка пакетов..."
  ssh "$host" "
    set -e
    cd /tmp/docker-update
    dpkg -i containerd.io_*.deb || apt-get -f install -y
    dpkg -i docker-ce-cli_*.deb
    dpkg -i docker-ce_*.deb
    systemctl daemon-reload
    systemctl restart docker
    docker version --format 'Server: {{.Server.Version}}'
  " 2>>"$LOG_FILE" | tee -a "$LOG_FILE" || {
    log "FAIL: $host — ошибка при установке"
    log "Выполните откат вручную: dpkg -i <старые_пакеты>.deb && systemctl restart docker"
    continue
  }

  # Проверить работоспособность
  log "$host: проверка после обновления..."
  ssh "$host" "
    docker version
    docker info | grep 'Server Version'
    systemctl is-active docker
    docker ps --format 'Работает: {{.Names}}'
  " 2>>"$LOG_FILE" | tee -a "$LOG_FILE" || {
    log "WARN: $host — проверка после обновления не прошла полностью"
  }

  log "$host: обновление завершено успешно"
  echo
done

log "=== Rolling update завершён. Журнал: $LOG_FILE ==="
