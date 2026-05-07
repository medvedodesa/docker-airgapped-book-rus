#!/usr/bin/env bash
# Немедленный отзыв доступа пользователя из всех проектов Harbor и завершение сессий
# Использование: bash revoke-user-access.sh [harbor_url] [admin_user] [admin_pass] [целевой_пользователь]
set -euo pipefail

HARBOR_URL="${1:-https://harbor.internal.company.local}"
ADMIN_USER="${2:-admin}"
ADMIN_PASS="${3:-${HARBOR_PASSWORD:-}}"
TARGET_USER="${4:-${REVOKE_USERNAME:-}}"

if [ -z "$TARGET_USER" ]; then
  echo "Укажите имя пользователя для отзыва доступа:"
  echo "  bash $0 [harbor_url] [admin_user] [admin_pass] <имя_пользователя>"
  echo "  или переменная REVOKE_USERNAME"
  exit 1
fi

AUTH=$(echo -n "$ADMIN_USER:$ADMIN_PASS" | base64)
api() {
  local method="$1" path="$2" data="${3:-}"
  if [ -n "$data" ]; then
    curl -sf --max-time 15 -X "$method" \
      -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
      "$HARBOR_URL/api/v2.0/$path" -d "$data"
  else
    curl -sf --max-time 15 -X "$method" \
      -H "Authorization: Basic $AUTH" \
      "$HARBOR_URL/api/v2.0/$path"
  fi
}

REVOKED=0; ERRORS=0

echo "=== Отзыв доступа пользователя: $TARGET_USER ==="
echo "Реестр:    $HARBOR_URL"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"
echo ""
echo "ВНИМАНИЕ: Операция необратима в автоматическом режиме. Продолжить? [y/N]"
read -r confirmation
[ "$confirmation" = "y" ] || [ "$confirmation" = "Y" ] || { echo "Отменено."; exit 0; }

# --- Получение ID пользователя ---
echo ""
echo "--- Поиск пользователя ---"
user_info=$(api GET "users?username=$TARGET_USER&page_size=10" 2>/dev/null | python3 -c "
import json,sys
users = json.load(sys.stdin)
for u in users:
    if u.get('username','').lower() == '$TARGET_USER'.lower():
        print(u.get('user_id',''), u.get('username',''), u.get('email',''), u.get('sysadmin_flag',False))
" 2>/dev/null || echo "")

if [ -z "$user_info" ]; then
  echo "[WARN] Пользователь $TARGET_USER не найден в Harbor (возможно LDAP-пользователь без прямой записи)"
else
  user_id=$(echo "$user_info" | awk '{print $1}')
  user_email=$(echo "$user_info" | awk '{print $3}')
  is_admin=$(echo "$user_info" | awk '{print $4}')
  echo "[OK] Найден: $TARGET_USER (id=$user_id, email=$user_email, sysadmin=$is_admin)"

  # Снятие прав системного администратора
  if [ "$is_admin" = "True" ] || [ "$is_admin" = "true" ]; then
    if api PUT "users/$user_id/sysadmin" '{"sysadmin_flag": false}' >/dev/null 2>&1; then
      echo "[OK] Права системного администратора отозваны"
    else
      echo "[FAIL] Не удалось отозвать права системного администратора"
      ((ERRORS++))
    fi
  fi
fi

# --- Удаление из всех проектов ---
echo ""
echo "--- Удаление из проектов ---"
projects=$(api GET "projects?page_size=100" 2>/dev/null || echo "[]")
echo "$projects" | python3 -c "import json,sys; [print(p['project_id'],p['name']) for p in json.load(sys.stdin)]" 2>/dev/null | \
while read -r proj_id proj_name; do
  members=$(api GET "projects/$proj_id/members?page_size=500" 2>/dev/null || echo "[]")
  member_id=$(echo "$members" | python3 -c "
import json,sys
for m in json.load(sys.stdin):
    if m.get('entity_name','').lower() == '$TARGET_USER'.lower() and m.get('entity_type') == 'u':
        print(m.get('id',''))
" 2>/dev/null || echo "")

  if [ -n "$member_id" ]; then
    if api DELETE "projects/$proj_id/members/$member_id" >/dev/null 2>&1; then
      echo "[OK] Удалён из проекта: $proj_name"
      ((REVOKED++))
    else
      echo "[FAIL] Не удалось удалить из проекта: $proj_name"
      ((ERRORS++))
    fi
  fi
done

# --- Отключение учётной записи (если прямой пользователь) ---
echo ""
echo "--- Деактивация учётной записи ---"
if [ -n "${user_id:-}" ]; then
  if api PUT "users/$user_id" '{"comment": "Заблокирован: отзыв доступа"}' >/dev/null 2>&1; then
    echo "[OK] Учётная запись деактивирована в Harbor"
  else
    echo "[WARN] Не удалось деактивировать учётную запись — для LDAP-пользователей заблокируйте в AD"
  fi
fi

# --- Сохранение протокола ---
AUDIT_FILE="revoke-access-$TARGET_USER-$(date +%Y%m%d%H%M%S).txt"
{
  echo "# Протокол отзыва доступа"
  echo "# Пользователь: $TARGET_USER"
  echo "# Дата: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Исполнитель: $ADMIN_USER"
  echo "# Проектов удалено: $REVOKED"
  echo "# Ошибок: $ERRORS"
} > "$AUDIT_FILE"

echo ""
echo "=== Итог ==="
echo "Проектов удалено: $REVOKED"
echo "Ошибок:           $ERRORS"
echo "Протокол:         $AUDIT_FILE"
echo ""
echo "Не забудьте: заблокируйте пользователя $TARGET_USER в Active Directory / LDAP"
[ "$ERRORS" -gt 0 ] && exit 1 || exit 0
