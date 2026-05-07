#!/usr/bin/env bash
# Настройка stunnel с ГОСТ-шифрованием как TLS-прокси для существующего сервиса
# stunnel принимает ГОСТ TLS → проксирует в незашифрованный backend
# Использование: bash setup-stunnel-gost.sh [сервис_порт] [stunnel_порт] [backend_host:port]
set -euo pipefail

STUNNEL_PORT="${1:-8443}"
BACKEND="${2:-localhost:8080}"
SERVICE_NAME="${3:-myservice}"
CERT_DIR="${STUNNEL_CERT_DIR:-/etc/stunnel/certs}"
STUNNEL_CONF="${STUNNEL_CONF:-/etc/stunnel/stunnel-gost.conf}"
CRYPTOPRO_DIR="${CRYPTOPRO_DIR:-/opt/cprocsp}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "[PASS] $1"; ((PASS++)); }
warn() { echo "[WARN] $1"; ((WARN++)); }
fail() { echo "[FAIL] $1"; ((FAIL++)); }

echo "=== Настройка stunnel с ГОСТ-поддержкой ==="
echo "ГОСТ TLS порт: $STUNNEL_PORT"
echo "Backend:       $BACKEND"
echo "Сервис:        $SERVICE_NAME"
echo "Дата:          $(date '+%Y-%m-%d %H:%M')"

# --- Проверка stunnel ---
echo ""
echo "--- stunnel ---"
if command -v stunnel &>/dev/null; then
  stunnel_ver=$(stunnel -version 2>&1 | head -1)
  ok "stunnel найден: $stunnel_ver"
  # Проверяем поддержку ГОСТ
  if stunnel -version 2>&1 | grep -qi "gost\|cryptopro"; then
    ok "stunnel скомпилирован с поддержкой ГОСТ"
  else
    warn "stunnel без ГОСТ-поддержки — используйте версию от КриптоПро"
    echo "    Скачайте stunnel с ГОСТ от КриптоПро и установите вместо системного"
  fi
elif [ -f "$CRYPTOPRO_DIR/bin/stunnel" ]; then
  STUNNEL_BIN="$CRYPTOPRO_DIR/bin/stunnel"
  ok "КриптоПро stunnel: $STUNNEL_BIN"
else
  fail "stunnel не найден — установите пакет stunnel или stunnel от КриптоПро"
  exit 1
fi

STUNNEL_BIN="${STUNNEL_BIN:-stunnel}"

# --- Проверка КриптоПро ---
echo ""
echo "--- КриптоПро CSP ---"
if [ -d "$CRYPTOPRO_DIR" ]; then
  ok "КриптоПро CSP установлен: $CRYPTOPRO_DIR"
  if command -v cpconfig &>/dev/null; then
    ok "cpconfig доступен"
  fi
else
  fail "КриптоПро CSP не установлен — ГОСТ TLS невозможен"
  exit 1
fi

# --- Сертификаты ---
echo ""
echo "--- Сертификаты ---"
mkdir -p "$CERT_DIR"

CERT_FILE="$CERT_DIR/$SERVICE_NAME.pem"
KEY_FILE="$CERT_DIR/$SERVICE_NAME.key"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  ok "Сертификат найден: $CERT_FILE"
  # Проверяем тип ключа (должен быть ГОСТ)
  key_type=$(openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | \
    grep "Public Key Algorithm" | awk '{print $NF}')
  echo "    Алгоритм ключа: $key_type"
  if echo "$key_type" | grep -qi "gost\|id-GostR"; then
    ok "ГОСТ-сертификат подтверждён"
  else
    warn "Сертификат не ГОСТ ($key_type) — для ГОСТ TLS нужен ГОСТ-сертификат от ЦС"
    echo "    Получите ГОСТ-сертификат от аккредитованного Удостоверяющего Центра"
  fi
else
  warn "Сертификат не найден: $CERT_FILE"
  echo "    Для тестирования создадим самоподписанный (не для продакшена):"
  echo "    csptest -keygen -provtype 80 -keyid $SERVICE_NAME"
  echo "    cryptcp -createcert -dn 'CN=$SERVICE_NAME.internal.company.local' -keyid $SERVICE_NAME"
fi

# --- Конфигурация stunnel ---
echo ""
echo "--- Конфигурация ---"
cat > "$STUNNEL_CONF" <<CONF
; stunnel с ГОСТ-шифрованием
; Генерируется: $(date '+%Y-%m-%d %H:%M')

; Глобальные параметры
pid = /var/run/stunnel-gost.pid
output = /var/log/stunnel-gost.log
foreground = no
syslog = yes

; ГОСТ-движок КриптоПро
engine = gost
engineDefault = RSA,DSA,ECDH,ECDSA,DH,RAND,PKEY,PKEY_CRYPTO,PKEY_ASN1

; Глобальные TLS-параметры
sslVersion = TLSv1.2
; Предпочтительные ГОСТ-шифры
ciphers = GOST2012-GOST8912-GOST8912:GOST2012-NULL-GOST12:GOST2001-GOST89-GOST89

[${SERVICE_NAME}-gost]
accept  = $STUNNEL_PORT
connect = $BACKEND

; ГОСТ-сертификат и ключ (из хранилища КриптоПро или файл)
cert = $CERT_FILE
key  = $KEY_FILE

; Логирование для аудита
debug = 6

; Опционально: mTLS (взаимная аутентификация клиентов)
; CAfile = $CERT_DIR/ca-gost.pem
; verify = 2
CONF
ok "Конфигурация создана: $STUNNEL_CONF"

# --- systemd юнит ---
cat > /etc/systemd/system/stunnel-gost.service <<UNIT
[Unit]
Description=stunnel ГОСТ TLS proxy для $SERVICE_NAME
After=network.target

[Service]
Type=forking
ExecStart=$STUNNEL_BIN $STUNNEL_CONF
ExecStop=/bin/kill -TERM \$MAINPID
PIDFile=/var/run/stunnel-gost.pid
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload 2>/dev/null && ok "systemd юнит создан" || warn "systemd недоступен"

# --- Проверка конфигурации ---
echo ""
echo "--- Тест конфигурации ---"
if $STUNNEL_BIN -test "$STUNNEL_CONF" 2>/dev/null; then
  ok "Конфигурация stunnel корректна"
else
  warn "Конфигурация содержит ошибки — проверьте вручную: $STUNNEL_BIN -test $STUNNEL_CONF"
fi

echo ""
echo "=== Итог ==="
echo "PASS: $PASS  WARN: $WARN  FAIL: $FAIL"
echo ""
echo "Запуск: systemctl enable --now stunnel-gost"
echo "Проверка ГОСТ TLS: openssl s_client -connect localhost:$STUNNEL_PORT -cipher GOST2012-GOST8912-GOST8912"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
