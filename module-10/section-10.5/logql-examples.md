# LogQL: практические запросы для Docker-инфраструктуры в закрытом контуре

Сборник LogQL-запросов для ежедневной работы в Grafana Explore и для создания правил оповещений.
Все запросы протестированы с Loki 3.x и Promtail, собирающим журналы Docker-контейнеров.

---

## Базовые фильтры

### Все журналы конкретного контейнера
```
{container_name="harbor-core"}
```

### Журналы по имени образа
```
{image_name=~"prom/.*"}
```

### Все журналы со всех хостов за последний час
```
{job=~".+"}
```

### Журналы только с конкретного хоста
```
{hostname="server01.internal.company.local"}
```

---

## Фильтрация по содержимому

### Только ошибки (case-insensitive)
```
{container_name=~".+"} |= "error" or "ERROR" or "Error"
```

### Исключить шумные строки healthcheck
```
{container_name="nginx"} != "GET /health" != "200"
```

### Регулярное выражение: HTTP 5xx ответы
```
{container_name=~"api|backend"} |~ `HTTP/[12]\.[01]" 5\d\d`
```

### Только строки с трассировкой стека Java
```
{container_name=~".+"} |~ "Exception|Error" |~ "at com\\.company"
```

---

## Парсинг структурированных журналов

### JSON-журналы: фильтр по уровню
```
{container_name="api"} | json | level="error"
```

### JSON-журналы: конкретный код ошибки
```
{container_name="api"} | json | error_code="DB_CONNECTION_FAILED"
```

### Logfmt: извлечение полей
```
{container_name="vault"} | logfmt | operation="read" | path=~"secret/prod/.*"
```

### Nginx access log: медленные запросы (>1с)
```
{container_name="nginx"} 
  | regexp `(?P<method>\w+) (?P<path>[^ ]+) [^ ]+ (?P<status>\d+) \d+ (?P<duration>[0-9.]+)`
  | duration > 1s
```

---

## Метрики из журналов (LogQL metric queries)

### Частота ошибок по контейнерам
```
sum by (container_name) (
  rate({job="docker"}[5m] |= "error")
)
```

### Число HTTP 5xx за период
```
sum(count_over_time({container_name="nginx"} |~ "\" 5\d\d "[5m]))
```

### Топ-5 контейнеров по объёму журналов
```
topk(5,
  sum by (container_name) (
    rate({job="docker"}[10m])
  )
)
```

### Скорость записи в журнал (байт/сек)
```
sum by (hostname) (
  bytes_rate({job="docker"}[5m])
)
```

---

## Аудит безопасности

### Все события аудита Vault
```
{job="vault"} | json | type="request"
```

### Неудачные аутентификации в Vault
```
{job="vault"} | json | type="response" | error != ""
```

### Обращения к секретам продакшена
```
{job="vault"} | json | path=~"secret/prod/.*" | type="request"
```

### Подозрительные exec в контейнерах (Falco)
```
{job="falco"} |= "exec_in_container" | json | priority="WARNING" or priority="CRITICAL"
```

### Изменения конфигурации GitLab CI
```
{job="gitlab"} |= "audit" |= "pipeline" |= "variable"
```

### Неудачные входы в Harbor
```
{container_name="harbor-core"} |= "401" |= "Unauthorized"
```

---

## Реагирование на инциденты

### Все события вокруг инцидента (±5 минут от времени T)
```
{job=~".+"} 
  | line_format "{{.container_name}}: {{.line}}"
```
Установите в Grafana: временной диапазон → конкретный момент инцидента ±5 мин.

### Журналы конкретного сервиса при OOM Kill
```
{container_name="api"} |= "killed" or "OOMKilled" or "out of memory"
```

### Последние 100 строк после сбоя контейнера
```
{container_name="harbor-db"} |= "FATAL" or "panic" or "Segmentation fault"
```

### Корреляция: метрики Prometheus + журналы (Loki)
В Grafana используйте Mixed datasource:
- Panel 1: `rate(container_cpu_usage_seconds_total{name="api"}[5m])` → Prometheus
- Panel 2: `{container_name="api"} | json | level="error"` → Loki
- Linked time range для корреляции

---

## Операционный мониторинг

### Ошибки конвейеров GitLab за сутки
```
count_over_time({job="gitlab-runner"} |= "ERROR" [24h])
```

### Harbor: ошибки репликации
```
{container_name="harbor-jobservice"} |= "replication" |= "failed" or "error"
```

### Истекающие сертификаты (из журналов приложений)
```
{job="docker"} |= "certificate" |= "expire" or "expir"
```

### Медленные запросы к Vault (из журнала аудита)
```
{job="vault"} | json | type="response" | duration > 500
```

---

## Алерты на основе LogQL

Добавьте в Grafana Alerting (Loki datasource):

### Критические ошибки в продакшене (>5 за 5 мин)
```
sum(count_over_time({container_name=~"api|backend"} |= "CRITICAL" [5m])) > 5
```

### Falco: попытка выхода из контейнера
```
count_over_time({job="falco"} |= "container_escape" [1m]) > 0
```

### Vault audit: обращение к секрету вне рабочего времени
```
count_over_time({job="vault"} | json | path=~"secret/prod/.*" [1m]) > 0
```

---

## Полезные команды Loki API

```bash
# Последние 50 строк контейнера
curl -G "http://loki.internal:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={container_name="api"}' \
  --data-urlencode 'limit=50' \
  --data-urlencode "start=$(date -d '5 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date +%s)000000000" | python3 -m json.tool

# Проверка объёма журналов за сутки
curl -G "http://loki.internal:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum(bytes_over_time({job="docker"}[24h]))' | python3 -m json.tool

# Список активных потоков журналов
curl -G "http://loki.internal:3100/loki/api/v1/labels" | python3 -m json.tool
```
