#!/usr/bin/env bash
# Проверка цифровых подписей образов Docker Content Trust.
# Выводит список образов с информацией о подписях.
#
# Использование: bash verify-signatures.sh [реестр/проект]
# Пример: bash verify-signatures.sh harbor.company.local/production

set -euo pipefail

REPO_PREFIX="${1:-}"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; RESET='\033[0m'

SIGNED=0; UNSIGNED=0; ERRORS=0

verify_image() {
    local image="$1"
    local result

    result=$(docker trust inspect "$image" 2>&1) || {
        echo -e "  ${RED}[ERR]${RESET}  $image — ошибка получения данных о подписи"
        ((ERRORS++))
        return
    }

    SIGNERS=$(echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
signers = []
for item in data:
    for tag in item.get('SignedTags', []):
        signers.extend([s['Name'] for s in tag.get('Signers', [])])
print(', '.join(set(signers)) if signers else 'НЕТ')
" 2>/dev/null || echo "НЕТ")

    if [ "$SIGNERS" = "НЕТ" ]; then
        echo -e "  ${YELLOW}[WARN]${RESET} $image — подпись отсутствует"
        ((UNSIGNED++))
    else
        echo -e "  ${GREEN}[OK]${RESET}   $image — подписан (${SIGNERS})"
        ((SIGNED++))
    fi
}

echo "=== Проверка подписей Docker Content Trust ==="
echo "Дата: $(date '+%Y-%m-%d %H:%M:%S')"
echo

if [ -n "$REPO_PREFIX" ]; then
    IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^${REPO_PREFIX}" | grep -v "<none>")
else
    IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>")
fi

TOTAL=$(echo "$IMAGES" | wc -l)
echo "Найдено образов: $TOTAL"
echo

for img in $IMAGES; do
    verify_image "$img"
done

echo
echo "=== Итог ==="
echo -e "Подписаны:       ${GREEN}$SIGNED${RESET}"
echo -e "Без подписи:     ${YELLOW}$UNSIGNED${RESET}"
echo -e "Ошибки:          ${RED}$ERRORS${RESET}"

[ "$UNSIGNED" -gt 0 ] && {
    echo
    echo "Для подписания образа:"
    echo "  export DOCKER_CONTENT_TRUST=1"
    echo "  docker trust sign <образ>:<тег>"
}
