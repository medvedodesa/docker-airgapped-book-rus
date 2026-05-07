#!/usr/bin/env bash
# Проверка инфраструктуры на наличие секретов в переменных окружения, docker-compose и образах
set -euo pipefail

COMPOSE_DIRS="${COMPOSE_DIRS:-. /opt /srv /home}"
OUTPUT="${SECRETS_AUDIT_OUTPUT:-secrets-audit-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

SECRET_PATTERNS="password|passwd|secret|token|api.key|access.key|private.key|credentials|auth.token"

echo "=== Аудит открытых секретов ==="
echo "Хост: $(hostname)  |  Дата: $(date '+%Y-%m-%d %H:%M')"

# ── 1. Переменные окружения запущенных контейнеров ────────────────────────
echo ""
echo "── 1. Переменные окружения контейнеров ──────────────────────────────────"
containers=$(docker ps --format '{{.Names}}' 2>/dev/null || echo "")
if [ -z "$containers" ]; then
  ok "Запущенных контейнеров нет"
else
  found_any=false
  while IFS= read -r cname; do
    hits=$(docker inspect "$cname" \
      --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | \
      grep -iE "$SECRET_PATTERNS" | grep -v "^[^=]*=\s*$" || true)
    if [ -n "$hits" ]; then
      fail "Контейнер $cname: подозрительные ENV-переменные:"
      echo "$hits" | sed 's/=.*/=***REDACTED***/' | sed 's/^/    /'
      found_any=true
    fi
  done <<< "$containers"
  $found_any || ok "Подозрительных ENV-переменных в контейнерах не найдено"
fi

# ── 2. Docker Compose файлы ───────────────────────────────────────────────
echo ""
echo "── 2. Docker Compose файлы ──────────────────────────────────────────────"
compose_hits=0
for dir in $COMPOSE_DIRS; do
  [ -d "$dir" ] || continue
  while IFS= read -r compose_file; do
    hits=$(grep -inE "^\s*(password|secret|token|api_key|access_key|private_key):\s*.+" \
      "$compose_file" 2>/dev/null | grep -v "^\s*#\|:\s*$\|:\s*\${" || true)
    if [ -n "$hits" ]; then
      fail "Найдены секреты в открытом виде: $compose_file"
      echo "$hits" | sed 's/:.*/:***REDACTED***/' | head -5 | sed 's/^/    /'
      ((compose_hits++))
    fi
  done < <(find "$dir" -maxdepth 4 -name "docker-compose*.yml" -o -name "docker-compose*.yaml" 2>/dev/null)
done
[ "$compose_hits" -eq 0 ] && ok "Секретов в открытом виде в Compose-файлах не найдено"

# ── 3. Слои образов (docker history) ─────────────────────────────────────
echo ""
echo "── 3. Образы: история слоёв ─────────────────────────────────────────────"
image_hits=0
while IFS= read -r img; do
  hits=$(docker history --no-trunc "$img" --format '{{.CreatedBy}}' 2>/dev/null | \
    grep -iE "$SECRET_PATTERNS" | grep -v "^\s*$" || true)
  if [ -n "$hits" ]; then
    fail "Образ $img: подозрительные команды в истории слоёв"
    echo "$hits" | head -3 | sed 's/^/    /'
    ((image_hits++))
  fi
done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>')
[ "$image_hits" -eq 0 ] && ok "Секретов в истории слоёв образов не найдено"

# ── 4. .env файлы в рабочих директориях ──────────────────────────────────
echo ""
echo "── 4. .env файлы ────────────────────────────────────────────────────────"
env_hits=0
for dir in $COMPOSE_DIRS; do
  [ -d "$dir" ] || continue
  while IFS= read -r env_file; do
    hits=$(grep -inE "^($SECRET_PATTERNS)\s*=\s*.+" "$env_file" 2>/dev/null | \
      grep -v "^\s*#\|=\s*$\|=\s*\${" || true)
    if [ -n "$hits" ]; then
      warn ".env файл с секретами: $env_file"
      echo "$hits" | sed 's/=.*/=***REDACTED***/' | head -3 | sed 's/^/    /'
      ((env_hits++))
    fi
  done < <(find "$dir" -maxdepth 4 -name ".env" -o -name "*.env" 2>/dev/null | head -50)
done
[ "$env_hits" -eq 0 ] && ok ".env файлов с секретами не найдено" || \
  warn "Рекомендация: перенесите секреты из .env в Vault KV v2"

# ── 5. Git-репозитории: незакомиченные секреты ────────────────────────────
echo ""
echo "── 5. Git-репозитории ───────────────────────────────────────────────────"
git_hits=0
for dir in $COMPOSE_DIRS; do
  [ -d "$dir" ] || continue
  while IFS= read -r git_dir; do
    repo=$(dirname "$git_dir")
    tracked_secrets=$(git -C "$repo" grep -inE "$SECRET_PATTERNS" -- \
      '*.yml' '*.yaml' '*.env' '*.json' '*.conf' 2>/dev/null | \
      grep -vE "vault\.|example\.|sample\.|\.gpg\|encrypted" | head -5 || true)
    if [ -n "$tracked_secrets" ]; then
      fail "Git-репозиторий $repo: возможные секреты в отслеживаемых файлах"
      echo "$tracked_secrets" | sed 's/^/    /'
      ((git_hits++))
    fi
  done < <(find "$dir" -maxdepth 4 -name ".git" -type d 2>/dev/null | head -10)
done
[ "$git_hits" -eq 0 ] && ok "Секретов в Git-репозиториях не обнаружено"

# ── Итог ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "Обнаружены секреты в открытом виде. Немедленные действия:"
  echo "  1. Перенесите секреты в Vault KV v2 (раздел 7.4)"
  echo "  2. Удалите секреты из ENV и Compose-файлов"
  echo "  3. Пересоберите образы, содержащие секреты в слоях"
fi
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
