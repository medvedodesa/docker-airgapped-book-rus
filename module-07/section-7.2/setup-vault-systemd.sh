#!/usr/bin/env bash
# Создание systemd-юнита для Vault и первоначальный запуск
# Использование: bash setup-vault-systemd.sh
set -euo pipefail

VAULT_USER="vault"
VAULT_CONFIG="/etc/vault.d"

echo "=== Настройка Vault как systemd-сервиса ==="

# Проверка установки
command -v vault &>/dev/null || { echo "[FAIL] vault не найден в PATH"; exit 1; }

# Systemd unit
echo ""
echo "--- Создание unit-файла ---"
cat > /etc/systemd/system/vault.service << 'UNIT'
[Unit]
Description=HashiCorp Vault — Secret Management Service
Documentation=https://www.vaultproject.io/docs/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/vault.d/vault.hcl
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=notify
User=vault
Group=vault
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
SecureBits=keep-caps
AmbientCapabilities=CAP_IPC_LOCK
CapabilityBoundingSet=CAP_SYSLOG CAP_IPC_LOCK
LimitNOFILE=65536
LimitMEMLOCK=infinity
ExecStart=/usr/local/bin/vault server -config=/etc/vault.d/vault.hcl
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
StandardOutput=append:/var/log/vault/vault.log
StandardError=append:/var/log/vault/vault.log
SyslogIdentifier=vault

[Install]
WantedBy=multi-user.target
UNIT

echo "  [OK] /etc/systemd/system/vault.service"

# logrotate
cat > /etc/logrotate.d/vault << 'LR'
/var/log/vault/vault.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl kill --kill-who=main --signal=USR1 vault.service || true
    endscript
}
LR
echo "  [OK] /etc/logrotate.d/vault"

# Активация
echo ""
echo "--- Активация сервиса ---"
systemctl daemon-reload
systemctl enable vault
echo "  [OK] vault.service включён в автозапуск"

# Проверка TLS
echo ""
echo "--- Проверка TLS-файлов ---"
for f in "$VAULT_CONFIG/tls/vault.crt" "$VAULT_CONFIG/tls/vault.key"; do
  if [ -f "$f" ]; then
    echo "  [OK] $f"
  else
    echo "  [WARN] $f не найден — создайте TLS-сертификат перед запуском"
  fi
done

echo ""
echo "=== Настройка завершена ==="
echo ""
echo "После размещения TLS-сертификатов в $VAULT_CONFIG/tls/ запустите:"
echo "  systemctl start vault"
echo "  journalctl -u vault -f"
echo ""
echo "Инициализация кластера:"
echo "  bash init-vault-cluster.sh"
