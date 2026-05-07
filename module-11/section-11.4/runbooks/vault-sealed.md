# Runbook: Vault запечатан (Sealed)

**Симптом:** Оповещение `VaultSealed` из Alertmanager. Сервисы не могут получить секреты и не запускаются.

**Severity:** P1 — Критический. Немедленная реакция.

---

## 1. Диагностика (2 минуты)

```bash
# Проверить статус Vault
curl -s https://vault.internal.company.local:8200/v1/sys/health | python3 -m json.tool

# Ожидаемый ответ при sealed:
# {"sealed": true, "initialized": true, ...}

# Проверить запущен ли процесс
systemctl status vault
# или
docker ps | grep vault
```

**Возможные причины:**
- Плановый перезапуск хоста или обновление
- Аварийный перезапуск процесса Vault
- Сработала защита (слишком много ошибок)

---

## 2. Действия: распечатывание (Unseal)

### Собираем кворум держателей ключей

Для распечатывания нужно **N держателей из M** (обычно 3 из 5). Проверьте реестр держателей ключей.

```bash
# Каждый держатель вводит свой фрагмент
# ВЫПОЛНЯЕТСЯ ПОСЛЕДОВАТЕЛЬНО КАЖДЫМ ДЕРЖАТЕЛЕМ
vault operator unseal
# Введите фрагмент ключа (Base64): <фрагмент_1>

# Проверить прогресс после каждого ввода
vault operator key-status
# Unseal Progress: 1/3, 2/3, 3/3 → "Unsealed: true"
```

### Проверка после распечатывания

```bash
# Статус должен показать "sealed: false"
curl -s https://vault.internal.company.local:8200/v1/sys/health | python3 -m json.tool

# Проверить аудит-лог
vault audit list

# Убедиться что сервисы получают секреты
vault kv get secret/prod/harbor/admin-password
```

---

## 3. Проверка сервисов после восстановления

```bash
# Проверить что сервисы поднялись
docker ps | grep -v "Up"

# Если сервисы не поднялись — перезапустить
docker compose restart <сервис>

# Проверить Prometheus: vault_core_unsealed должен быть 1
curl -s "http://prometheus.internal:9090/api/v1/query?query=vault_core_unsealed" | python3 -m json.tool
```

---

## 4. Критерий разрешения

- `vault_core_unsealed = 1` в Prometheus
- Оповещение `VaultSealed` закрылось в Alertmanager
- Все зависимые сервисы работают: `docker ps | grep -v "Up"` — пусто

---

## 5. Эскалация

Если кворум невозможно собрать (держатели недоступны):
- Позвонить ответственному за безопасность (см. реестр контактов)
- Запустить аварийную процедуру генерации корневого токена: `generate-root-token.sh`

---

## 6. Post-mortem

Зафиксировать в `incident-report-template.md`:
- Время обнаружения и устранения
- Причина запечатывания
- Время недоступности сервисов
- Число держателей, участвовавших в распечатывании
