#!/usr/bin/env bash
# Установка HashiCorp Vault из локального пакета в изолированной среде
# Использование: bash install-vault-offline.sh [путь_к_пакету]
set -euo pipefail

VAULT_PKG="${1:-}"
VAULT_VERSION="${VAULT_VERSION:-1.15.4}"
VAULT_USER="vault"
VAULT_GROUP="vault"
VAULT_HOME="/opt/vault"
VAULT_CONFIG="/etc/vault.d"
VAULT_DATA="/var/lib/vault"

echo "=== Установка HashiCorp Vault (офлайн) ==="

# Поиск пакета
if [ -z "$VAULT_PKG" ]; then
  VAULT_PKG=$(find /tmp /opt/packages -name "vault_${VAULT_VERSION}*.zip" 2>/dev/null | head -1 || true)
  [ -z "$VAULT_PKG" ] && VAULT_PKG=$(find /tmp /opt/packages -name "vault*.zip" 2>/dev/null | head -1 || true)
fi

[ -n "$VAULT_PKG" ] && [ -f "$VAULT_PKG" ] || {
  echo "[FAIL] Пакет Vault не найден. Укажите путь явно или поместите zip в /tmp"
  exit 1
}

echo "  Пакет: $VAULT_PKG"

# Проверка контрольной суммы (если есть файл .sha256)
sha_file="${VAULT_PKG%.zip}.sha256"
if [ -f "$sha_file" ]; then
  if sha256sum -c "$sha_file" &>/dev/null; then
    echo "  [OK] Контрольная сумма верна"
  else
    echo "  [FAIL] Контрольная сумма не совпадает — пакет повреждён"
    exit 1
  fi
else
  echo "  [WARN] Файл контрольной суммы не найден, пропускаем проверку"
fi

# Распаковка бинарного файла
echo ""
echo "--- Установка бинарного файла ---"
TMP_DIR=$(mktemp -d)
unzip -q "$VAULT_PKG" -d "$TMP_DIR"
install -o root -g root -m 0755 "$TMP_DIR/vault" /usr/local/bin/vault
rm -rf "$TMP_DIR"
echo "  [OK] /usr/local/bin/vault"

vault version

# Создание пользователя
echo ""
echo "--- Создание системного пользователя ---"
if ! id "$VAULT_USER" &>/dev/null; then
  useradd --system --home "$VAULT_HOME" --shell /bin/false "$VAULT_USER"
  echo "  [OK] Пользователь $VAULT_USER создан"
else
  echo "  [OK] Пользователь $VAULT_USER уже существует"
fi

# Директории
echo ""
echo "--- Директории ---"
for dir in "$VAULT_HOME" "$VAULT_CONFIG" "$VAULT_DATA"; do
  mkdir -p "$dir"
  chown "$VAULT_USER:$VAULT_GROUP" "$dir"
  chmod 750 "$dir"
  echo "  [OK] $dir"
done

# Базовая конфигурация
echo ""
echo "--- Базовая конфигурация ---"
cat > "$VAULT_CONFIG/vault.hcl" << 'VAULTCONF'
ui = true
disable_mlock = false

storage "file" {
  path = "/var/lib/vault/data"
}

listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault.d/tls/vault.crt"
  tls_key_file  = "/etc/vault.d/tls/vault.key"
}

api_addr = "https://vault.internal.company.local:8200"
cluster_addr = "https://vault.internal.company.local:8201"

log_level = "INFO"
log_file  = "/var/log/vault/vault.log"
VAULTCONF

chown "$VAULT_USER:$VAULT_GROUP" "$VAULT_CONFIG/vault.hcl"
chmod 640 "$VAULT_CONFIG/vault.hcl"
mkdir -p "$VAULT_CONFIG/tls" /var/log/vault
chown "$VAULT_USER:$VAULT_GROUP" "$VAULT_CONFIG/tls" /var/log/vault
echo "  [OK] $VAULT_CONFIG/vault.hcl"

# Возможности mlock
echo ""
echo "--- Настройка mlock ---"
if setcap cap_ipc_lock=+ep /usr/local/bin/vault 2>/dev/null; then
  echo "  [OK] cap_ipc_lock установлен"
else
  echo "  [WARN] Не удалось установить cap_ipc_lock, используйте disable_mlock=true в конфиге"
fi

echo ""
echo "=== Установка завершена ==="
echo ""
echo "Следующий шаг — настройка TLS и запуск через systemd:"
echo "  bash setup-vault-systemd.sh"
