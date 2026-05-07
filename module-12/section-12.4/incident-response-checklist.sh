#!/usr/bin/env bash
# Пошаговый чек-лист реагирования на инцидент с таймерами для соблюдения сроков НКЦКИ
# Использование: bash incident-response-checklist.sh [категория_КИИ: 1|2|3]
set -euo pipefail

KII_CATEGORY="${1:-1}"
VAULT_ADDR="${VAULT_ADDR:-https://vault.internal.company.local:8200}"
HARBOR_URL="${HARBOR_URL:-https://harbor.internal.company.local}"

# Сроки уведомления НКЦКИ (в минутах)
case "$KII_CATEGORY" in
  1) NOTIFY_DEADLINE=180   ;; # 3 часа
  2) NOTIFY_DEADLINE=1440  ;; # 24 часа
  3) NOTIFY_DEADLINE=4320  ;; # 3 суток
  *) NOTIFY_DEADLINE=180   ;;
esac

START_TIME=$(date +%s)
START_HMS=$(date '+%H:%M:%S')

show_timer() {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local remaining=$(( NOTIFY_DEADLINE * 60 - elapsed ))
  local rem_h=$(( remaining / 3600 ))
  local rem_m=$(( (remaining % 3600) / 60 ))
  if [ "$remaining" -gt 0 ]; then
    echo "  ⏱  До уведомления НКЦКИ: ${rem_h}ч ${rem_m}мин"
  else
    echo "  ⚠️  СРОК УВЕДОМЛЕНИЯ НКЦКИ ИСТЁК — уведомите немедленно"
  fi
}

step() {
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "ШАГ $1: $2"
  echo "Время: $(date '+%H:%M:%S')  (начало: $START_HMS)"
  show_timer
  echo "════════════════════════════════════════════════════════"
}

confirm() {
  local msg="$1"
  echo ""
  echo "$msg"
  echo -n "Выполнено? [y/пропустить/стоп]: "
  read -r answer
  case "$answer" in
    y|Y|да|yes) return 0 ;;
    стоп|stop|q|Q) echo "Остановлено."; exit 0 ;;
    *) echo "  [ПРОПУЩЕНО]"; return 0 ;;
  esac
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║     РЕАГИРОВАНИЕ НА КОМПЬЮТЕРНЫЙ ИНЦИДЕНТ                   ║"
echo "║     КИИ категория: $KII_CATEGORY  │  Срок уведомления НКЦКИ: $(( NOTIFY_DEADLINE / 60 )) ч."
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Начало реагирования: $START_HMS"
echo "Дата: $(date '+%Y-%m-%d')"

# ── ШАГ 1: Фиксация факта инцидента ──────────────────────────────────────
step 1 "Фиксация факта инцидента"
echo ""
echo "  1.1 Запишите время обнаружения: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "  1.2 Опишите наблюдаемые признаки (НЕ предположения о причинах):"
echo -n "  > "
read -r incident_description
echo ""
echo "  1.3 Источник обнаружения:"
echo "    a) Falco / Alertmanager (автоматически)"
echo "    b) Сотрудник сообщил"
echo "    c) Внешнее уведомление"
echo -n "  > "
read -r detection_source

# Создаём журнал реагирования
LOG_FILE="incident-response-$(date +%Y%m%d%H%M%S).log"
{
  echo "# Журнал реагирования на инцидент"
  echo "# Начало: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# КИИ категория: $KII_CATEGORY"
  echo "# Описание: $incident_description"
  echo "# Источник обнаружения: $detection_source"
} > "$LOG_FILE"
echo "  Журнал: $LOG_FILE"

# ── ШАГ 2: Сбор данных ДО изоляции ───────────────────────────────────────
step 2 "Сбор криминалистических данных (ДО изоляции)"
echo ""
echo "  ⚠️  НЕ ПЕРЕЗАПУСКАЙТЕ контейнеры до выполнения этого шага"
echo "  ⚠️  Перезапуск уничтожает доказательства"
echo ""
echo "  2.1 Сохранить список запущенных контейнеров:"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.ID}}' 2>/dev/null | tee -a "$LOG_FILE"
echo ""
echo "  2.2 Запустить сбор криминалистических данных:"
echo "    bash collect-forensics.sh"
confirm "  Сбор данных выполнен?"
echo "$(date '+%H:%M:%S') ШАГ 2: Криминалистика собрана" >> "$LOG_FILE"

# ── ШАГ 3: Изоляция ───────────────────────────────────────────────────────
step 3 "Изоляция скомпрометированного компонента"
echo ""
echo "  3.1 Определите затронутый контейнер/хост:"
echo -n "  Контейнер или хост: "
read -r compromised_target
echo ""
echo "  3.2 Изолировать (остановить сеть, НЕ удалять):"
echo "    docker network disconnect <сеть> $compromised_target"
echo "    # ИЛИ для хоста: iptables -I INPUT -s <ip> -j DROP"
confirm "  Изоляция выполнена?"
echo "$(date '+%H:%M:%S') ШАГ 3: Изолирован $compromised_target" >> "$LOG_FILE"

# ── ШАГ 4: Отзыв скомпрометированных аутентификаторов ────────────────────
step 4 "Отзыв скомпрометированных учётных данных"
echo ""
echo "  4.1 Отозвать аренды Vault если скомпрометирован контейнер:"
echo "    bash revoke-lease.sh <lease_id>"
echo "    # или: vault lease revoke -prefix auth/approle/login"
echo ""
echo "  4.2 Отозвать Robot Account Harbor если скомпрометирован реестр:"
echo "    bash revoke-user-access.sh harbor.internal $compromised_target"
confirm "  Учётные данные отозваны?"
echo "$(date '+%H:%M:%S') ШАГ 4: Учётные данные отозваны" >> "$LOG_FILE"

# ── ШАГ 5: Уведомление НКЦКИ ─────────────────────────────────────────────
step 5 "Уведомление НКЦКИ"
show_timer
echo ""
elapsed=$(( $(date +%s) - START_TIME ))
echo "  Прошло с начала реагирования: $((elapsed / 60)) минут"
echo ""
echo "  5.1 Заполнить форму: incident-report-nkci.md"
echo "  5.2 Отправить на: incident@cert.gov.ru"
echo "  5.3 Горячая линия НКЦКИ: +7 (800) 555-07-05"
echo ""
if [ "$elapsed" -gt $((NOTIFY_DEADLINE * 60)) ]; then
  echo "  ⚠️  СРОК ИСТЁК — уведомите немедленно и зафиксируйте причину задержки"
else
  remaining=$(( NOTIFY_DEADLINE * 60 - elapsed ))
  echo "  Оставшееся время: $((remaining / 60)) минут"
fi
confirm "  Уведомление НКЦКИ отправлено?"
echo "$(date '+%H:%M:%S') ШАГ 5: НКЦКИ уведомлён" >> "$LOG_FILE"

# ── ШАГ 6: Параллельные действия ──────────────────────────────────────────
step 6 "Параллельные действия (выполнять одновременно с шагами 1-5)"
echo ""
echo "  Уведомить руководителя ИТ-службы:"
echo -n "  ФИО уведомлённого: "
read -r notified_person
echo ""
echo "  Уведомить руководство организации (если P1):"
confirm "  Все уведомлены?"
echo "$(date '+%H:%M:%S') ШАГ 6: Уведомления: $notified_person" >> "$LOG_FILE"

# ── Итог ─────────────────────────────────────────────────────────────────
total_elapsed=$(( $(date +%s) - START_TIME ))
echo ""
echo "════════════════════════════════════════════════════════"
echo "РЕАГИРОВАНИЕ ЗАВЕРШЕНО"
echo "Общее время: $((total_elapsed / 60)) минут"
echo "Журнал: $LOG_FILE"
echo ""
echo "Следующие шаги:"
echo "  - Продолжить расследование и устранение"
echo "  - Провести post-mortem (шаблон: incident-report-template.md)"
echo "  - Отправить финальный отчёт в НКЦКИ (при необходимости)"
echo "════════════════════════════════════════════════════════"

# Финальная запись в журнал
{
  echo ""
  echo "# Завершение реагирования"
  echo "# Время: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Общее время реагирования: $((total_elapsed / 60)) мин"
} >> "$LOG_FILE"
