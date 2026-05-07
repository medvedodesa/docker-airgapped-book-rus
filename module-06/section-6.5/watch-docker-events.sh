#!/usr/bin/env bash
# Фоновый сбор сетевых событий Docker в systemd journal и Loki
# Использование:
#   bash watch-docker-events.sh                  — запуск в foreground
#   bash watch-docker-events.sh --daemon         — запуск через systemd-run
#   bash watch-docker-events.sh --install        — установка systemd-юнита
set -euo pipefail

MODE="${1:---foreground}"
LOKI_URL="${LOKI_URL:-}"
LOG_TAG="${LOG_TAG:-docker-network-events}"
FILTER_TYPES="${DOCKER_EVENT_TYPES:-network,container}"

# ── Установка systemd-юнита ────────────────────────────────────────────────
install_unit() {
  local unit_file="/etc/systemd/system/docker-network-watcher.service"
  local script_path
  script_path="$(realpath "$0")"

  cat > "$unit_file" <<EOF
[Unit]
Description=Docker Network Events Watcher
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=/usr/bin/bash $script_path --foreground
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$LOG_TAG
Environment=LOKI_URL=$LOKI_URL

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now docker-network-watcher.service
  echo "Юнит установлен и запущен: docker-network-watcher.service"
  echo "Просмотр: journalctl -u docker-network-watcher -f"
  exit 0
}

# ── Запуск через systemd-run ───────────────────────────────────────────────
start_daemon() {
  systemd-run --unit=docker-network-watcher \
    --description="Docker Network Events Watcher" \
    /usr/bin/bash "$(realpath "$0")" --foreground
  echo "Запущено в фоне: systemctl status docker-network-watcher"
  exit 0
}

[ "$MODE" = "--install" ] && install_unit
[ "$MODE" = "--daemon"  ] && start_daemon

# ── Foreground: обработка событий ─────────────────────────────────────────
send_to_loki() {
  local message="$1" level="$2" event_type="$3" container_name="$4"
  [ -z "$LOKI_URL" ] && return 0

  local now_ns
  now_ns=$(date +%s%N 2>/dev/null || python3 -c "import time; print(int(time.time()*1e9))")

  local payload
  payload=$(python3 -c "
import json
print(json.dumps({
  'streams': [{
    'stream': {
      'job': 'docker-events',
      'host': '$(hostname)',
      'level': '$level',
      'event_type': '$event_type',
      'container': '$container_name'
    },
    'values': [['$now_ns', json.dumps({'message': '''$message'''})]]
  }]
}))
" 2>/dev/null) || return 0

  curl -sf --max-time 3 \
    -H "Content-Type: application/json" \
    -X POST "$LOKI_URL/loki/api/v1/push" \
    -d "$payload" >/dev/null 2>&1 || true
}

classify_event() {
  local action="$1"
  case "$action" in
    connect|create)              echo "info" ;;
    disconnect|destroy)          echo "info" ;;
    die|kill|oom)                echo "warning" ;;
    exec_create|exec_start)      echo "warning" ;;
    update|rename)               echo "info" ;;
    *)                           echo "debug" ;;
  esac
}

echo "=== Docker Network Events Watcher ===" | systemd-cat -t "$LOG_TAG" 2>/dev/null || \
  echo "=== Docker Network Events Watcher ==="
echo "Фильтр: $FILTER_TYPES  |  Loki: ${LOKI_URL:-(не настроен)}  |  Дата: $(date '+%Y-%m-%d %H:%M')" | \
  systemd-cat -t "$LOG_TAG" 2>/dev/null || true

# Основной цикл обработки событий
docker events \
  --filter "type=network" \
  --filter "type=container" \
  --format '{{json .}}' 2>/dev/null | while IFS= read -r event_json; do

  # Парсинг полей события
  event_type=$(echo "$event_json"   | python3 -c "import json,sys; print(json.load(sys.stdin).get('Type','?'))"   2>/dev/null || echo "?")
  action=$(echo "$event_json"       | python3 -c "import json,sys; print(json.load(sys.stdin).get('Action','?'))" 2>/dev/null || echo "?")
  actor_id=$(echo "$event_json"     | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Actor',{}).get('ID','?')[:12])" 2>/dev/null || echo "?")
  actor_name=$(echo "$event_json"   | python3 -c "
import json,sys
d = json.load(sys.stdin)
attrs = d.get('Actor',{}).get('Attributes',{})
print(attrs.get('name', attrs.get('container','?'))[:40])
" 2>/dev/null || echo "?")
  network_name=$(echo "$event_json" | python3 -c "
import json,sys
d = json.load(sys.stdin)
attrs = d.get('Actor',{}).get('Attributes',{})
print(attrs.get('network',''))
" 2>/dev/null || echo "")
  ts=$(date '+%Y-%m-%d %H:%M:%S')

  level=$(classify_event "$action")

  # Формируем читаемое сообщение
  case "$event_type" in
    network)
      msg="$ts [NETWORK] $action: ${actor_name:-$actor_id}"
      ;;
    container)
      if [ -n "$network_name" ]; then
        msg="$ts [CONTAINER] $action: ${actor_name:-$actor_id} (сеть: $network_name)"
      else
        msg="$ts [CONTAINER] $action: ${actor_name:-$actor_id}"
      fi
      ;;
    *)
      msg="$ts [$event_type] $action: ${actor_name:-$actor_id}"
      ;;
  esac

  # Вывод с приоритетом по уровню
  case "$level" in
    warning) prefix="[WARN]" ;;
    info)    prefix="[INFO]" ;;
    *)       prefix="[DEBUG]" ;;
  esac

  full_msg="$prefix $msg"
  echo "$full_msg" | systemd-cat -t "$LOG_TAG" -p "$level" 2>/dev/null || echo "$full_msg"

  # Отправка в Loki для warning-событий и выше
  if [ "$level" = "warning" ]; then
    send_to_loki "$msg" "$level" "$event_type" "${actor_name:-$actor_id}"
  fi

  # Особые события — расширенное логирование
  case "$action" in
    oom)
      alert_msg="OOM KILL: контейнер ${actor_name:-$actor_id} завершён ядром из-за нехватки памяти"
      echo "[CRITICAL] $ts $alert_msg" | systemd-cat -t "$LOG_TAG" -p "alert" 2>/dev/null || \
        echo "[CRITICAL] $alert_msg"
      send_to_loki "$alert_msg" "critical" "container" "${actor_name:-$actor_id}"
      ;;
    exec_start)
      alert_msg="EXEC в контейнере: ${actor_name:-$actor_id} — команда выполняется внутри контейнера"
      echo "[WARN] $ts $alert_msg" | systemd-cat -t "$LOG_TAG" -p "warning" 2>/dev/null || \
        echo "[WARN] $alert_msg"
      send_to_loki "$alert_msg" "warning" "container" "${actor_name:-$actor_id}"
      ;;
  esac
done
