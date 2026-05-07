#!/usr/bin/env bash
# Расчёт требуемого объёма хранилища для Docker-инфраструктуры
set -euo pipefail

echo "=== Калькулятор хранилища Docker-инфраструктуры ==="
echo ""

# Параметры — переопределяются аргументами или оставляются дефолтные
IMAGE_COUNT="${1:-150}"        # количество уникальных образов
AVG_IMAGE_SIZE_MB="${2:-600}"  # средний размер образа в МБ
VERSIONS_PER_IMAGE="${3:-10}"  # версий на образ
YEARS="${4:-3}"                # планируемый горизонт

echo "Параметры:"
echo "  Уникальных образов:      $IMAGE_COUNT"
echo "  Средний размер образа:   ${AVG_IMAGE_SIZE_MB} МБ"
echo "  Версий на образ:         $VERSIONS_PER_IMAGE"
echo "  Горизонт планирования:   $YEARS лет"
echo ""

# Harbor blob storage
harbor_min=$(( IMAGE_COUNT * AVG_IMAGE_SIZE_MB * VERSIONS_PER_IMAGE * 15 / 10000 ))  # ГБ, коэф 1.5
harbor_plan=$(( harbor_min * 2 * YEARS ))
echo "--- Harbor (blob storage) ---"
echo "  Минимум сейчас:  $harbor_min ГБ"
echo "  Планировать:     $harbor_plan ГБ (с запасом на $YEARS года)"
echo ""

# Harbor PostgreSQL (метаданные)
harbor_pg=20
echo "--- Harbor (PostgreSQL) ---"
echo "  Метаданные:      ~$harbor_pg ГБ"
echo ""

# GitLab
gitlab_min=100
gitlab_plan=$(( gitlab_min * YEARS ))
echo "--- GitLab ---"
echo "  Репозитории:     $gitlab_min ГБ (базовый)"
echo "  Планировать:     $gitlab_plan ГБ"
echo ""

# Vault Raft
vault_gb=5
echo "--- Vault ---"
echo "  Данные Raft:     ~$vault_gb ГБ (плюс резерв)"
echo ""

# Хосты Docker
echo "--- Хосты Docker (/var/lib/docker) ---"
echo "  На хост (примерно):  $((AVG_IMAGE_SIZE_MB * 20 / 1024 + 20)) ГБ (20 образов + тома)"
echo ""

# Резервные копии (14 дней)
echo "--- Резервные копии (14 дней) ---"
backup_daily=$(( harbor_min / 10 + 15 + vault_gb ))  # ГБ/день
backup_total=$(( backup_daily * 14 ))
echo "  В день:          ~$backup_daily ГБ"
echo "  За 14 дней:      ~$backup_total ГБ"
echo ""

# Итог
total=$(( harbor_plan + harbor_pg + gitlab_plan + vault_gb + backup_total ))
echo "=== ИТОГО ПЛАНИРОВАТЬ ==="
echo "  Harbor:          $harbor_plan ГБ"
echo "  GitLab:          $gitlab_plan ГБ"
echo "  Vault:           $vault_gb ГБ"
echo "  Резервные копии: $backup_total ГБ"
echo "  ─────────────────────────"
echo "  ВСЕГО:           $total ГБ"
echo ""
echo "Использование: $0 <образов> <размер_МБ> <версий> <лет>"
