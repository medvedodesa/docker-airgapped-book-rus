# Docker в закрытых контурах — скрипты

Скрипты к книге **«Docker в закрытых контурах: установка, безопасность и аттестация в изолированных средах»**.

Каждый скрипт привязан к конкретному разделу. Структура директорий точно повторяет нумерацию модулей и разделов книги.

---

## Использование

Все скрипты написаны на `bash 4+`, тестировались на Ubuntu 22.04 и Astra Linux SE 1.7.

```bash
bash <имя-скрипта>.sh
```

Большинство скриптов выводят результат в формате `[PASS]` / `[WARN]` / `[FAIL]` и возвращают код выхода `1` при критических ошибках, что позволяет использовать их в конвейерах CI/CD.

---

## Структура

### Модуль 1 — Основы инфраструктуры закрытого контура

**section-1.1** — Что такое изолированная среда
- `check-isolation.sh` — проверка отсутствия маршрутов к внешним сетям и активных внешних соединений
- `check-vlan-vs-airgap.sh` — анализ сетевой конфигурации: признаки VLAN-изоляции вместо физической

**section-1.2** — Архитектура изолированных контейнерных сред
- `check-network-isolation.sh` — проверка фактической изоляции хоста от внешних сетей
- `infrastructure-assessment.sh` — оценка готовности инфраструктуры по контрольному списку
- `prepare-initial-bundle.sh` — подготовка и валидация первоначального пакета для переноса

**section-1.3** — Планирование инфраструктуры
- `storage-calculator.sh` — расчёт требуемого объёма хранилища для всех компонентов
- `check-ip-conflicts.sh` — проверка пересечений IP-диапазонов Docker с существующими маршрутами
- `check-ntp-sync.sh` — проверка синхронизации времени; критерий расхождения ≤ 1 с

**section-1.4** — Подготовка к развёртыванию
- `system-readiness-check.sh` — комплексная проверка совместимости хоста с Docker
- `prepare-transfer-bundle.sh` — сборка передаточного пакета на машине с интернетом
- `verify-bundle.sh` — проверка целостности принятого пакета по SHA-256
- `save-environment-snapshot.sh` — документирование версий всех установленных компонентов
- `sysctl-docker.conf` — готовый конфигурационный файл параметров ядра

---

### Модуль 2 — Офлайн-установка Docker

**section-2.1** — Подготовка к установке
- `download-docker-offline.sh` — загрузка Docker с зависимостями на машине с интернетом
- `verify-bundle.sh` — проверка SHA-256 установочного пакета
- `check-version-compatibility.sh` — проверка совместимости версий компонентов и дистрибутивов

**section-2.2** — Установка Docker
- `install-docker-deb.sh` — установка на Ubuntu/Debian в правильном порядке зависимостей
- `install-docker-rpm.sh` — установка на RHEL/Rocky Linux/РедОС с проверкой SELinux
- `install-docker-astra.sh` — установка на Astra Linux SE с учётом политик Parsec
- `install-docker-binary.sh` — установка из статических бинарников без пакетного менеджера
- `verify-installation.sh` — комплексная верификация установки

**section-2.3** — Настройка Docker daemon
- `daemon.json` — готовый production-конфиг с журналированием, лимитами и безопасными параметрами
- `apply-daemon-config.sh` — применение конфигурации с валидацией и проверкой после перезапуска
- `check-daemon-config.sh` — проверка текущей конфигурации daemon на соответствие требованиям

**section-2.4** — Перенос образов в закрытый контур
- `export-images.sh` — сохранение образов группами с оптимизацией общих слоёв
- `import-images.sh` — загрузка образов в Harbor в закрытом контуре
- `image-inventory.sh` — инвентаризация образов с тегами и датами
- `sync-images-skopeo.sh` — синхронизация через Skopeo без промежуточного хранения

**section-2.5** — Обновление Docker Engine
- `update-docker-rolling.sh` — последовательное обновление хостов с выводом из нагрузки и откатом
- `check-version-compatibility.sh` — проверка совместимости версий перед обновлением

---

### Модуль 3 — Harbor: реестр образов

**section-3.1** — Реестр образов в закрытом контуре
- `harbor-requirements-check.sh` — проверка соответствия хоста требованиям Harbor
- `harbor-health-check.sh` — проверка состояния всех компонентов Harbor через API
- `harbor-metrics-setup.sh` — настройка сбора метрик в Prometheus
- `harbor-storage-report.sh` — отчёт об использовании хранилища blob storage
- `backup-all.sh` — резервное копирование PostgreSQL и blob storage с контрольными суммами

**section-3.2** — Установка Harbor в закрытом контуре
- `download-harbor-offline.sh` — загрузка офлайн-установщика с проверкой GPG и SHA-256
- `generate-harbor-certs.sh` — создание временного TLS-сертификата (до подключения Vault PKI)
- `install-harbor.sh` — установка Harbor с проверкой предварительных требований
- `verify-harbor-install.sh` — комплексная верификация установки
- `configure-docker-for-harbor.sh` — настройка Docker-хостов: CA, проверка соединения
- `configure-harbor-ha.sh` — настройка конфигурации active-standby из двух экземпляров

**section-3.3** — Конфигурация: проекты, RBAC и политики
- `setup-harbor-projects.sh` — создание проектов и ролевой модели через Harbor API
- `create-robot-account.sh` — создание Robot Account с минимальными привилегиями
- `check-robot-account-activity.sh` — проверка активности и сроков действия Robot Accounts
- `configure-scanning-policy.sh` — настройка политик автоматического сканирования
- `audit-harbor-access.sh` — аудит прав доступа: роли пользователей и Robot Accounts

**section-3.4** — Репликация между экземплярами
- `setup-replication.sh` — создание политик репликации между экземплярами Harbor
- `check-replication-status.sh` — мониторинг статуса заданий репликации
- `replication-audit-report.sh` — отчёт по истории репликации для аудита

**section-3.5** — Интеграция с LDAP и Active Directory
- `configure-harbor-ldap.sh` — настройка LDAP-аутентификации
- `test-harbor-ldap-login.sh` — тест входа через LDAP
- `sync-ldap-groups.sh` — синхронизация групп из AD с ролями проектов Harbor
- `revoke-user-access.sh` — отзыв доступа пользователя

---

### Модуль 4 — Безопасность контейнеров

**section-4.1** — Модель угроз и принципы безопасности
- `security-audit.sh` — аудит безопасности хоста: SELinux, Docker socket, привилегированные контейнеры
- `audit-containers.sh` — детальная проверка каждого контейнера на соответствие политике
- `selinux-status-check.sh` — проверка статуса SELinux/AppArmor и оповещение при отклонениях
- `save-environment-snapshot.sh` — снимок конфигурации безопасности для сравнения в аудите

**section-4.2** — Усиление контейнеров
- `check-container-hardening.sh` — проверка запущенных контейнеров на избыточные привилегии
- `docker-bench-offline.sh` — запуск CIS Docker Benchmark из локального Harbor-образа
- `lint-dockerfile.sh` — статический анализ Dockerfile через Hadolint

**section-4.3** — Подпись образов
- `setup-cosign-vault.sh` — настройка Cosign с ключами из Vault Transit
- `sign-image-cosign.sh` — подпись образа и публикация подписи в Harbor
- `verify-signatures.sh` — проверка подписей для всех production-образов

**section-4.4** — Сканирование уязвимостей
- `update-trivy-db.sh` — обновление базы уязвимостей Trivy для закрытого контура
- `scan-image.sh` — сканирование образа с выводом по уровням критичности
- `setup-trivy-pipeline.sh` — интеграция Trivy в конвейер CI/CD

---

### Модуль 5 — Zero Trust

**section-5.1** — Основы Zero Trust
- `zero-trust-assessment.sh` — оценка текущего состояния по принципам нулевого доверия
- `zero-trust-maturity-report.sh` — отчёт об уровне зрелости Zero Trust

**section-5.2** — Идентификация нагрузок: SPIFFE и SPIRE
- `install-spire-offline.sh` — установка SPIRE Server и Agent без доступа в интернет
- `register-workload.sh` — регистрация нагрузки и настройка атрибутов аттестации
- `verify-svid.sh` — проверка SVID: срок действия, SPIFFE ID, цепочка сертификатов

**section-5.3** — mTLS: взаимная аутентификация между сервисами
- `test-mtls-connection.sh` — тест mTLS-соединения между двумя сервисами
- `diagnose-mtls.sh` — диагностика ошибок handshake
- `mtls-coverage-report.sh` — отчёт о покрытии mTLS по всем сервисам
- `docker-compose.mtls-example.yml` — пример конфигурации Compose с mTLS
- `pg_hba.conf` — конфигурация PostgreSQL для mTLS с сертификатами клиента

**section-5.4** — Непрерывная верификация: Falco и auditd
- `install-falco-offline.sh` — установка Falco без доступа в интернет
- `configure-auditd-docker.sh` — настройка auditd для отслеживания Docker-событий
- `falco-alert-handler.sh` — обработчик оповещений Falco с маршрутизацией инцидентов
- `falco-docker-rules.yaml` — правила Falco для Docker-инфраструктуры

**section-5.5** — Сквозной сценарий: payment-api → postgres
- `verify-zero-trust.sh` — верификация полного сценария Zero Trust
- `docker-compose.payment-api.yml` — конфигурация сервисов payment-api и postgres с mTLS
- `falco-payment-rules.yaml` — правила Falco для мониторинга платёжных сервисов
- `pg_hba.conf`, `pg_ident.conf`, `postgresql.conf` — конфигурация PostgreSQL для сценария

---

### Модуль 6 — Сетевая изоляция

**section-6.1** — Сетевая модель Docker
- `create-internal-network.sh` — создание изолированных internal-сетей с заданными параметрами
- `inspect-networks.sh` — детальный осмотр сетей: подсети, контейнеры, драйверы
- `test-network-isolation.sh` — проверка отсутствия связности между изолированными сетями

**section-6.2** — DNS без выхода в интернет
- `install-coredns.sh` — установка и настройка CoreDNS как внутреннего резолвера
- `check-dns-config.sh` — проверка конфигурации DNS: резолверы, поиск, доступность имён

**section-6.3** — Сегментация трафика
- `save-iptables-rules.sh` — сохранение текущих правил iptables для аудита и восстановления
- `audit-network-connectivity.sh` — аудит связности между контейнерами и подсетями

**section-6.4** — TLS внутри периметра
- `create-internal-ca.sh` — создание внутреннего удостоверяющего центра
- `issue-service-cert.sh` — выпуск сертификата для сервиса с заданными SAN
- `check-cert-expiry.sh` — проверка сроков действия всех сертификатов с оповещением

**section-6.5** — Мониторинг сетевых соединений
- `network-audit.sh` — полный аудит сетевой конфигурации Docker
- `show-container-connections.sh` — активные соединения конкретного контейнера
- `watch-docker-events.sh` — подписка на события Docker с фильтрацией сетевых событий

---

### Модуль 7 — Vault: управление секретами

**section-7.1** — Архитектура Vault
- `vault-architecture-check.sh` — проверка конфигурации и статуса кластера Vault
- `audit-secrets-exposure.sh` — поиск секретов в переменных окружения контейнеров

**section-7.2** — Развёртывание в закрытом контуре
- `install-vault-offline.sh` — установка Vault без доступа в интернет
- `setup-vault-systemd.sh` — создание systemd-юнита и настройка автозапуска
- `init-vault-cluster.sh` — первичная инициализация кластера с сохранением ключей Shamir
- `vault-backup.sh` — резервное копирование Raft-снимка

**section-7.3** — PKI: Vault как центр сертификации
- `setup-pki-hierarchy.sh` — создание двухуровневой PKI: root CA и intermediate CA
- `issue-service-cert-vault.sh` — выпуск сертификата для сервиса через Vault PKI
- `setup-vault-agent-tls.sh` — настройка Vault Agent для автоматического обновления сертификатов
- `check-crl-distribution.sh` — проверка доступности CRL в закрытом контуре

**section-7.4** — KV-механизм: статические секреты
- `setup-kv-structure.sh` — создание иерархии путей KV v2 с политиками
- `rotate-static-secret.sh` — ротация статического секрета с уведомлением сервисов
- `vault-agent-sidecar.sh` — запуск Vault Agent как sidecar-контейнера
- `audit-secret-access.sh` — анализ журнала аудита Vault: кто и когда обращался к секретам

**section-7.5** — Динамические секреты
- `setup-database-engine.sh` — настройка динамических учётных данных для PostgreSQL
- `setup-ssh-engine.sh` — настройка временного доступа к хостам через SSH engine
- `list-active-leases.sh` — список активных аренд с временем истечения
- `revoke-lease.sh` — немедленный отзыв аренды динамического секрета

**section-7.6** — Аутентификация и авторизация
- `setup-approle.sh` — настройка AppRole для аутентификации сервисов
- `generate-secret-id.sh` — генерация Secret ID с ограничениями использования
- `setup-ldap-auth.sh` — настройка LDAP-аутентификации для администраторов
- `generate-root-token.sh` — аварийная процедура генерации корневого токена

---

### Модуль 8 — CI/CD в изолированной среде

**section-8.1** — GitLab CE
- `install-gitlab-offline.sh` — установка GitLab CE без доступа в интернет
- `configure-gitlab-airgap.sh` — настройка GitLab для работы в закрытом контуре
- `register-gitlab-runner.sh` — регистрация и настройка GitLab Runner
- `gitlab-backup.sh` — резервное копирование GitLab с проверкой наличия secrets

**section-8.2** — Альтернативные платформы
- `install-teamcity-offline.sh` — установка TeamCity без доступа в интернет
- `install-jenkins-offline.sh` — установка Jenkins с офлайн-плагинами
- `install-gitea-woodpecker.sh` — установка связки Gitea + Woodpecker CI

**section-8.3** — Безопасность конвейеров
- `configure-runner-security.sh` — настройка безопасной конфигурации Runner
- `audit-pipeline-access.sh` — аудит доступа к конвейерам и переменным окружения
- `setup-trivy-pipeline.sh` — интеграция сканирования Trivy в конвейер

**section-8.4** — Интеграция с Harbor и Vault
- `setup-vault-approle-ci.sh` — настройка AppRole для конвейера CI/CD
- `setup-nexus-mirrors.sh` — зеркала пакетных менеджеров в Nexus для сборки
- `sign-image-cosign.sh` — подпись образа в конвейере после успешной сборки

**section-8.5** — Управление артефактами
- `install-nexus-offline.sh` — установка Nexus Repository Manager без интернета
- `configure-build-cache.sh` — настройка кеша сборки в закрытом контуре
- `setup-harbor-retention.sh` — политики хранения образов и автоматическая очистка

**section-8.6** — Автоматизация развёртывания
- `blue-green-deploy.sh` — переключение между blue и green окружениями
- `rolling-update.sh` — последовательное обновление сервисов без остановки
- `deploy-with-vault.sh` — развёртывание с получением секретов из Vault в runtime

---

### Модуль 9 — Сборка образов

**section-9.1** — Стратегия базовых образов
- `inventory-base-images.sh` — инвентаризация базовых образов в Harbor с версиями
- `transfer-base-image.sh` — перенос базового образа через шлюзовую зону
- `update-base-image.sh` — обновление базового образа и запуск пересборки зависимых

**section-9.2** — Dockerfile для изолированной среды
- `build-with-secrets.sh` — сборка с секретами через BuildKit без сохранения в слоях
- `lint-dockerfile.sh` — статический анализ через Hadolint с корпоративными правилами

**section-9.3** — Многоэтапная сборка
- `compare-image-sizes.sh` — сравнение размеров образов до и после оптимизации
- `Dockerfile.java-multistage` — пример многоэтапной сборки для Java-приложения
- `Dockerfile.go-scratch` — сборка Go-приложения в образ scratch

**section-9.4** — Минимальные базовые образы
- `transfer-distroless-images.sh` — перенос distroless-образов Google в закрытый контур
- `Dockerfile.distroless-java` — пример для Java на базе distroless
- `Dockerfile.distroless-python` — пример для Python на базе distroless

**section-9.5** — Сборка без Docker daemon
- `build-with-kaniko.sh` — сборка образов через Kaniko внутри контейнера без привилегий
- `setup-buildah-runner.sh` — настройка Buildah в GitLab Runner для rootless-сборки
- `sync-images-skopeo.sh` — синхронизация набора образов через Skopeo без загрузки

---

### Модуль 10 — Мониторинг

**section-10.1** — Стек мониторинга
- `deploy-monitoring-stack.sh` — развёртывание Prometheus + Grafana + Loki через Compose
- `transfer-monitoring-images.sh` — перенос образов стека мониторинга в Harbor

**section-10.2** — Сбор метрик
- `deploy-exporters.sh` — развёртывание node_exporter и cAdvisor на всех хостах
- `add-service-target.sh` — добавление нового сервиса в конфигурацию Prometheus

**section-10.3** — Правила оповещений
- `create-silence.sh` — создание подавления в Alertmanager на период обслуживания
- `alerting-rules-base.yml` — базовые правила оповещений для Docker-инфраструктуры
- `alertmanager-config.yml` — конфигурация Alertmanager с маршрутизацией

**section-10.4** — Grafana
- `setup-grafana-provisioning.sh` — настройка Provisioning: источники данных и дашборды как код
- `dashboards/docker-hosts.json` — дашборд метрик хостов Docker
- `dashboards/harbor-registry.json` — дашборд Harbor: blob storage, запросы, репликация
- `dashboards/vault-status.json` — дашборд статуса Vault: аренды, аутентификации, задержки

**section-10.5** — Агрегация журналов: Loki и Promtail
- `deploy-loki-promtail.sh` — развёртывание Loki и Promtail через Compose
- `configure-log-retention.sh` — настройка ротации и хранения журналов
- `logql-examples.md` — примеры LogQL-запросов для типовых сценариев диагностики

---

### Модуль 11 — Операции и обслуживание

**section-11.1** — Резервное копирование
- `backup-all.sh` — комплексное резервное копирование всей инфраструктуры
- `restore-postgres.sh` — восстановление PostgreSQL из резервной копии
- `test-backup-restore.sh` — автоматизированный тест цикла резервного копирования и восстановления

**section-11.2** — Процедуры обновления
- `update-system-packages.sh` — обновление пакетов ОС из офлайн-репозитория
- `update-docker-rolling.sh` — последовательное обновление Docker на хостах
- `gitlab-upgrade-path.sh` — проверка корректности пути обновления GitLab по версиям

**section-11.3** — Планирование ёмкости
- `capacity-report.sh` — отчёт о текущем использовании ресурсов по всем компонентам
- `harbor-gc.sh` — сборка мусора в Harbor: удаление неиспользуемых blob-объектов
- `capacity-dashboard.json` — дашборд Grafana для прогнозирования ёмкости

**section-11.4** — Реагирование на инциденты
- `incident-report-template.md` — шаблон отчёта об инциденте (post-mortem)
- `runbooks/disk-full.md` — runbook: диск на Harbor заполнен
- `runbooks/harbor-unavailable.md` — runbook: Harbor недоступен
- `runbooks/vault-sealed.md` — runbook: Vault запечатан

**section-11.5** — Аварийное восстановление
- `dr-test.sh` — автоматизированный тест плана аварийного восстановления
- `full-restore-procedure.sh` — полная процедура восстановления инфраструктуры с нуля
- `dr-plan-template.md` — шаблон плана аварийного восстановления

**section-11.6** — Ежедневные операции
- `morning-check.sh` — утренняя проверка состояния всей инфраструктуры
- `harbor-maintenance.sh` — плановое обслуживание Harbor: GC, проверка репликации, отчёты
- `check-cert-expiry.sh` — мониторинг сроков действия TLS-сертификатов
- `checklists/harbor-upgrade.md` — чек-лист обновления Harbor
- `checklists/gitlab-upgrade.md` — чек-лист обновления GitLab
- `checklists/rotate-keys.md` — чек-лист ротации ключей и сертификатов
- `checklists/transfer-new-image.md` — чек-лист переноса нового образа в закрытый контур

---

### Модуль 12 — Российская регуляторика и аттестация

**section-12.1** — КИИ и ФСТЭК
- `kii-category-checklist.sh` — определение категории значимости КИИ по 187-ФЗ
- `compliance-check.sh` — проверка соответствия требованиям Приказа ФСТЭК №239
- `gis-readiness-check.sh` — проверка готовности к аттестации по Приказу ФСТЭК №17 (ГИС)
- `compliance-matrix.md` — матрица соответствия: меры ФСТЭК и главы книги

**section-12.2** — ГОСТ-криптография в Docker
- `check-gost-requirements.sh` — проверка необходимости сертифицированной ГОСТ-криптографии
- `cryptopro-container-test.sh` — тест работы КриптоПро CSP внутри контейнера
- `setup-stunnel-gost.sh` — настройка stunnel с ГОСТ-шифрами через КриптоПро
- `Dockerfile.cryptopro` — пример образа с КриптоПро CSP
- `Dockerfile.nginx-gost` — пример образа Nginx с ГОСТ-TLS

**section-12.3** — Аттестация и поддержание соответствия
- `pre-attestation-checklist.sh` — предаттестационная проверка за 30 дней до испытаний
- `generate-system-inventory.sh` — генерация технического паспорта из текущего состояния системы
- `inventory-installed-components.sh` — полная инвентаризация компонентов для документации
- `attestation-docs-package.sh` — автоматическая сборка пакета аттестационной документации
- `check-trivy-db-age.sh` — проверка актуальности базы Trivy (критерий ≤ 30 дней)
- `change-impact-assessment.md` — шаблон оценки влияния изменений на аттестат

**section-12.4** — ГосСОПКА, НКЦКИ и реагирование на инциденты
- `gossopka-readiness-check.sh` — проверка готовности к подключению к ГосСОПКА
- `setup-gossopka-integration.sh` — настройка технической интеграции с ГосСОПКА
- `incident-response-checklist.sh` — чек-лист реагирования на инцидент по 187-ФЗ
- `collect-forensics.sh` — сбор криминалистических артефактов Docker-контейнеров
- `incident-report-nkci.md` — шаблон уведомления НКЦКИ об инциденте

---

## Лицензия

MIT License

Copyright (c) 2026 Михаил Шмаров

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
