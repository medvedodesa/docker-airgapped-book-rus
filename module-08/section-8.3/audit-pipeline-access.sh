#!/usr/bin/env bash
# Анализ журнала аудита GitLab: изменения переменных, конфигурации раннеров и прав доступа
# Использование: bash audit-pipeline-access.sh [gitlab_url] [token] [дней]
set -euo pipefail

GITLAB_URL="${1:-${GITLAB_URL:-https://gitlab.internal.company.local}}"
GITLAB_TOKEN="${2:-${GITLAB_PRIVATE_TOKEN:-}}"
DAYS="${3:-30}"
OUTPUT="${GITLAB_AUDIT_OUTPUT:-gitlab-pipeline-audit-$(date +%Y%m%d).txt}"

if [ -z "$GITLAB_TOKEN" ]; then
  echo "Укажите GitLab токен: GITLAB_PRIVATE_TOKEN=<token> bash $0"
  echo "Или: bash $0 [gitlab_url] <token> [дней]"
  exit 1
fi

api() { curl -sf --max-time 15 -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$GITLAB_URL/api/v4/$1" 2>/dev/null; }

echo "=== Аудит GitLab CI/CD ==="
echo "GitLab: $GITLAB_URL"
echo "Период: последние $DAYS дней"
echo "Дата:   $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Аудит доступа к GitLab CI/CD"
  echo "# GitLab: $GITLAB_URL  |  Период: $DAYS дней  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  CUTOFF=$(date -d "$DAYS days ago" --iso-8601=seconds 2>/dev/null || \
           date -v-"${DAYS}d" +%Y-%m-%dT%H:%M:%S 2>/dev/null || echo "")

  # ── 1. Системный аудит-журнал ─────────────────────────────────────────
  echo "## Системный аудит-журнал"
  audit_events=$(api "admin/audit_events?per_page=100&entity_type=Key" 2>/dev/null || echo "[]")

  # Пытаемся получить аудит изменений CI/CD переменных
  ci_audit=$(api "admin/audit_events?per_page=200" 2>/dev/null | python3 -c "
import json,sys,re
from datetime import datetime, timezone

events = json.load(sys.stdin)
days = int('$DAYS')
now = datetime.now(timezone.utc)

ci_events = []
for e in events:
    dt_str = e.get('created_at','')
    try:
        dt = datetime.fromisoformat(dt_str.replace('Z','+00:00'))
        age = (now - dt).days
        if age > days:
            continue
    except Exception:
        continue

    action = e.get('action_name','')
    target = e.get('target_type','')
    details = str(e.get('details',''))

    # Фильтр CI/CD событий
    if any(kw in action.lower() or kw in target.lower() or kw in details.lower()
           for kw in ['variable', 'runner', 'pipeline', 'ci', 'token', 'access', 'secret']):
        author = e.get('author_name', e.get('author_id','?'))
        ip = e.get('ip_address','?')
        ci_events.append(f'  {dt_str[:19]}  {author:<25} {action:<30} {target} / {details[:50]}')

if ci_events:
    print(f'Событий CI/CD за период: {len(ci_events)}')
    print()
    for ev in ci_events[:50]:
        print(ev)
    if len(ci_events) > 50:
        print(f'  ... и ещё {len(ci_events)-50}')
else:
    print('  CI/CD событий за период не найдено')
    print('  (Убедитесь что токен имеет права admin или read_audit_log)')
" 2>/dev/null || echo "  Аудит-журнал недоступен — нужны права администратора")
  echo "$ci_audit"
  echo ""

  # ── 2. Переменные CI/CD по проектам ──────────────────────────────────
  echo "## Переменные CI/CD"
  projects=$(api "projects?per_page=50&membership=true" 2>/dev/null | \
    python3 -c "import json,sys; [print(p['id'],p['name_with_namespace']) for p in json.load(sys.stdin)]" 2>/dev/null || echo "")

  if [ -n "$projects" ]; then
    total_vars=0
    sensitive_vars=0
    while IFS=' ' read -r pid pname; do
      vars=$(api "projects/$pid/variables?per_page=100" 2>/dev/null || echo "[]")
      var_count=$(echo "$vars" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
      if [ "$var_count" -gt 0 ]; then
        total_vars=$((total_vars + var_count))
        masked_count=$(echo "$vars" | python3 -c "
import json,sys
vs = json.load(sys.stdin)
masked = sum(1 for v in vs if v.get('masked'))
unmasked_sensitive = [v.get('key','') for v in vs if not v.get('masked') and
  any(kw in v.get('key','').upper() for kw in ['PASSWORD','SECRET','TOKEN','KEY','PASS'])]
print(masked, '|'.join(unmasked_sensitive[:3]))
" 2>/dev/null || echo "0 ")
        masked=$(echo "$masked_count" | cut -d' ' -f1)
        unmasked=$(echo "$masked_count" | cut -d' ' -f2-)

        echo "  Проект: $pname ($var_count переменных, $masked маскировано)"
        if [ -n "$unmasked" ]; then
          echo "  [WARN] Не замаскированы чувствительные: $unmasked"
          sensitive_vars=$((sensitive_vars + 1))
        fi
      fi
    done <<< "$projects"
    echo ""
    echo "  Итого переменных: $total_vars, проектов с незамаскированными чувствительными: $sensitive_vars"
  else
    echo "  Проекты не найдены или нет прав"
  fi
  echo ""

  # ── 3. Активные Runner'ы ──────────────────────────────────────────────
  echo "## Зарегистрированные Runner'ы"
  runners=$(api "runners/all?per_page=100" 2>/dev/null || echo "[]")
  echo "$runners" | python3 -c "
import json,sys
from datetime import datetime, timezone

runners = json.load(sys.stdin)
now = datetime.now(timezone.utc)
print(f'  Всего Runner-ов: {len(runners)}')
print()
print(f'  {\"ID\":<6} {\"Описание\":<30} {\"Статус\":<12} {\"Активен\":<8} {\"IP\":<20} {\"Версия\"}')
print(f'  {\"-\"*6} {\"-\"*30} {\"-\"*12} {\"-\"*8} {\"-\"*20} {\"-\"*10}')

for r in runners:
    rid = r.get('id','?')
    desc = r.get('description','')[:28]
    status = r.get('status','?')
    active = r.get('active','?')
    ip = r.get('ip_address','?')
    ver = r.get('version','?')
    # Предупреждение об устаревших
    marker = '[WARN]' if status == 'offline' else ''
    print(f'  {rid:<6} {desc:<30} {status:<12} {str(active):<8} {ip:<20} {ver} {marker}')
" 2>/dev/null || echo "  Нет прав на просмотр Runner-ов"
  echo ""

  # ── 4. Изменения прав доступа к проектам ─────────────────────────────
  echo "## Изменения прав доступа (последние $DAYS дней)"
  recent_members=$(api "admin/audit_events?action=member_created,member_updated,member_destroyed&per_page=50" \
    2>/dev/null | python3 -c "
import json,sys
from datetime import datetime, timezone

events = json.load(sys.stdin)
days = int('$DAYS')
now = datetime.now(timezone.utc)

for e in events:
    dt_str = e.get('created_at','')
    try:
        dt = datetime.fromisoformat(dt_str.replace('Z','+00:00'))
        if (now - dt).days > days:
            continue
    except Exception:
        continue
    author = e.get('author_name','?')
    action = e.get('action_name','?')
    target = e.get('target_details','?')
    print(f'  {dt_str[:19]}  {author:<20} {action:<25} {target}')
" 2>/dev/null || echo "  Нет прав на просмотр или событий не было")
  echo ""

  # ── 5. Рекомендации ───────────────────────────────────────────────────
  echo "## Рекомендации"
  echo "  1. Маскируйте все переменные с PASSWORD, TOKEN, SECRET, KEY"
  echo "  2. Переносите чувствительные секреты из GitLab CI Variables в Vault (раздел 8.4)"
  echo "  3. Offline Runner'ы дольше 30 дней — удалите или проверьте"
  echo "  4. Права Maintainer/Owner — проверьте актуальность каждого"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
