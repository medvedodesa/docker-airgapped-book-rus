#!/usr/bin/env bash
# Анализ журнала аудита Vault: кто и когда обращался к конкретному секрету за заданный период
# Использование: bash audit-secret-access.sh [secret_path] [дней] [audit_log]
set -euo pipefail

SECRET_PATH="${1:-secret/prod}"
DAYS="${2:-30}"
AUDIT_LOG="${3:-${VAULT_AUDIT_LOG:-/var/log/vault/audit.log}}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-}"
OUTPUT="${VAULT_AUDIT_OUTPUT:-vault-audit-$(date +%Y%m%d).txt}"

echo "=== Анализ аудита Vault ==="
echo "Секрет:    $SECRET_PATH"
echo "Период:    последние $DAYS дней"
echo "Журнал:    $AUDIT_LOG"
echo "Дата:      $(date '+%Y-%m-%d %H:%M')"

{
  echo "# Аудит доступа к Vault"
  echo "# Секрет: $SECRET_PATH  |  Период: $DAYS дней  |  Дата: $(date '+%Y-%m-%d %H:%M')"
  echo ""

  CUTOFF_EPOCH=$(( $(date +%s) - DAYS * 86400 ))

  # ── Анализ файла аудита ─────────────────────────────────────────────────
  if [ -f "$AUDIT_LOG" ]; then
    echo "## Доступ к секрету: $SECRET_PATH"
    echo ""

    python3 - <<PYEOF
import json, sys, time
from datetime import datetime
from collections import defaultdict

log_file = "$AUDIT_LOG"
search_path = "$SECRET_PATH"
cutoff = $CUTOFF_EPOCH

ops = defaultdict(lambda: defaultdict(int))
errors = defaultdict(int)
total = 0

try:
    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Проверяем время
            ts = entry.get('time', '')
            try:
                epoch = int(datetime.fromisoformat(ts.replace('Z','+00:00')).timestamp())
                if epoch < cutoff:
                    continue
            except Exception:
                continue

            # Проверяем путь
            req = entry.get('request', {})
            path = req.get('path', '')
            if not (path == search_path or path.startswith(search_path.rstrip('/') + '/')):
                continue

            total += 1
            op = req.get('operation', '?')
            auth = entry.get('auth', {})
            client = auth.get('display_name', auth.get('client_token', '?'))
            resp = entry.get('response', {})
            err = resp.get('data', {}).get('error', '')
            dt = datetime.fromisoformat(ts.replace('Z','+00:00')).strftime('%Y-%m-%d %H:%M')

            ops[client][op] += 1
            if err:
                errors[f"{client} / {op}"] += 1

            # Последние 20 операций
            if total <= 20:
                print(f"   {dt}  {op:<10} {client:<40} {err or 'OK'}")

    print()
    print(f"## Сводка за {$DAYS} дней")
    print(f"   Всего операций: {total}")
    print()
    print(f"   {'Клиент':<40} {'read':>6} {'create':>8} {'update':>8} {'delete':>8} {'list':>6}")
    print(f"   {'-'*40} {'-'*6} {'-'*8} {'-'*8} {'-'*8} {'-'*6}")
    for client, client_ops in sorted(ops.items()):
        r = client_ops.get('read', 0)
        c = client_ops.get('create', 0)
        u = client_ops.get('update', 0)
        d = client_ops.get('delete', 0)
        l = client_ops.get('list', 0)
        print(f"   {client:<40} {r:>6} {c:>8} {u:>8} {d:>8} {l:>6}")

    if errors:
        print()
        print("## Ошибки доступа")
        for key, count in sorted(errors.items(), key=lambda x: -x[1]):
            print(f"   {key}: {count} ошибок")

    if total == 0:
        print("   За период обращений не найдено")

except FileNotFoundError:
    print(f"   Файл журнала не найден: {log_file}")
    print("   Проверьте vault audit list и путь к файлу")
except PermissionError:
    print(f"   Нет прав на чтение: {log_file}")
    print("   Запустите от root или добавьте пользователя в группу vault")
PYEOF

  elif [ -n "$VAULT_TOKEN" ]; then
    # Попытка получить данные через Vault API (если audit-backend поддерживает read)
    echo "## Статус аудита через Vault API"
    audit_list=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
      "$VAULT_ADDR/v1/sys/audit" 2>/dev/null || echo "{}")
    echo "$audit_list" | python3 -c "
import json,sys
devices = json.load(sys.stdin)
if devices:
    for path, info in devices.items():
        opts = info.get('options', {})
        file_path = opts.get('file_path', 'N/A')
        print(f'   Устройство аудита: {path} → {file_path}')
    print()
    print('   Для анализа укажите путь к файлу аудита:')
    print('   bash audit-secret-access.sh $SECRET_PATH $DAYS <путь_к_файлу>')
else:
    print('   Аудит не настроен в Vault')
    print('   Включите: vault audit enable file file_path=/var/log/vault/audit.log')
" 2>/dev/null
  else
    echo "   Файл аудита $AUDIT_LOG не найден"
    echo "   Задайте VAULT_TOKEN для проверки через API"
    echo "   Или укажите путь к файлу: bash $0 '$SECRET_PATH' $DAYS /path/to/audit.log"
  fi

  echo ""
  echo "## Рекомендации"
  echo "   - Обращения из неожиданных клиентов — расследовать"
  echo "   - Многократные ошибки — признак попытки несанкционированного доступа"
  echo "   - Операции delete/update — подтвердить авторизованность изменений"

} | tee "$OUTPUT"

echo ""
echo "Отчёт сохранён: $OUTPUT"
