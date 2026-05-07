#!/usr/bin/env bash
# Настройка Vault Agent как sidecar для автоматического обновления TLS-сертификатов контейнера
# Использование: bash setup-vault-agent-tls.sh [service_name] [vault_addr] [role_id]
set -euo pipefail

SERVICE_NAME="${1:-myservice}"
VAULT_ADDR="${2:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_ROLE_ID="${3:-${VAULT_ROLE_ID:-}}"
PKI_MOUNT="${PKI_MOUNT:-pki_int}"
PKI_ROLE="${PKI_ROLE:-services}"
CERT_TTL="${CERT_TTL:-72h}"
RENEW_BEFORE="${RENEW_BEFORE:-12h}"
CERTS_DIR="${CERTS_DIR:-/etc/ssl/services/$SERVICE_NAME}"
CONFIG_DIR="${CONFIG_DIR:-/etc/vault-agent}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Настройка Vault Agent (sidecar TLS) ==="
echo "Сервис:    $SERVICE_NAME"
echo "Vault:     $VAULT_ADDR"
echo "PKI:       $PKI_MOUNT / роль $PKI_ROLE"
echo "TTL:       $CERT_TTL (обновление за $RENEW_BEFORE)"

mkdir -p "$OUTPUT_DIR"

# ── Конфигурация Vault Agent ──────────────────────────────────────────────
AGENT_CONFIG="$OUTPUT_DIR/vault-agent-$SERVICE_NAME.hcl"
cat > "$AGENT_CONFIG" <<HCL
# Vault Agent — sidecar для автоматического обновления TLS-сертификатов
# Сервис: $SERVICE_NAME
# Генерируется: $(date '+%Y-%m-%d %H:%M')

vault {
  address = "$VAULT_ADDR"
}

# Файл для хранения токена
cache {}

# Аутентификация через AppRole
auth "$PKI_ROLE" {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path   = "/vault-agent/role-id"
      secret_id_file_path = "/vault-agent/secret-id"
      remove_secret_id_file_after_reading = true
    }
  }
}

# Шаблон сертификата сервиса
template {
  contents = <<TMPL
{{- with secret "$PKI_MOUNT/issue/$PKI_ROLE" "common_name=$SERVICE_NAME.internal.company.local" "ttl=$CERT_TTL" "alt_names=localhost" -}}
{{ .Data.certificate }}
{{- end -}}
TMPL
  destination   = "$CERTS_DIR/server.crt"
  perms         = "0644"
  command       = "kill -HUP \$(cat /var/run/$SERVICE_NAME.pid 2>/dev/null) 2>/dev/null || true"
}

template {
  contents = <<TMPL
{{- with secret "$PKI_MOUNT/issue/$PKI_ROLE" "common_name=$SERVICE_NAME.internal.company.local" "ttl=$CERT_TTL" -}}
{{ .Data.private_key }}
{{- end -}}
TMPL
  destination   = "$CERTS_DIR/server.key"
  perms         = "0640"
}

template {
  contents = <<TMPL
{{- with secret "$PKI_MOUNT/issue/$PKI_ROLE" "common_name=$SERVICE_NAME.internal.company.local" "ttl=$CERT_TTL" -}}
{{ .Data.issuing_ca }}
{{ .Data.certificate }}
{{- end -}}
TMPL
  destination   = "$CERTS_DIR/fullchain.crt"
  perms         = "0644"
}

template {
  contents = <<TMPL
{{- with secret "$PKI_MOUNT/ca/pem" -}}
{{ .Data.certificate }}
{{- end -}}
TMPL
  destination   = "$CERTS_DIR/ca.crt"
  perms         = "0644"
}
HCL

ok "Конфигурация агента: $AGENT_CONFIG"

# ── Docker Compose фрагмент ───────────────────────────────────────────────
COMPOSE_SNIPPET="$OUTPUT_DIR/docker-compose-vault-agent-$SERVICE_NAME.yml"
cat > "$COMPOSE_SNIPPET" <<YAML
# Фрагмент Docker Compose: Vault Agent sidecar для $SERVICE_NAME
# Включите в ваш docker-compose.yml через merge или скопируйте секции вручную

services:
  vault-agent-$SERVICE_NAME:
    image: hashicorp/vault:latest
    command: ["agent", "-config=/vault-agent/config.hcl"]
    restart: on-failure
    environment:
      VAULT_ADDR: "$VAULT_ADDR"
    volumes:
      - ./$AGENT_CONFIG:/vault-agent/config.hcl:ro
      - vault-agent-role:/vault-agent/role-id:ro
      - vault-agent-secret:/vault-agent
      - ${SERVICE_NAME}-certs:$CERTS_DIR
    depends_on:
      - $SERVICE_NAME
    networks:
      - backend

  $SERVICE_NAME:
    # ... ваша конфигурация сервиса ...
    volumes:
      - ${SERVICE_NAME}-certs:$CERTS_DIR:ro   # монтируем сертификаты от агента
    depends_on:
      vault-agent-$SERVICE_NAME:
        condition: service_healthy

volumes:
  ${SERVICE_NAME}-certs:      # общий том для сертификатов
  vault-agent-role:           # Role ID (только чтение)
  vault-agent-secret:         # Secret ID (удаляется после использования)
YAML

ok "Docker Compose фрагмент: $COMPOSE_SNIPPET"

# ── systemd unit для хоста (без Docker) ──────────────────────────────────
SYSTEMD_UNIT="$OUTPUT_DIR/vault-agent-$SERVICE_NAME.service"
cat > "$SYSTEMD_UNIT" <<UNIT
[Unit]
Description=Vault Agent TLS для $SERVICE_NAME
After=network.target vault.service
Requires=network.target

[Service]
Type=simple
User=vault
Group=vault
ExecStartPre=/bin/mkdir -p $CERTS_DIR
ExecStart=/usr/local/bin/vault agent -config=$CONFIG_DIR/vault-agent-$SERVICE_NAME.hcl
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vault-agent-$SERVICE_NAME

[Install]
WantedBy=multi-user.target
UNIT

ok "systemd юнит: $SYSTEMD_UNIT"

# ── Проверка PKI-роли ─────────────────────────────────────────────────────
echo ""
echo "── Проверка PKI-роли ────────────────────────────────────────────────────"
if [ -n "$VAULT_TOKEN" ] 2>/dev/null; then
  role_info=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
    "$VAULT_ADDR/v1/$PKI_MOUNT/roles/$PKI_ROLE" 2>/dev/null || echo "{}")
  if echo "$role_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}))" 2>/dev/null | grep -q "max_ttl"; then
    max_ttl=$(echo "$role_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('max_ttl','?'))" 2>/dev/null)
    ok "PKI-роль $PKI_ROLE существует, max_ttl=$max_ttl"
  else
    warn "PKI-роль $PKI_ROLE не найдена — создайте через setup-pki-hierarchy.sh"
  fi
else
  warn "VAULT_TOKEN не задан — пропуск проверки PKI-роли"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Следующие шаги:"
echo "1. Скопируйте $AGENT_CONFIG на целевой хост в $CONFIG_DIR/"
echo "2. Создайте файл Role ID: echo '<role_id>' > /vault-agent/role-id"
echo "3. Запустите агент: systemctl enable --now vault-agent-$SERVICE_NAME"
echo "4. Или добавьте сервис vault-agent-$SERVICE_NAME в Docker Compose"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
