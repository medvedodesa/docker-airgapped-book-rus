#!/usr/bin/env bash
# Настройка политик хранения образов в Harbor: релизные версии, feature-ветки, расписание очистки
# Использование: bash setup-harbor-retention.sh [harbor_url] [пользователь] [пароль]
set -euo pipefail

HARBOR_URL="${1:-${HARBOR_URL:-https://harbor.internal.company.local}}"
HARBOR_USER="${2:-admin}"
HARBOR_PASS="${3:-${HARBOR_PASSWORD:-}}"

# Политики хранения по умолчанию
KEEP_RELEASES="${KEEP_RELEASES:-0}"          # 0 = хранить все релизные (v*.*.*)
KEEP_MAIN_BRANCH="${KEEP_MAIN_BRANCH:-30}"   # последних N сборок из main
KEEP_FEATURE="${KEEP_FEATURE:-5}"            # последних N сборок из feature-веток
FEATURE_MAX_AGE="${FEATURE_AGE_DAYS:-14}"    # удалять feature-теги старше N дней

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

if [ -z "$HARBOR_PASS" ]; then
  echo "Укажите пароль: HARBOR_PASSWORD=<pass> bash $0 или третий аргумент"
  exit 1
fi

AUTH=$(echo -n "$HARBOR_USER:$HARBOR_PASS" | base64)
api() {
  curl -sf --max-time 15 -X "${1:-GET}" \
    -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" \
    "$HARBOR_URL/api/v2.0/$2" ${3:+-d "$3"} 2>/dev/null
}

echo "=== Настройка политик хранения Harbor ==="
echo "Реестр:          $HARBOR_URL"
echo "Релизные теги:   хранить $([ "$KEEP_RELEASES" -eq 0 ] && echo 'все' || echo "последние $KEEP_RELEASES")"
echo "main-ветка:      последние $KEEP_MAIN_BRANCH сборок"
echo "Feature-ветки:   последние $KEEP_FEATURE сборок, старше $FEATURE_MAX_AGE дней — удалять"

# --- Получаем проекты ---
echo ""
echo "--- Проекты ---"
projects=$(api GET "projects?page_size=100" | python3 -c "
import json,sys; [print(p['project_id'],p['name']) for p in json.load(sys.stdin)]
" 2>/dev/null || echo "")

[ -z "$projects" ] && { fail "Проекты не найдены или нет прав"; exit 1; }
project_count=$(echo "$projects" | wc -l)
ok "Найдено проектов: $project_count"

# --- Создаём политику для каждого проекта ---
echo ""
echo "--- Создание политик хранения ---"

while IFS=' ' read -r proj_id proj_name; do
  echo "  Проект: $proj_name (id=$proj_id)"

  # Политика хранения в формате Harbor API
  RULES=$(python3 -c "
import json

rules = []

# Правило 1: Хранить все релизные теги (v*.*.*)
if $KEEP_RELEASES == 0:
    rules.append({
        'disabled': False,
        'action': 'retain',
        'params': {'latestPushedK': 0},
        'scope_selectors': {'repository': [{'kind': 'doublestar', 'decoration': 'repoMatches', 'pattern': '**'}]},
        'tag_selectors': [{'kind': 'doublestar', 'decoration': 'matches', 'pattern': 'v*.*.*'}],
        'template': 'latestPushedK'
    })
else:
    rules.append({
        'disabled': False,
        'action': 'retain',
        'params': {'latestPushedK': $KEEP_RELEASES},
        'scope_selectors': {'repository': [{'kind': 'doublestar', 'decoration': 'repoMatches', 'pattern': '**'}]},
        'tag_selectors': [{'kind': 'doublestar', 'decoration': 'matches', 'pattern': 'v*.*.*'}],
        'template': 'latestPushedK'
    })

# Правило 2: Последние N сборок из main/master
rules.append({
    'disabled': False,
    'action': 'retain',
    'params': {'latestPushedK': $KEEP_MAIN_BRANCH},
    'scope_selectors': {'repository': [{'kind': 'doublestar', 'decoration': 'repoMatches', 'pattern': '**'}]},
    'tag_selectors': [{'kind': 'doublestar', 'decoration': 'matches', 'pattern': 'main-*'},
                      {'kind': 'doublestar', 'decoration': 'matches', 'pattern': 'master-*'}],
    'template': 'latestPushedK'
})

# Правило 3: Feature-ветки — последние N и не старше X дней
rules.append({
    'disabled': False,
    'action': 'retain',
    'params': {'latestPushedK': $KEEP_FEATURE, 'nDaysSinceLastPush': $FEATURE_MAX_AGE},
    'scope_selectors': {'repository': [{'kind': 'doublestar', 'decoration': 'repoMatches', 'pattern': '**'}]},
    'tag_selectors': [{'kind': 'doublestar', 'decoration': 'excludes', 'pattern': 'v*.*.*'},
                      {'kind': 'doublestar', 'decoration': 'excludes', 'pattern': 'main-*'},
                      {'kind': 'doublestar', 'decoration': 'excludes', 'pattern': 'master-*'},
                      {'kind': 'doublestar', 'decoration': 'excludes', 'pattern': 'production'}],
    'template': 'nDaysSinceLastPush'
})

policy = {
    'algorithm': 'or',
    'rules': rules,
    'trigger': {
        'kind': 'Schedule',
        'settings': {'cron': '0 0 0 * * 0'}  # воскресенье 00:00
    },
    'scope': {
        'level': 'project',
        'ref': $proj_id
    }
}
print(json.dumps(policy))
")

  # Проверяем существующую политику
  existing=$(api GET "retentions/metadatas?project_id=$proj_id" 2>/dev/null || echo "{}")
  retention_id=$(echo "$existing" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

  if [ -n "$retention_id" ]; then
    # Обновляем существующую
    result=$(api PUT "retentions/$retention_id" "$RULES" 2>/dev/null && echo "ok" || echo "err")
    [ "$result" = "ok" ] && ok "  Политика обновлена: $proj_name" || warn "  Не удалось обновить: $proj_name"
  else
    # Создаём новую
    result=$(api POST "retentions" "$RULES" 2>/dev/null || echo "")
    [ -n "$result" ] && ok "  Политика создана: $proj_name" || warn "  Не удалось создать: $proj_name (возможно уже есть)"
  fi

done <<< "$projects"

# --- Неизменяемые теги для релизных ---
echo ""
echo "--- Неизменяемые теги (релизные v*.*.*) ---"
while IFS=' ' read -r proj_id proj_name; do
  immutable_rule=$(python3 -c "
import json
print(json.dumps({'selector_repository': {'kind': 'doublestar', 'decoration': 'repoMatches', 'pattern': '**'},
                  'selector_tag': {'kind': 'doublestar', 'decoration': 'matches', 'pattern': 'v*.*.*'}}))
")
  result=$(api POST "projects/$proj_id/immutabletagrules" "$immutable_rule" 2>/dev/null || echo "")
  [ -n "$result" ] && ok "  Неизменяемые теги: $proj_name" || warn "  $proj_name: уже настроено или нет прав"
done <<< "$projects"

# --- Итог ---
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Применённые политики:"
echo "  Релизные (v*.*.*):  хранятся $([ "$KEEP_RELEASES" -eq 0 ] && echo 'бессрочно' || echo "последние $KEEP_RELEASES")"
echo "  main/master ветки:  последние $KEEP_MAIN_BRANCH сборок"
echo "  Feature-ветки:      последние $KEEP_FEATURE сборок, старше $FEATURE_MAX_AGE дней — удаляются"
echo "  Расписание очистки: воскресенье 00:00"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
