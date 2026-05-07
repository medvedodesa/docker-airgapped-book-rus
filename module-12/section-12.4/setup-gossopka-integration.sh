#!/usr/bin/env bash
# Настройка интеграции с ГосСОПКА через НКЦКИ для уведомления об инцидентах
# Использование: bash setup-gossopka-integration.sh
# Документация: https://nkcki.ru / технические требования к взаимодействию
set -euo pipefail

GOSSOPKA_API="${GOSSOPKA_API:-https://portal.cert.gov.ru/api/v1}"
CERT_DIR="${GOSSOPKA_CERT_DIR:-/etc/gossopka/certs}"
CONFIG_DIR="/etc/gossopka"
SCRIPT_DIR="/opt/gossopka"

echo "=== Настройка интеграции с ГосСОПКА/НКЦКИ ==="
echo "  API:    $GOSSOPKA_API"
echo "  Сертификаты: $CERT_DIR"
echo ""
echo "  ВНИМАНИЕ: Для реального подключения требуются:"
echo "  1. Договор с НКЦКИ / ФСБ России"
echo "  2. Квалифицированный сертификат ЭП организации"
echo "  3. Регистрация в личном кабинете ГосСОПКА"
echo ""

mkdir -p "$CERT_DIR" "$CONFIG_DIR" "$SCRIPT_DIR"
chmod 700 "$CERT_DIR"

# Конфигурация подключения
cat > "$CONFIG_DIR/gossopka.conf" << CONF
# Конфигурация взаимодействия с ГосСОПКА
# Приказ ФСБ России №281 от 06.05.2019

# Адрес API НКЦКИ (prod)
GOSSOPKA_API="$GOSSOPKA_API"

# Сертификат организации (квалифицированный, ФСБ/ФСТЭК)
ORG_CERT="$CERT_DIR/org.crt"
ORG_KEY="$CERT_DIR/org.key"

# CA НКЦКИ
NKCKI_CA="$CERT_DIR/nkcki-ca.crt"

# ИНН организации (для идентификации)
ORG_INN=""

# Email уведомлений (дублирование)
NOTIFY_EMAIL=""

# Дедлайн уведомления для КИИ 1-й категории: 3 часа
KII_CAT1_DEADLINE_HOURS=3
# Для 2-й и 3-й категории: 24 часа
KII_DEFAULT_DEADLINE_HOURS=24
CONF
echo "  [OK] $CONFIG_DIR/gossopka.conf"

# Скрипт отправки уведомления об инциденте
cat > "$SCRIPT_DIR/send-incident-notification.sh" << 'NOTIF'
#!/usr/bin/env bash
# Отправка уведомления об инциденте в НКЦКИ
set -euo pipefail

. /etc/gossopka/gossopka.conf

INCIDENT_TYPE="${1:-}"    # Несанкционированный_доступ|Вредоносное_ПО|Нарушение_доступности|Иное
DESCRIPTION="${2:-}"
SEVERITY="${3:-medium}"   # low|medium|high|critical
AFFECTED_SYSTEMS="${4:-}"

[ -n "$INCIDENT_TYPE" ] && [ -n "$DESCRIPTION" ] || {
  echo "Использование: $0 <тип_инцидента> <описание> [severity] [затронутые_системы]"
  exit 1
}

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INCIDENT_ID="INC-$(date +%Y%m%d)-$(hostname | cut -c1-6)-$(shuf -i 1000-9999 -n1)"

# Формирование JSON уведомления
NOTIFICATION=$(cat << JSON
{
  "incident_id": "$INCIDENT_ID",
  "timestamp": "$TIMESTAMP",
  "type": "$INCIDENT_TYPE",
  "severity": "$SEVERITY",
  "description": "$DESCRIPTION",
  "affected_systems": "$AFFECTED_SYSTEMS",
  "organization": {
    "inn": "$ORG_INN",
    "contact_email": "$NOTIFY_EMAIL"
  },
  "source": {
    "hostname": "$(hostname)",
    "ip": "$(hostname -I | awk '{print $1}')"
  }
}
JSON
)

# Запись в локальный журнал (всегда, независимо от успеха отправки)
echo "$TIMESTAMP | $INCIDENT_ID | $SEVERITY | $INCIDENT_TYPE | $DESCRIPTION" \
  >> /var/log/gossopka-incidents.log

# Проверка наличия сертификатов
if [ ! -f "$ORG_CERT" ] || [ ! -f "$ORG_KEY" ]; then
  echo "[WARN] Сертификаты организации не найдены — уведомление записано только локально"
  echo "  Incident ID: $INCIDENT_ID"
  exit 0
fi

# Отправка в НКЦКИ
HTTP_CODE=$(curl -s -o /tmp/gossopka-response.json \
  -w "%{http_code}" \
  --cert "$ORG_CERT" \
  --key "$ORG_KEY" \
  --cacert "$NKCKI_CA" \
  --max-time 30 \
  -X POST \
  -H "Content-Type: application/json" \
  -d "$NOTIFICATION" \
  "$GOSSOPKA_API/incidents" \
  2>/dev/null || echo "000")

if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ]; then
  echo "[OK] Уведомление отправлено в НКЦКИ: $INCIDENT_ID"
else
  echo "[WARN] HTTP $HTTP_CODE — уведомление сохранено локально: $INCIDENT_ID"
  echo "  Отправьте вручную через личный кабинет: https://lk.cert.gov.ru"
fi

# Дублирование по email
[ -n "$NOTIFY_EMAIL" ] && \
  echo "Incident: $INCIDENT_ID | $INCIDENT_TYPE | $DESCRIPTION" | \
  mail -s "[ГосСОПКА] Инцидент $INCIDENT_ID ($SEVERITY)" "$NOTIFY_EMAIL" 2>/dev/null || true
NOTIF
chmod +x "$SCRIPT_DIR/send-incident-notification.sh"
echo "  [OK] $SCRIPT_DIR/send-incident-notification.sh"

# Таймер дедлайна для КИИ 1-й категории
cat > "$SCRIPT_DIR/check-incident-deadline.sh" << 'DEADLINE'
#!/usr/bin/env bash
# Проверка не истёк ли 3-часовой дедлайн уведомления для КИИ 1-й категории
set -euo pipefail

. /etc/gossopka/gossopka.conf

INCIDENT_FILE="${1:-}"
[ -f "$INCIDENT_FILE" ] || { echo "Укажите файл инцидента"; exit 1; }

incident_time=$(stat -c %Y "$INCIDENT_FILE" 2>/dev/null)
now=$(date +%s)
elapsed_hours=$(( (now - incident_time) / 3600 ))
elapsed_min=$(( (now - incident_time) / 60 ))

if [ "$elapsed_hours" -lt "$KII_CAT1_DEADLINE_HOURS" ]; then
  remaining=$(( KII_CAT1_DEADLINE_HOURS * 60 - elapsed_min ))
  echo "[OK] Осталось ~$remaining минут до дедлайна уведомления НКЦКИ"
else
  echo "[FAIL] ДЕДЛАЙН ИСТЁК: прошло $elapsed_hours ч. (лимит $KII_CAT1_DEADLINE_HOURS ч.)"
  echo "  Немедленно уведомьте НКЦКИ через личный кабинет!"
  exit 1
fi
DEADLINE
chmod +x "$SCRIPT_DIR/check-incident-deadline.sh"
echo "  [OK] $SCRIPT_DIR/check-incident-deadline.sh"

# Logrotate для журнала инцидентов
cat > /etc/logrotate.d/gossopka << 'LR'
/var/log/gossopka-incidents.log {
    monthly
    rotate 60
    compress
    missingok
    notifempty
}
LR
echo "  [OK] logrotate для gossopka-incidents.log"

echo ""
echo "=== Интеграция ГосСОПКА настроена ==="
echo ""
echo "Следующие шаги:"
echo "1. Заполните ORG_INN и NOTIFY_EMAIL в $CONFIG_DIR/gossopka.conf"
echo "2. Поместите сертификат организации в $CERT_DIR/org.crt и org.key"
echo "3. Поместите CA НКЦКИ в $CERT_DIR/nkcki-ca.crt"
echo ""
echo "Тест отправки уведомления:"
echo "  $SCRIPT_DIR/send-incident-notification.sh Тест 'Тестовое уведомление' low"
