#!/usr/bin/env bash
# Полная процедура восстановления инфраструктуры из резервных копий
# Порядок: DNS → Vault → Harbor → Базы данных → Сервисы → GitLab
# Использование: bash full-restore-procedure.sh [backup_dir] [--dry-run]
set -euo pipefail

BACKUP_DIR="${1:-/opt/backups/latest}"
DRY_RUN="${2:-}"
[ "$DRY_RUN" = "--dry-run" ] && DRY_RUN=true || DRY_RUN=false

HARBOR_URL="${HARBOR_URL:-https://harbor.internal.company.local}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://prometheus.internal:9090}"

PASS=0; WARN=0; FAIL=0
STEP=0
START_TIME=$(date +%s)

ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }
step() { ((STEP++)); echo ""; echo "══════════════════════════════════════════════"; echo "Шаг $STEP: $1"; echo "══════════════════════════════════════════════"; }
run()  { $DRY_RUN && echo "  [DRY-RUN] $*" || eval "$@"; }

echo "=== Полная процедура восстановления инфраструктуры ==="
echo "Резервные копии: $BACKUP_DIR"
echo "Режим:           $([ "$DRY_RUN" = true ] && echo 'DRY RUN — изменения не применяются' || echo 'РЕАЛЬНОЕ ВОССТАНОВЛЕНИЕ')"
echo "Дата:            $(date '+%Y-%m-%d %H:%M')"
echo ""
echo "ВНИМАНИЕ: Убедитесь что все сервисы остановлены перед началом."
if [ "$DRY_RUN" != true ]; then
  echo "Продолжить? [y/N]"
  read -r confirm
  [ "$confirm" = "y" ] || [ "$confirm" = "Y" ] || { echo "Отменено."; exit 0; }
fi

# ── Шаг 1: Проверка наличия резервных копий ───────────────────────────────
step "Проверка резервных копий"

[ -d "$BACKUP_DIR" ] || { fail "Директория не найдена: $BACKUP_DIR"; exit 1; }
ok "Директория найдена: $BACKUP_DIR"

for component in vault postgres harbor gitlab; do
  found=$(find "$BACKUP_DIR" -name "*${component}*" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    ok "Резервная копия $component: $(basename "$found")"
  else
    warn "Резервная копия $component не найдена в $BACKUP_DIR"
  fi
done

# ── Шаг 2: Восстановление сети и DNS ─────────────────────────────────────
step "Сеть и DNS"
echo "Проверяем доступность базовой сети..."
if ping -c 1 -W 2 "$(ip route | awk '/default/{print $3}' | head -1)" &>/dev/null 2>&1; then
  ok "Сеть доступна"
else
  warn "Сеть недоступна — проверьте сетевые настройки хоста"
fi

if command -v coredns &>/dev/null || docker ps --format '{{.Names}}' 2>/dev/null | grep -q coredns; then
  ok "CoreDNS запущен"
else
  warn "CoreDNS не найден — запустите DNS-сервис перед продолжением"
fi

# ── Шаг 3: Восстановление Vault ──────────────────────────────────────────
step "Vault (секреты и PKI)"

vault_snapshot=$(find "$BACKUP_DIR" -name "vault-*.snap" 2>/dev/null | sort -r | head -1)
if [ -n "$vault_snapshot" ]; then
  ok "Снимок Vault: $vault_snapshot"

  if [ "$DRY_RUN" != true ]; then
    echo "  Запуск нового Vault..."
    systemctl start vault 2>/dev/null || docker compose -f /opt/vault/docker-compose.yml up -d vault 2>/dev/null || true
    sleep 5

    echo "  Инициализация и восстановление..."
    if curl -sf "$VAULT_ADDR/v1/sys/health" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized',True))" | grep -q False; then
      warn "Vault не инициализирован — выполните vault operator init, затем vault operator raft snapshot restore"
    else
      echo "  Vault уже инициализирован — восстановление снимка:"
      echo "  VAULT_TOKEN=<root_token> vault operator raft snapshot restore $vault_snapshot"
    fi
  else
    echo "  [DRY-RUN] vault operator raft snapshot restore $vault_snapshot"
  fi
else
  warn "Снимок Vault не найден — восстановите секреты вручную"
fi

# ── Шаг 4: Восстановление Harbor ─────────────────────────────────────────
step "Harbor (реестр образов)"

harbor_db_dump=$(find "$BACKUP_DIR" -name "harbor-db*.sql*" 2>/dev/null | sort -r | head -1)
harbor_data=$(find "$BACKUP_DIR" -name "harbor-data*" -type f 2>/dev/null | sort -r | head -1)

if [ -n "$harbor_db_dump" ]; then
  ok "Дамп БД Harbor: $harbor_db_dump"
  if [ "$DRY_RUN" != true ]; then
    echo "  Восстановление БД Harbor..."
    if [[ "$harbor_db_dump" == *.gz ]]; then
      gunzip -c "$harbor_db_dump" | docker exec -i harbor-db psql -U postgres -d registry 2>/dev/null && ok "БД Harbor восстановлена" || warn "Ошибка восстановления БД Harbor"
    else
      docker exec -i harbor-db psql -U postgres -d registry < "$harbor_db_dump" 2>/dev/null && ok "БД Harbor восстановлена" || warn "Ошибка восстановления БД Harbor"
    fi
  fi
fi

if [ -n "$harbor_data" ]; then
  ok "Blob-хранилище Harbor: $harbor_data"
  [ "$DRY_RUN" = true ] && echo "  [DRY-RUN] tar xzf $harbor_data -C /data/harbor/"
fi

run "docker compose -f /opt/harbor/docker-compose.yml up -d 2>/dev/null || true"

# ── Шаг 5: Восстановление баз данных ─────────────────────────────────────
step "Базы данных приложений"

for dump in $(find "$BACKUP_DIR" -name "*.sql.gz" -o -name "*postgres*.sql" 2>/dev/null); do
  db_name=$(basename "$dump" | sed 's/-[0-9].*//;s/\.sql.*//')
  ok "Найден дамп: $db_name ($dump)"
  if [ "$DRY_RUN" != true ]; then
    run "bash restore-postgres.sh '$dump' '$db_name' 2>/dev/null || warn 'Ошибка восстановления $db_name'"
  fi
done

# ── Шаг 6: Запуск сервисов ────────────────────────────────────────────────
step "Запуск прикладных сервисов"

for compose_file in /opt/*/docker-compose.yml /srv/*/docker-compose.yml; do
  [ -f "$compose_file" ] || continue
  service_dir=$(dirname "$compose_file")
  service_name=$(basename "$service_dir")
  echo "  Запуск: $service_name"
  run "docker compose -f '$compose_file' up -d 2>/dev/null || true"
done

# ── Шаг 7: GitLab (последним) ────────────────────────────────────────────
step "GitLab (последним — не нужен для работы продакшена)"

gitlab_backup=$(find "$BACKUP_DIR" -name "*gitlab_backup.tar" 2>/dev/null | sort -r | head -1)
if [ -n "$gitlab_backup" ]; then
  ok "Резервная копия GitLab: $gitlab_backup"
  if [ "$DRY_RUN" != true ]; then
    cp "$gitlab_backup" /var/opt/gitlab/backups/ 2>/dev/null || true
    echo "  gitlab-backup restore BACKUP=$(basename "$gitlab_backup" _gitlab_backup.tar)"
    warn "Запустите восстановление GitLab вручную после проверки остальных сервисов"
  fi
fi

# ── Итог ─────────────────────────────────────────────────────────────────
ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
echo "════════════════════════════════════════════════════"
echo "=== Итог восстановления ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo "Время: $((ELAPSED / 60)) мин $((ELAPSED % 60)) сек"
echo ""
echo "Следующие шаги:"
echo "  1. Проверьте Vault: curl $VAULT_ADDR/v1/sys/health"
echo "  2. Проверьте Harbor: curl -sf $HARBOR_URL/api/v2.0/ping"
echo "  3. Проверьте мониторинг: $PROMETHEUS_URL/targets"
echo "  4. Запустите: bash morning-check.sh"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
