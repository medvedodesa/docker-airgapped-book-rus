#!/usr/bin/env bash
# Шаблон конфигурации Vault Agent для Docker Compose с автообновлением секретов из KV v2
# Генерирует HCL-конфигурацию агента и фрагмент docker-compose
# Использование: bash vault-agent-sidecar.sh [service_name] [secret_paths...] [vault_addr]
set -euo pipefail

SERVICE_NAME="${1:-myservice}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
PKI_ROLE="${PKI_ROLE:-services}"
OUTPUT_DIR="${OUTPUT_DIR:-.}"
SECRETS_BASE="${SECRETS_BASE:-secret/prod}"

shift 1 || true
SECRET_PATHS=("${@:-$SECRETS_BASE/$SERVICE_NAME}")

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Генерация конфигурации Vault Agent sidecar ==="
echo "Сервис:   $SERVICE_NAME"
echo "Vault:    $VAULT_ADDR"
echo "Секреты:  ${SECRET_PATHS[*]}"

mkdir -p "$OUTPUT_DIR"

# ── HCL-конфигурация Vault Agent ─────────────────────────────────────────
AGENT_HCL="$OUTPUT_DIR/vault-agent-$SERVICE_NAME.hcl"

cat > "$AGENT_HCL" <<HCL
# Vault Agent sidecar для $SERVICE_NAME
# Автообновление секретов из KV v2 + TLS-сертификатов из PKI
# Генерируется: $(date '+%Y-%m-%d %H:%M')

vault {
  address = "$VAULT_ADDR"

  # Повторные попытки при недоступности Vault
  retry {
    num_retries = 5
  }
}

# Кеш для ускорения запросов
cache {
  use_auth_auth_token = true
}

# AppRole аутентификация
auth "approle" {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path              = "/vault-agent/role-id"
      secret_id_file_path            = "/vault-agent/secret-id"
      remove_secret_id_file_after_reading = true
    }
  }
}

HCL

# Добавляем шаблоны для каждого пути секретов
for secret_path in "${SECRET_PATHS[@]}"; do
  secret_basename=$(basename "$secret_path")
  cat >> "$AGENT_HCL" <<HCL
# Шаблон: $secret_path → конфигурационный файл
template {
  source      = "/vault-agent/templates/$secret_basename.ctmpl"
  destination = "/app/config/$secret_basename.env"
  perms       = "0640"
  # Перезапустить сервис при обновлении секрета
  command     = "kill -HUP \$(cat /var/run/$SERVICE_NAME.pid 2>/dev/null) 2>/dev/null || true"

  # Ждать появления секрета (не падать при старте)
  wait {
    min = "5s"
    max = "10s"
  }
}

HCL

  # Создаём шаблон для этого секрета
  mkdir -p "$OUTPUT_DIR/templates"
  cat > "$OUTPUT_DIR/templates/$secret_basename.ctmpl" <<'CTMPL'
{{- with secret "SECRET_PATH" -}}
{{- range $key, $value := .Data.data -}}
{{ $key }}={{ $value }}
{{ end -}}
{{- end -}}
CTMPL
  sed -i "s|SECRET_PATH|$secret_path|g" "$OUTPUT_DIR/templates/$secret_basename.ctmpl"
done

# PKI-шаблон (опционально)
cat >> "$AGENT_HCL" <<HCL
# TLS-сертификат от Vault PKI
template {
  contents = <<TMPL
{{- with secret "pki_int/issue/$PKI_ROLE" "common_name=$SERVICE_NAME.internal.company.local" "ttl=72h" -}}
{{ .Data.certificate }}
{{- end -}}
TMPL
  destination = "/app/certs/server.crt"
  perms       = "0644"
}

template {
  contents = <<TMPL
{{- with secret "pki_int/issue/$PKI_ROLE" "common_name=$SERVICE_NAME.internal.company.local" "ttl=72h" -}}
{{ .Data.private_key }}
{{- end -}}
TMPL
  destination = "/app/certs/server.key"
  perms       = "0640"
}
HCL

ok "Конфигурация агента: $AGENT_HCL"

# ── Docker Compose фрагмент ───────────────────────────────────────────────
COMPOSE_FILE="$OUTPUT_DIR/docker-compose.vault-sidecar.yml"
cat > "$COMPOSE_FILE" <<YAML
# Docker Compose: Vault Agent sidecar для $SERVICE_NAME
# Использование: docker compose -f docker-compose.yml -f $COMPOSE_FILE up

services:

  # Vault Agent sidecar — получает секреты и сертификаты
  vault-agent:
    image: hashicorp/vault:latest
    command: agent -config=/vault-agent/config.hcl
    restart: on-failure:5
    environment:
      VAULT_ADDR: "$VAULT_ADDR"
    volumes:
      - ./$AGENT_HCL:/vault-agent/config.hcl:ro
      - ./templates:/vault-agent/templates:ro
      - role-id-vol:/vault-agent/role-id:ro
      - secret-id-vol:/vault-agent/secret-id
      - app-config:/app/config
      - app-certs:/app/certs
    healthcheck:
      test: ["CMD", "test", "-f", "/app/config/${SECRET_PATHS[0]##*/}.env"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - internal

  # Основной сервис
  $SERVICE_NAME:
    # image: your-image:tag
    volumes:
      - app-config:/app/config:ro    # секреты от Vault Agent
      - app-certs:/app/certs:ro      # сертификаты от Vault Agent
    depends_on:
      vault-agent:
        condition: service_healthy
    networks:
      - internal

volumes:
  role-id-vol:     # Role ID (заполняется при деплое)
  secret-id-vol:   # Secret ID (удаляется агентом после использования)
  app-config:      # конфигурационные файлы с секретами
  app-certs:       # TLS-сертификаты

networks:
  internal:
    driver: bridge
    internal: true
YAML

ok "Docker Compose файл: $COMPOSE_FILE"

# ── Политика Vault для агента ─────────────────────────────────────────────
POLICY_FILE="$OUTPUT_DIR/vault-policy-$SERVICE_NAME.hcl"
cat > "$POLICY_FILE" <<HCL
# Vault-политика для Vault Agent сервиса $SERVICE_NAME
# Применить: vault policy write $SERVICE_NAME $POLICY_FILE

HCL

for secret_path in "${SECRET_PATHS[@]}"; do
  cat >> "$POLICY_FILE" <<HCL
path "$secret_path" {
  capabilities = ["read"]
}

HCL
done

cat >> "$POLICY_FILE" <<HCL
path "pki_int/issue/$PKI_ROLE" {
  capabilities = ["create", "update"]
}

path "pki_int/ca/pem" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
HCL

ok "Политика Vault: $POLICY_FILE"

# ── Инструкции по деплою ──────────────────────────────────────────────────
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Сгенерированные файлы:"
echo "  $AGENT_HCL"
echo "  $COMPOSE_FILE"
echo "  $POLICY_FILE"
echo "  $OUTPUT_DIR/templates/*.ctmpl"
echo ""
echo "Деплой:"
echo "  1. vault policy write $SERVICE_NAME $POLICY_FILE"
echo "  2. vault write auth/approle/role/$SERVICE_NAME policies=$SERVICE_NAME"
echo "  3. vault read -field=role_id auth/approle/role/$SERVICE_NAME/role-id > role-id"
echo "  4. vault write -f -field=secret_id auth/approle/role/$SERVICE_NAME/secret-id > secret-id"
echo "  5. docker compose -f docker-compose.yml -f $COMPOSE_FILE up -d"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
