#!/usr/bin/env bash
# Интеграция Vault AppRole с GitLab CI: настройка переменных и политики
# Использование: bash setup-vault-approle-ci.sh <gitlab_project_path> <vault_policy>
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.internal.company.local}"
GITLAB_TOKEN="${GITLAB_TOKEN:-}"
PROJECT_PATH="${1:-}"         # group/project
VAULT_POLICY="${2:-app-prod-readonly}"
APP_NAME="${3:-gitlab-ci-$(echo "$1" | tr '/' '-' | tr -d ' ')}"

export VAULT_ADDR

echo "=== Интеграция Vault AppRole с GitLab CI ==="
echo "  Проект:  $PROJECT_PATH"
echo "  Политика: $VAULT_POLICY"
echo "  AppRole:  $APP_NAME"

[ -n "$PROJECT_PATH" ] || { echo "[FAIL] Путь к проекту не задан"; exit 1; }
[ -n "${VAULT_TOKEN:-}" ] || { echo "[FAIL] VAULT_TOKEN не установлен"; exit 1; }

# Создание AppRole в Vault
echo ""
echo "--- AppRole в Vault ---"
vault auth enable approle 2>/dev/null || true

vault write "auth/approle/role/$APP_NAME" \
  secret_id_ttl=720h \
  token_ttl=1h \
  token_max_ttl=4h \
  token_policies="$VAULT_POLICY" \
  bind_secret_id=true \
  secret_id_num_uses=0 \
  2>/dev/null

role_id=$(vault read -field=role_id "auth/approle/role/$APP_NAME/role-id" 2>/dev/null)
secret_id=$(vault write -f -field=secret_id "auth/approle/role/$APP_NAME/secret-id" 2>/dev/null)
echo "  [OK] AppRole $APP_NAME создан"

# Запись переменных в GitLab через API
if [ -n "$GITLAB_TOKEN" ]; then
  echo ""
  echo "--- Запись переменных в GitLab CI ---"
  PROJECT_ID=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    "$GITLAB_URL/api/v4/projects/$(echo "$PROJECT_PATH" | sed 's|/|%2F|g')" \
    2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

  if [ -n "$PROJECT_ID" ]; then
    for var_name in VAULT_ROLE_ID VAULT_SECRET_ID VAULT_ADDR; do
      case "$var_name" in
        VAULT_ROLE_ID)   var_value="$role_id" ;;
        VAULT_SECRET_ID) var_value="$secret_id" ;;
        VAULT_ADDR)      var_value="$VAULT_ADDR" ;;
      esac
      masked="true"
      [ "$var_name" = "VAULT_ADDR" ] && masked="false"
      curl -s -X POST \
        --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        --form "key=$var_name" \
        --form "value=$var_value" \
        --form "masked=$masked" \
        --form "protected=true" \
        "$GITLAB_URL/api/v4/projects/$PROJECT_ID/variables" \
        &>/dev/null && echo "  [OK] $var_name записан" || echo "  [WARN] $var_name — возможно уже существует"
    done
  else
    echo "  [WARN] Не удалось найти проект $PROJECT_PATH через API"
    echo "  Добавьте вручную в Settings > CI/CD > Variables:"
  fi
else
  echo ""
  echo "  Установите следующие переменные в GitLab CI/CD:"
fi

echo "    VAULT_ADDR      = $VAULT_ADDR"
echo "    VAULT_ROLE_ID   = $role_id"
echo "    VAULT_SECRET_ID = <masked>"

echo ""
echo "=== Интеграция настроена ==="
echo ""
echo "Пример использования в .gitlab-ci.yml:"
echo "  script:"
echo "    - export VAULT_TOKEN=\$(vault write -field=token auth/approle/login role_id=\$VAULT_ROLE_ID secret_id=\$VAULT_SECRET_ID)"
echo "    - export DB_PASS=\$(VAULT_TOKEN=\$VAULT_TOKEN vault kv get -field=password secret/prod/database/postgres)"
