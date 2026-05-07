#!/usr/bin/env bash
# Проверка состояния Vault: sealed/unsealed, версия, активные механизмы и методы аутентификации
# Использование: bash vault-architecture-check.sh [vault_addr] [vault_token]
set -euo pipefail

VAULT_ADDR="${1:-${VAULT_ADDR:-https://vault.internal.company.local:8200}}"
VAULT_TOKEN="${2:-${VAULT_TOKEN:-}}"
OUTPUT="${VAULT_CHECK_OUTPUT:-vault-architecture-check-$(date +%Y%m%d).txt}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

api() {
  local path="$1"
  curl -sf --max-time 10 \
    ${VAULT_TOKEN:+-H "X-Vault-Token: $VAULT_TOKEN"} \
    "$VAULT_ADDR/v1/$path" 2>/dev/null
}

echo "=== Проверка архитектуры Vault ==="
echo "Адрес: $VAULT_ADDR"
echo "Дата:  $(date '+%Y-%m-%d %H:%M')"

# ── Доступность и TLS ─────────────────────────────────────────────────────
echo ""
echo "── Доступность ─────────────────────────────────────────────────────────"
health=$(curl -sf --max-time 10 "$VAULT_ADDR/v1/sys/health" 2>/dev/null || echo "{}")
if [ -z "$health" ] || [ "$health" = "{}" ]; then
  fail "Vault недоступен: $VAULT_ADDR"
  exit 1
fi
ok "Vault отвечает: $VAULT_ADDR"

# TLS
vault_host=$(echo "$VAULT_ADDR" | sed 's|https\?://||' | cut -d: -f1)
vault_port=$(echo "$VAULT_ADDR" | awk -F: '{print $NF}' | cut -d/ -f1)
if echo | openssl s_client -connect "$vault_host:$vault_port" \
    -servername "$vault_host" 2>/dev/null | grep -q "Verify return code: 0"; then
  ok "TLS: сертификат доверенный"
elif echo | openssl s_client -connect "$vault_host:$vault_port" 2>/dev/null | grep -q "CONNECTED"; then
  warn "TLS: соединение установлено, но сертификат не прошёл проверку CA"
else
  fail "TLS: соединение не установлено"
fi

# ── Версия и режим ────────────────────────────────────────────────────────
echo ""
echo "── Версия и режим ──────────────────────────────────────────────────────"
version=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
initialized=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('initialized',False))" 2>/dev/null || echo "?")
sealed=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('sealed',True))" 2>/dev/null || echo "True")
standby=$(echo "$health" | python3 -c "import json,sys; print(json.load(sys.stdin).get('standby',False))" 2>/dev/null || echo "?")

ok "Версия Vault: $version"
[ "$initialized" = "True" ] && ok "Инициализирован: да" || fail "Инициализирован: нет"
if [ "$sealed" = "True" ]; then
  fail "Состояние: SEALED (запечатан) — сервисы не могут получить секреты"
else
  ok "Состояние: unsealed (распечатан)"
fi
[ "$standby" = "False" ] && ok "Роль: Active (лидер)" || warn "Роль: Standby (резервный)"

# Dev-mode
if echo "$health" | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print(d.get('license',{}))" 2>/dev/null | grep -q "dev"; then
  fail "Dev-mode: ВКЛЮЧЁН — данные в памяти, без шифрования, недопустимо в продакшене"
fi

[ -z "$VAULT_TOKEN" ] && { warn "VAULT_TOKEN не задан — детальные проверки пропущены"; echo ""; echo "=== Итог ==="; echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"; exit 0; }

# ── Ключи и кворум ────────────────────────────────────────────────────────
echo ""
echo "── Ключи распечатывания ────────────────────────────────────────────────"
key_status=$(api "sys/key-status" 2>/dev/null || echo "{}")
seal_type=$(api "sys/seal-status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('type','?'))" 2>/dev/null || echo "?")
threshold=$(api "sys/seal-status" | python3 -c "import json,sys; print(json.load(sys.stdin).get('t','?'))" 2>/dev/null || echo "?")
shares=$(api "sys/seal-status"    | python3 -c "import json,sys; print(json.load(sys.stdin).get('n','?'))" 2>/dev/null || echo "?")
ok "Тип запечатывания: $seal_type"
ok "Порог/доли ключа: $threshold из $shares"

# ── Хранилище Raft ────────────────────────────────────────────────────────
echo ""
echo "── Хранилище Raft ──────────────────────────────────────────────────────"
raft_config=$(api "sys/storage/raft/configuration" 2>/dev/null || echo "{}")
if echo "$raft_config" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('data',{}).get('config',{}))" 2>/dev/null | grep -q "leader_id"; then
  raft_servers=$(echo "$raft_config" | python3 -c "
import json,sys
cfg = json.load(sys.stdin).get('data',{}).get('config',{})
servers = cfg.get('servers',[])
print(f'Узлов в кластере: {len(servers)}')
for s in servers:
    print(f'  {s.get(\"address\",\"?\")} voter={s.get(\"voter\",\"?\")} leader={s.get(\"leader\",False)}')
" 2>/dev/null || echo "")
  ok "Raft-кластер активен"
  echo "$raft_servers" | sed 's/^/    /'
else
  warn "Raft-конфигурация недоступна (одиночный узел или нет прав)"
fi

# ── Механизмы секретов ────────────────────────────────────────────────────
echo ""
echo "── Механизмы секретов ──────────────────────────────────────────────────"
mounts=$(api "sys/mounts" 2>/dev/null || echo "{}")
echo "$mounts" | python3 -c "
import json,sys
mounts = json.load(sys.stdin)
expected = {'kv': False, 'pki': False, 'database': False, 'transit': False, 'ssh': False}
for path, info in mounts.items():
    t = info.get('type','?')
    desc = info.get('description','')
    print(f'  [{\"PASS\" if t != \"?\" else \"INFO\"}] {path}: {t}  {desc[:40]}')
    for k in expected:
        if t == k: expected[k] = True
print()
for k, found in expected.items():
    if found: print(f'  [PASS] Механизм {k}: настроен')
    else:     print(f'  [INFO] Механизм {k}: не настроен')
" 2>/dev/null || warn "Механизмы секретов недоступны"

# ── Методы аутентификации ─────────────────────────────────────────────────
echo ""
echo "── Методы аутентификации ───────────────────────────────────────────────"
auth_methods=$(api "sys/auth" 2>/dev/null || echo "{}")
echo "$auth_methods" | python3 -c "
import json,sys
methods = json.load(sys.stdin)
expected = {'approle/': False, 'ldap/': False}
for path, info in methods.items():
    t = info.get('type','?')
    print(f'  [OK] {path}: {t}')
    if path in expected: expected[path] = True
print()
for path, found in expected.items():
    if not found: print(f'  [WARN] Метод {path} не настроен')
" 2>/dev/null || warn "Методы аутентификации недоступны"

# ── Аудит ─────────────────────────────────────────────────────────────────
echo ""
echo "── Аудит ────────────────────────────────────────────────────────────────"
audit_devices=$(api "sys/audit" 2>/dev/null || echo "{}")
audit_count=$(echo "$audit_devices" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)
if [ "$audit_count" -gt 0 ]; then
  ok "Устройств аудита: $audit_count"
  echo "$audit_devices" | python3 -c "
import json,sys
for path, info in json.load(sys.stdin).items():
    print(f'  {path}: {info.get(\"type\",\"?\")} — {info.get(\"description\",\"\")}')
" 2>/dev/null
else
  fail "Аудит не настроен — все обращения к секретам не фиксируются"
fi

# ── Корневой токен ────────────────────────────────────────────────────────
echo ""
echo "── Корневой токен ───────────────────────────────────────────────────────"
token_info=$(api "auth/token/lookup-self" 2>/dev/null | python3 -c "
import json,sys; d=json.load(sys.stdin).get('data',{}); print(d.get('policies',[]))
" 2>/dev/null || echo "[]")
if echo "$token_info" | grep -q '"root"'; then
  fail "Используется root-токен — должен быть немедленно отозван после настройки"
else
  ok "Не используется root-токен"
fi

# ── Итог ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
