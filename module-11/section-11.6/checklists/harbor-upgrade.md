# Чек-лист: Обновление Harbor

**Версия:** __________ → __________  
**Дата:**   __________  
**Инженер:** __________  

---

## Подготовка

- [ ] Проверить release notes новой версии Harbor на изменения схемы БД
- [ ] Скачать и перенести новый образ Harbor в закрытый контур
- [ ] Убедиться что новый образ прошёл Trivy-сканирование

## Перед обновлением

- [ ] Создать резервную копию: `pg_dump registry > harbor-db-$(date +%Y%m%d).sql`
- [ ] Создать резервную копию blob: `tar czf harbor-data-$(date +%Y%m%d).tar.gz /data/harbor/registry`
- [ ] Записать текущую версию: `docker exec harbor-core cat /harbor/VERSION`
- [ ] Свободно >20 ГБ на диске хранилища

## Обновление

- [ ] Остановить Harbor: `docker compose down`
- [ ] Обновить тег образа в docker-compose.yml
- [ ] Запустить: `docker compose up -d`
- [ ] Дождаться автоматической миграции БД (журнал: `docker logs harbor-core`)

## Проверка

- [ ] `curl -sf https://harbor.internal.company.local/api/v2.0/health` — все компоненты healthy
- [ ] `docker pull harbor.internal.company.local/library/alpine:3.19` — успешно
- [ ] Войти в Harbor UI, проверить список образов
- [ ] Убедиться что сканирование работает

## Завершение

- [ ] Обновить версию Harbor в техническом паспорте
- [ ] Сделать коммит с новым docker-compose.yml в репозиторий
