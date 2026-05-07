#!/usr/bin/env bash
# Проверка наличия ГОСТ-криптографии: КриптоПро CSP, ViPNet, СКЗИ
# Использование: bash check-gost-requirements.sh
set -euo pipefail

PASS=0; WARN=0; FAIL=0

ok()   { echo "  [OK]   $1"; ((PASS++)); }
warn() { echo "  [WARN] $1"; ((WARN++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

echo "=== Проверка ГОСТ-криптографии ==="
echo "  Требования: ФСБ России, ГОСТ Р 34.10-2012, ГОСТ Р 34.11-2012"
echo ""

# КриптоПро CSP
echo "--- КриптоПро CSP ---"
if command -v cryptcp &>/dev/null; then
  ver=$(cryptcp -ver 2>/dev/null | head -1 || echo "версия неизвестна")
  ok "cryptcp доступен: $ver"
elif command -v cpconfig &>/dev/null; then
  ok "КриптоПро CSP установлен (cpconfig)"
elif dpkg -l 2>/dev/null | grep -qi "cprocsp\|cryptopro"; then
  ok "КриптоПро CSP (пакет) установлен"
else
  warn "КриптоПро CSP не обнаружен"
fi

# Лицензия КриптоПро
if command -v cpconfig &>/dev/null; then
  license=$(cpconfig -license -view 2>/dev/null | grep -i "expire\|срок" || echo "")
  [ -n "$license" ] && ok "Лицензия КриптоПро: $license" || warn "Лицензия КриптоПро: не удалось проверить"
fi

# ViPNet
echo ""
echo "--- ViPNet ---"
if systemctl is-active itcsrv &>/dev/null 2>&1 || \
   systemctl is-active itcskip &>/dev/null 2>&1 || \
   dpkg -l 2>/dev/null | grep -qi vipnet; then
  ok "ViPNet обнаружен"
else
  warn "ViPNet не обнаружен (может использоваться другой СКЗИ)"
fi

# ГОСТ сертификаты
echo ""
echo "--- ГОСТ-сертификаты ---"
for cert_dir in /etc/ssl/certs /etc/docker/certs.d /etc/harbor/ssl /etc/vault.d/tls; do
  [ -d "$cert_dir" ] || continue
  while IFS= read -r cert; do
    algo=$(openssl x509 -in "$cert" -noout -text 2>/dev/null | grep "Public Key Algorithm" || echo "")
    if echo "$algo" | grep -qiE "gost|GOST"; then
      ok "ГОСТ-сертификат: $cert"
    fi
  done < <(find "$cert_dir" -name "*.crt" -o -name "*.pem" 2>/dev/null)
done

# Контейнер КриптоПро
echo ""
echo "--- КриптоПро в Docker ---"
if docker images 2>/dev/null | grep -qi cryptopro; then
  ok "Образ с КриптоПро найден в локальном реестре"
else
  warn "Образ с КриптоПро не найден (может быть в Harbor)"
fi

# TLS версии
echo ""
echo "--- TLS конфигурация ---"
DAEMON_JSON="/etc/docker/daemon.json"
if [ -f "$DAEMON_JSON" ] && python3 -c "
import json
d=json.load(open('$DAEMON_JSON'))
assert d.get('tls') or d.get('tlsverify'), 'no tls'
" 2>/dev/null; then
  ok "Docker daemon использует TLS"
else
  warn "TLS Docker daemon: проверьте /etc/docker/daemon.json"
fi

# OpenSSL ГОСТ engine
echo ""
echo "--- OpenSSL ГОСТ engine ---"
if openssl engine 2>/dev/null | grep -qi "gost\|cryptopro"; then
  ok "ГОСТ engine зарегистрирован в OpenSSL"
else
  warn "ГОСТ engine не зарегистрирован в OpenSSL"
fi

# Итог
echo ""
echo "=== Итог: PASS=$PASS  WARN=$WARN  FAIL=$FAIL ==="
echo ""
if [ "$PASS" -ge 3 ]; then
  echo "  СКЗИ обнаружены — проверьте наличие действующих сертификатов ФСБ"
else
  echo "  СКЗИ не обнаружены или не настроены"
fi
echo ""
echo "  Для получения лицензий СКЗИ:"
echo "  - КриптоПро: www.cryptopro.ru"
echo "  - ViPNet: infotecs.ru"
