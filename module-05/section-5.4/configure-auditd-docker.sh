#!/usr/bin/env bash
# Настройка auditd для мониторинга Docker-инфраструктуры
# Добавляет правила аудита для Docker daemon, сокетов, конфигурационных файлов и namespaces
set -euo pipefail

RULES_FILE="${AUDITD_RULES_FILE:-/etc/audit/rules.d/docker.rules}"
AUDIT_LOG="${AUDIT_LOG:-/var/log/audit/audit.log}"
RESTART_AUDITD="${RESTART_AUDITD:-true}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Настройка auditd для Docker ==="
echo "Хост:        $(hostname)"
echo "Файл правил: $RULES_FILE"
echo "Дата:        $(date '+%Y-%m-%d %H:%M')"

# --- Проверка прав ---
if [ "$(id -u)" -ne 0 ]; then
  echo "Требуются права root: sudo bash $0"
  exit 1
fi

# --- Проверка наличия auditd ---
echo ""
echo "--- auditd ---"
if ! command -v auditctl &>/dev/null; then
  fail "auditctl не найден — установите пакет auditd"
  exit 1
fi
ok "auditd установлен: $(auditctl --version 2>/dev/null | head -1)"

if systemctl is-active auditd &>/dev/null 2>&1; then
  ok "auditd: запущен"
else
  warn "auditd: не запущен — запуск..."
  systemctl start auditd && ok "auditd запущен" || fail "Не удалось запустить auditd"
  systemctl enable auditd || true
fi

# --- Создание файла правил ---
echo ""
echo "--- Создание правил аудита Docker ---"
mkdir -p "$(dirname "$RULES_FILE")"

cat > "$RULES_FILE" <<'RULES'
# Правила auditd для Docker-инфраструктуры в закрытом контуре
# Версия: 1.0  Источник: модуль 5, раздел 5.4

## ── Docker daemon ────────────────────────────────────────────────────────────
# Конфигурация Docker daemon
-w /etc/docker -p wa -k docker-daemon-config
-w /etc/docker/daemon.json -p rwa -k docker-daemon-config

# Docker сокеты
-w /var/run/docker.sock -p rwa -k docker-socket
-w /run/docker.sock -p rwa -k docker-socket

# systemd-юнит Docker
-w /lib/systemd/system/docker.service -p wa -k docker-service
-w /lib/systemd/system/docker.socket -p wa -k docker-service
-w /usr/lib/systemd/system/docker.service -p wa -k docker-service

## ── Бинарники Docker ─────────────────────────────────────────────────────────
-w /usr/bin/docker -p x -k docker-binary
-w /usr/bin/dockerd -p x -k docker-binary
-w /usr/bin/containerd -p x -k docker-binary
-w /usr/bin/runc -p x -k docker-binary
-w /usr/bin/containerd-shim -p x -k docker-binary
-w /usr/local/bin/docker -p x -k docker-binary

## ── Данные Docker ────────────────────────────────────────────────────────────
# Директория хранилища образов и контейнеров
-w /var/lib/docker -p wa -k docker-data

# TLS-сертификаты Docker
-w /etc/docker/certs.d -p rwa -k docker-certs

## ── Namespaces (выход из контейнера) ─────────────────────────────────────────
# Системные вызовы создания namespaces — потенциальный container escape
-a always,exit -F arch=b64 -S unshare -k container-namespaces
-a always,exit -F arch=b32 -S unshare -k container-namespaces
-a always,exit -F arch=b64 -S clone -F a0&268435456 -k container-namespaces
-a always,exit -F arch=b32 -S clone -F a0&268435456 -k container-namespaces

## ── Привилегированные операции ───────────────────────────────────────────────
# Использование setuid/setgid
-a always,exit -F arch=b64 -S setuid -S setgid -k setuid-setgid
-a always,exit -F arch=b32 -S setuid -S setgid -k setuid-setgid

# Монтирование (потенциальный побег из контейнера)
-a always,exit -F arch=b64 -S mount -k container-mount
-a always,exit -F arch=b32 -S mount -k container-mount

## ── Файлы конфигурации безопасности ─────────────────────────────────────────
-w /etc/passwd -p rwa -k identity
-w /etc/shadow -p rwa -k identity
-w /etc/group -p rwa -k identity
-w /etc/sudoers -p rwa -k sudoers
-w /etc/sudoers.d -p rwa -k sudoers

## ── Harbor / Vault (если используются) ──────────────────────────────────────
-w /opt/harbor -p wa -k harbor-config
-w /etc/harbor -p wa -k harbor-config
-w /opt/vault -p wa -k vault-binary
-w /etc/vault.d -p wa -k vault-config
RULES

ok "Файл правил создан: $RULES_FILE ($(wc -l < "$RULES_FILE") строк)"

# --- Применение правил ---
echo ""
echo "--- Применение правил ---"
if augenrules --load 2>/dev/null; then
  ok "Правила применены через augenrules"
elif auditctl -R "$RULES_FILE" 2>/dev/null; then
  ok "Правила применены через auditctl -R"
else
  warn "Не удалось применить правила автоматически — перезапустите auditd вручную"
fi

if [ "$RESTART_AUDITD" = "true" ]; then
  systemctl restart auditd 2>/dev/null && ok "auditd перезапущен" || warn "Перезапуск auditd не выполнен"
fi

# --- Проверка активных правил ---
echo ""
echo "--- Проверка активных правил ---"
docker_rules=$(auditctl -l 2>/dev/null | grep -c "docker\|container" || echo 0)
ok "Активных правил для Docker/контейнеров: $docker_rules"

# --- Настройка ротации журнала аудита ---
echo ""
echo "--- Ротация журнала ---"
AUDIT_CONF="/etc/audit/auditd.conf"
if [ -f "$AUDIT_CONF" ]; then
  # Проверяем max_log_file (МБ) и num_logs
  max_log=$(grep "^max_log_file " "$AUDIT_CONF" | awk '{print $3}' || echo 0)
  num_logs=$(grep "^num_logs " "$AUDIT_CONF" | awk '{print $3}' || echo 0)
  if [ "${max_log:-0}" -ge 100 ] && [ "${num_logs:-0}" -ge 10 ]; then
    ok "Ротация журнала: max_log_file=$max_log МБ, num_logs=$num_logs"
  else
    warn "Ротация журнала: рекомендуется max_log_file=100, num_logs=10 (текущее: $max_log МБ, $num_logs файлов)"
    echo "    Для изменения: отредактируйте $AUDIT_CONF"
  fi
fi

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Правила аудита Docker применены: $RULES_FILE"
echo "Журнал аудита: $AUDIT_LOG"
echo "Просмотр событий Docker: ausearch -k docker-socket -i | tail -20"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
