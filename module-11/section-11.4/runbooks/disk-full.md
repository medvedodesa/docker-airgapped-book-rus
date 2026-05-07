# Runbook: Диск заполнен

**Симптом:** Оповещение `DiskSpaceCritical` (>95%) или `DiskSpaceWarning` (>85%). Сервисы могут падать с ошибками записи.

**Severity:** P1 при >95%, P2 при >85%.

---

## 1. Диагностика (2 минуты)

```bash
# Определить заполненный диск
df -h | sort -k5 -rh | head -10

# Найти самые большие директории
du -sh /var/lib/docker/* 2>/dev/null | sort -rh | head -10
du -sh /var/log/* 2>/dev/null | sort -rh | head -10
du -sh /data/harbor/* 2>/dev/null | sort -rh | head -10
du -sh /var/opt/gitlab/* 2>/dev/null | sort -rh | head -10

# Слои Docker (dangling images)
docker system df
```

---

## 2. Немедленные действия для освобождения места

### Вариант A: Docker (первым делом)

```bash
# Удалить остановленные контейнеры, неиспользуемые образы, кеш сборки
docker system prune -f

# Если всё ещё критично — удалить и тома без владельцев
docker system prune --volumes -f

# Проверить освобождённое место
df -h /var/lib/docker
```

### Вариант B: Harbor GC

```bash
bash harbor-gc.sh

# После GC — проверить
df -h /data/harbor
```

### Вариант C: Журналы

```bash
# Размер журналов Docker по контейнерам
find /var/lib/docker/containers -name "*.log" \
  -exec du -sh {} \; 2>/dev/null | sort -rh | head -10

# Очистить журнал конкретного контейнера (безопасно)
truncate -s 0 /var/lib/docker/containers/<id>/*.log

# Системные журналы
journalctl --disk-usage
journalctl --vacuum-size=500M
```

### Вариант D: Временные файлы и архивы

```bash
# Старые резервные копии (оставить только последние 3)
ls -t /var/backups/*.tar | tail -n +4 | xargs rm -f

# Архивы бандлов переноса
find /tmp /opt -name "*.tar.gz" -mtime +7 -delete 2>/dev/null
```

---

## 3. Постоянное решение

Если место освобождено временно — запланировать:

```bash
# 1. Настроить политики хранения Harbor (если не настроены)
bash setup-harbor-retention.sh

# 2. Настроить ротацию журналов Docker
cat >> /etc/docker/daemon.json << 'EOF'
{
  "log-opts": {
    "max-size": "100m",
    "max-file": "5"
  }
}
EOF
systemctl restart docker

# 3. Добавить задание cron для регулярной очистки
echo "0 2 * * 0 /opt/scripts/harbor-gc.sh" >> /etc/crontab
```

---

## 4. Расширение диска (если освобождение невозможно)

```bash
# Шаг 1: определить том
lsblk

# Шаг 2: расширить (если LVM)
lvextend -L +50G /dev/vg0/data && resize2fs /dev/vg0/data

# Шаг 3: проверить
df -h
```

---

## 5. Критерий разрешения

- `df -h` показывает <80% на проблемном диске
- Оповещение `DiskSpaceCritical`/`DiskSpaceWarning` закрылось
- `predict_linear` в Grafana показывает >30 дней до исчерпания

---

## 6. Post-mortem

Зафиксировать:
- Что заняло место (журналы, образы, резервные копии)
- Как долго диск заполнялся (данные из Grafana)
- Какие политики хранения отсутствовали или не работали
