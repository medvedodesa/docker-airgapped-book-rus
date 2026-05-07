#!/usr/bin/env bash
# Настройка Docker-хоста для работы с Harbor: добавление CA, проверка соединения
# Использование: sudo bash configure-docker-for-harbor.sh <harbor_hostname> [путь_к_CA.crt]
set -euo pipefail

HARBOR_HOST="${1:-harbor.internal.company.local}"
CA_CERT="${2:-}"

echo "=== Настройка Docker для Harbor: $HARBOR_HOST ==="

# Добавление CA в доверенные
echo ""
echo "--- Доверенный CA ---"
if [ -n "$CA_CERT" ] && [ -f "$CA_CERT" ]; then
  # Метод 1: системное хранилище
  if [ -d /usr/local/share/ca-certificates ]; then
    cp "$CA_CERT" /usr/local/share/ca-certificates/harbor-ca.crt
    update-ca-certificates 2>/dev/null
    echo "[OK] CA добавлен в системное хранилище (Ubuntu/Debian)"
  elif [ -d /etc/pki/ca-trust/source/anchors ]; then
    cp "$CA_CERT" /etc/pki/ca-trust/source/anchors/harbor-ca.crt
    update-ca-trust 2>/dev/null
    echo "[OK] CA добавлен в системное хранилище (RHEL/Rocky)"
  fi

  # Метод 2: для Docker-специфичного доверия
  DOCKER_CERT_DIR="/etc/docker/certs.d/${HARBOR_HOST}"
  mkdir -p "$DOCKER_CERT_DIR"
  cp "$CA_CERT" "$DOCKER_CERT_DIR/ca.crt"
  echo "[OK] CA добавлен в $DOCKER_CERT_DIR/ca.crt"
else
  echo "[WARN] CA-сертификат не указан — Docker будет использовать системное хранилище"
fi

# Проверка DNS
echo ""
echo "--- Проверка DNS ---"
if host "$HARBOR_HOST" &>/dev/null 2>&1 || nslookup "$HARBOR_HOST" &>/dev/null 2>&1; then
  ip=$(host "$HARBOR_HOST" 2>/dev/null | awk '/address/{print $NF}' | head -1)
  echo "[OK] $HARBOR_HOST -> $ip"
else
  echo "[FAIL] DNS-имя $HARBOR_HOST не резолвится — проверьте DNS-конфигурацию"
  exit 1
fi

# Проверка HTTPS-соединения
echo ""
echo "--- Проверка HTTPS ---"
if curl -sf "https://$HARBOR_HOST/api/v2.0/health" -o /dev/null 2>/dev/null; then
  echo "[OK] HTTPS к $HARBOR_HOST работает"
else
  echo "[FAIL] HTTPS к $HARBOR_HOST не работает"
  echo "  Проверьте: сертификат, DNS, доступность хоста"
  exit 1
fi

# Тестовый pull
echo ""
echo "--- Тестовый доступ ---"
echo "  Попытка анонимного доступа к /v2/ ..."
http_code=$(curl -so /dev/null -w "%{http_code}" "https://$HARBOR_HOST/v2/" 2>/dev/null)
case "$http_code" in
  200|401) echo "[OK] Harbor API отвечает (HTTP $http_code)" ;;
  *)       echo "[WARN] Harbor API вернул HTTP $http_code" ;;
esac

echo ""
echo "=== Конфигурация применена ==="
echo "  Выполните: docker login $HARBOR_HOST"
