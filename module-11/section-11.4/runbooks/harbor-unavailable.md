# Runbook: Harbor недоступен

**Симптом:** Оповещение `HarborDown`. Docker push/pull завершаются ошибкой. Конвейеры CI/CD не могут загрузить образы.

**Severity:** P1/P2 в зависимости от влияния на продакшен.

---

## 1. Диагностика (3 минуты)

```bash
# Базовая доступность
curl -sf https://harbor.internal.company.local/api/v2.0/ping
# Ожидается: "pong"

# Статус компонентов через API
curl -sf https://harbor.internal.company.local/api/v2.0/health | python3 -m json.tool

# Контейнеры Harbor
docker ps --filter name=harbor | grep -v "Up"

# Журналы ключевых компонентов
docker logs harbor-core --tail=50 2>&1 | grep -i "error\|fatal\|panic"
docker logs harbor-db   --tail=30 2>&1 | grep -i "error\|fatal"
docker logs nginx       --tail=30 2>&1 | grep -i "error\|502\|503"
```

**Типичные причины:**
- Компонент `harbor-core` упал — OOM или ошибка БД
- Компонент `harbor-db` (PostgreSQL) недоступен
- Диск заполнен (`/data/harbor`)
- Истёк TLS-сертификат

---

## 2. Действия: перезапуск

```bash
cd /opt/harbor    # или директория установки Harbor

# Плавный перезапуск всех компонентов
docker compose down && docker compose up -d

# Ожидание готовности (до 60 секунд)
for i in $(seq 1 12); do
  curl -sf https://harbor.internal.company.local/api/v2.0/ping && break
  sleep 5
done

# Проверка после перезапуска
bash /opt/scripts/harbor-health-check.sh
```

---

## 3. Если диск заполнен

```bash
# Проверить заполненность
df -h /data/harbor

# Немедленное освобождение: запустить GC
bash harbor-gc.sh

# Если GC не помогает — удалить неиспользуемые образы вручную
curl -sf -u admin:PASSWORD \
  "https://harbor.internal.company.local/api/v2.0/repositories?page_size=100" | \
  python3 -m json.tool | grep -i "pull_count\|name"
```

---

## 4. Если TLS-сертификат истёк

```bash
# Проверить срок сертификата
openssl s_client -connect harbor.internal.company.local:443 </dev/null 2>/dev/null | \
  openssl x509 -noout -dates

# Перевыпустить через Vault PKI (если настроен)
bash issue-service-cert-vault.sh harbor

# Или вручную заменить сертификат и перезапустить nginx
cp new-cert.crt /opt/harbor/data/cert/harbor.crt
cp new-cert.key /opt/harbor/data/cert/harbor.key
docker compose restart nginx
```

---

## 5. Критерий разрешения

- `curl -sf https://harbor.internal.company.local/api/v2.0/ping` возвращает `pong`
- `docker pull harbor.internal.company.local/library/alpine:3.19` успешно
- Оповещение `HarborDown` закрылось в Alertmanager

---

## 6. Эскалация

Если самостоятельное восстановление не удалось за 30 минут:
- Активировать резервный Harbor (если настроен active-standby)
- Обратиться к владельцу системы Harbor (см. реестр)

---

## 7. Post-mortem

Зафиксировать:
- Компонент, вызвавший сбой
- Причину (OOM, диск, сертификат, БД)
- Время недоступности и влияние на конвейеры
