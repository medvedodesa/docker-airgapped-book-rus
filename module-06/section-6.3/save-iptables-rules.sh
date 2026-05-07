#!/usr/bin/env bash
# Сохранение правил iptables и настройка их восстановления через systemd
set -euo pipefail

RULES_FILE="/etc/iptables/rules.v4"

echo "=== Сохранение правил iptables ==="
mkdir -p /etc/iptables
iptables-save > "$RULES_FILE"
echo "[OK] Правила сохранены: $RULES_FILE ($(wc -l < "$RULES_FILE") строк)"

# systemd unit для восстановления
cat > /etc/systemd/system/iptables-restore.service << UNIT
[Unit]
Description=Restore iptables rules
Before=docker.service
After=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore $RULES_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable iptables-restore.service
echo "[OK] Автовосстановление правил настроено"
echo "[WARN] При изменении правил DOCKER-USER повторите эту команду"
