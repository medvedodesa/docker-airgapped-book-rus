# Docker в закрытых контурах - Примеры кода и скрипты

Репозиторий содержит все практические примеры, скрипты и конфигурации из книги "Docker в закрытых контурах: Полный учебный курс".

## О книге

**Название:** Docker в закрытых контурах: Полный учебный курс  
**English:** Docker in Air-Gapped Environments: Complete Learning Path  
**Автор:** [Ваше имя]  
**Объём:** 625-685 страниц (RU) / 685-760 страниц (EN)  
**GitHub:** https://github.com/medvedodesa/docker-airgapped-book-rus

## Структура репозитория

```
docker-airgapped-book-rus/
├── module-01/          # Air-Gapped Infrastructure Essentials
│   ├── examples/       # Реальные кейсы (Банк, Завод, Энергосистема)
│   ├── scripts/        # Automation скрипты
│   └── architectures/  # Архитектурные диаграммы
├── module-02/          # Offline Docker Installation
│   ├── section-2.1/    # Offline Bundle Preparation (✓ READY)
│   ├── section-2.2/    # OS-specific Installation
│   ├── section-2.3/    # Docker Configuration
│   ├── section-2.4/    # Base Infrastructure
│   └── section-2.5/    # Automation
├── module-03/          # Harbor & Container Registry
├── module-04/          # Security Hardening
├── module-05/          # Zero Trust Architecture
├── module-06/          # Network Isolation
├── module-07/          # Secrets Management
├── module-08/          # CI/CD in Air-Gapped
├── module-09/          # Image Building Best Practices
├── module-10/          # Monitoring & Observability
├── module-11/          # Operations & Maintenance
└── module-12/          # Capstone Project
```

## MODULE 02, Section 2.1: Offline Bundle Preparation ✓

**Status:** COMPLETE  
**Location:** `module-02/section-2.1/`

### Скрипты (8 готовых к использованию):

1. **apt-download-from-manifest.sh** - Скачивание .deb пакетов (Ubuntu/Debian)
2. **dnf-download-from-manifest.sh** - Скачивание .rpm пакетов (RHEL/CentOS)
3. **verify-download.sh** - Проверка полноты скачивания
4. **verify-gpg.sh** - Проверка GPG подписей
5. **create-checksums.sh** - Создание SHA256 checksums
6. **verify-checksums.sh** - Проверка checksums
7. **generate-verification-report.sh** - Генерация отчёта верификации
8. **create-bundle.sh** - Создание финального bundle

### Примеры манифестов:

- **manifest-ubuntu.txt** - Для Ubuntu 22.04 LTS
- **manifest-rhel.txt** - Для RHEL 9 / Rocky Linux 9

### Быстрый старт:

```bash
# Для Ubuntu/Debian
sudo ./apt-download-from-manifest.sh manifest-ubuntu.txt
./verify-download.sh manifest-ubuntu.txt
./create-checksums.sh ./packages
./verify-checksums.sh ./packages
./generate-verification-report.sh ./packages
./create-bundle.sh docker-offline-v1.0

# Для RHEL/CentOS
sudo ./dnf-download-from-manifest.sh manifest-rhel.txt
# ... остальные шаги аналогично
```

Полная документация: [module-02/section-2.1/README.md](module-02/section-2.1/README.md)

## Скачать архив со скриптами

[**module-02-section-2.1-scripts.tar.gz**](module-02-section-2.1-scripts.tar.gz) (8.1 KB)

Содержит все 8 скриптов + манифесты + README

## Особенности скриптов

- **Production-ready:** Готовы к использованию без модификаций
- **Error handling:** Все скрипты с `set -euo pipefail`
- **Цветной вывод:** Green/Yellow/Red для удобства
- **Подробные логи:** Понятные сообщения об ошибках
- **Автоматизация:** Batch processing из manifest файлов

## Требования

**На машине с интернетом:**
- Ubuntu 22.04 / RHEL 9 (или совместимые)
- `apt-get` (Debian/Ubuntu) или `dnf` (RHEL/CentOS)
- `bash` 4.0+
- `sha256sum`, `tar`, `gzip`
- `gpg` (опционально, для подписей)
- `dpkg-sig` (опционально, для .deb проверки)

## Использование

### 1. Подготовка bundle (на машине с интернетом)

```bash
git clone https://github.com/medvedodesa/docker-airgapped-book-rus.git
cd docker-airgapped-book-rus/module-02/section-2.1

# Скачать пакеты
sudo ./apt-download-from-manifest.sh manifest-ubuntu.txt

# Проверить и упаковать
./verify-download.sh manifest-ubuntu.txt
./create-checksums.sh ./packages
./verify-checksums.sh ./packages
./create-bundle.sh docker-offline-v1.0
```

Результат: `docker-offline-v1.0.tar.gz` + `docker-offline-v1.0.tar.gz.sha256`

### 2. Перенос в air-gap

- USB drive (< 5 GB): Зашифрованный
- External HDD (5-50 GB): Рекомендуется
- DVD (4.7 GB): Legacy, но надёжно

### 3. Установка в air-gap

```bash
# Проверить checksum
sha256sum -c docker-offline-v1.0.tar.gz.sha256

# Распаковать
tar xzf docker-offline-v1.0.tar.gz
cd docker-offline-v1.0

# Проверить bundle
./scripts/verify-checksums.sh packages

# Установить (см. Module 2, Section 2.2)
# OS-specific инструкции в docs/INSTALL.md
```

## Лицензия

MIT License

Код из этого репозитория можно свободно использовать в коммерческих и некоммерческих проектах.

## Книга

Текст книги защищён авторским правом.

**Купить:**
- Amazon: [ссылка]
- ЛитРес: [ссылка]

## Contributing

Pull requests приветствуются!

Особенно интересны:
- Исправления багов в скриптах
- Поддержка дополнительных OS (SLES, Arch, etc.)
- Улучшения автоматизации
- Дополнительные примеры

## Поддержка

- **Issues:** https://github.com/medvedodesa/docker-airgapped-book-rus/issues
- **Discussions:** https://github.com/medvedodesa/docker-airgapped-book-rus/discussions
- **Email:** [ваш email]

## Roadmap

- [x] MODULE 02, Section 2.1: Offline Bundle Preparation
- [ ] MODULE 02, Section 2.2: OS-specific Installation
- [ ] MODULE 02, Section 2.3: Docker Configuration
- [ ] MODULE 02, Section 2.4: Base Infrastructure
- [ ] MODULE 02, Section 2.5: Automation
- [ ] MODULE 03: Harbor & Registry
- [ ] MODULE 04: Security Hardening
- [ ] ... (остальные модули)

## Благодарности

Спасибо всем, кто тестировал скрипты и давал feedback!

---

**Примеры обновляются по мере написания книги. Star репозиторий чтобы следить за обновлениями!**
