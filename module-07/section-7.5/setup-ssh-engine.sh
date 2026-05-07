#!/usr/bin/env bash
# Настройка Vault SSH Secrets Engine для выдачи временных OTP
# Использование: bash setup-ssh-engine.sh [cidr_list]
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
ALLOWED_CIDR="${1:-10.0.0.0/8,172.16.0.0/12}"

export VAULT_ADDR

echo "=== Настройка Vault SSH Engine ==="
echo "  Разрешённые сети: $ALLOWED_CIDR"

[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

# Включение SSH engine
echo ""
echo "--- Включение SSH Secrets Engine ---"
vault secrets enable -path=ssh ssh 2>/dev/null || echo "  ssh уже включён"

# Роль OTP для пользователей
echo ""
echo "--- Создание ролей ---"
vault write ssh/roles/ops-otp \
  key_type=otp \
  default_user=ops \
  allowed_users="ops,ansible" \
  cidr_list="$ALLOWED_CIDR" \
  2>/dev/null
echo "  [OK] Роль ops-otp (type=otp, user=ops)"

vault write ssh/roles/admin-otp \
  key_type=otp \
  default_user=admin \
  allowed_users="admin" \
  cidr_list="$ALLOWED_CIDR" \
  2>/dev/null
echo "  [OK] Роль admin-otp (type=otp, user=admin)"

# Политики
echo ""
echo "--- Политики ---"
vault policy write ssh-ops - << 'POLICY' 2>/dev/null
path "ssh/creds/ops-otp" {
  capabilities = ["create", "update"]
}
POLICY
echo "  [OK] Политика ssh-ops"

vault policy write ssh-admin - << 'POLICY' 2>/dev/null
path "ssh/creds/ops-otp" {
  capabilities = ["create", "update"]
}
path "ssh/creds/admin-otp" {
  capabilities = ["create", "update"]
}
POLICY
echo "  [OK] Политика ssh-admin"

# Инструкция по настройке хоста (vault-ssh-helper)
echo ""
echo "=== SSH Engine настроен ==="
echo ""
echo "На каждом целевом хосте установите vault-ssh-helper:"
echo "  /etc/vault-ssh-helper.d/config.hcl:"
echo "    vault_addr = \"$VAULT_ADDR\""
echo "    ssh_mount_point = \"ssh\""
echo "    tls_skip_verify = false"
echo "    allowed_roles = \"ops-otp,admin-otp\""
echo ""
echo "Настройте /etc/pam.d/sshd:"
echo "  auth requisite pam_exec.so quiet expose_authtok log=/var/log/vault-ssh.log /usr/local/bin/vault-ssh-helper -dev -config=/etc/vault-ssh-helper.d/config.hcl"
echo "  auth optional pam_unix.so not_set_pass use_first_pass nodelay"
echo ""
echo "Получение OTP для подключения:"
echo "  vault write ssh/creds/ops-otp ip=<target_ip>"
