#!/usr/bin/env bash
# Генерация инвентаря ИС для материалов аттестации
# Использование: bash generate-system-inventory.sh [output_dir]
set -euo pipefail

OUTPUT_DIR="${1:-/opt/attestation/inventory}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
INVENTORY_FILE="$OUTPUT_DIR/system-inventory-$TIMESTAMP.txt"

mkdir -p "$OUTPUT_DIR"

{
echo "================================================================"
echo "  ИНВЕНТАРЬ ИНФОРМАЦИОННОЙ СИСТЕМЫ"
echo "  Дата формирования: $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Хост: $(hostname)"
echo "================================================================"

echo ""
echo "1. ОПЕРАЦИОННАЯ СИСТЕМА"
echo "   $(uname -o) $(uname -r)"
lsb_release -d 2>/dev/null | sed 's/Description:\s*/   Дистрибутив: /' || \
  cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '"' | sed 's/^/   /'

echo ""
echo "2. АППАРАТНОЕ ОБЕСПЕЧЕНИЕ"
echo "   CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs)"
echo "   Ядер: $(nproc)"
echo "   RAM: $(free -h | awk '/^Mem/{print $2}')"
echo "   Диски:"
lsblk -d -o NAME,SIZE,MODEL 2>/dev/null | grep -v loop | sed 's/^/     /'

echo ""
echo "3. СЕТЕВЫЕ ИНТЕРФЕЙСЫ"
ip -o addr show 2>/dev/null | awk '{print "   "$2": "$4}' | grep -v "127.0.0.1\|::1"

echo ""
echo "4. DOCKER"
docker version --format "   Client: {{.Client.Version}}\n   Server: {{.Server.Version}}" 2>/dev/null || \
  echo "   Docker недоступен"
echo "   Storage driver: $(docker info --format '{{.Driver}}' 2>/dev/null)"
echo "   Cgroup driver: $(docker info --format '{{.CgroupDriver}}' 2>/dev/null)"

echo ""
echo "5. ЗАПУЩЕННЫЕ КОНТЕЙНЕРЫ"
docker ps --format "   {{.Names}}\t{{.Image}}\t{{.Status}}" 2>/dev/null | head -20

echo ""
echo "6. DOCKER ОБРАЗЫ"
docker images --format "   {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" 2>/dev/null | head -30

echo ""
echo "7. УСТАНОВЛЕННОЕ ПО (ключевые компоненты)"
for pkg in docker vault gitlab-ce gitlab-runner harbor trivy cosign falco auditd aide cryptopro; do
  ver=$(dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' || \
        rpm -q "$pkg" 2>/dev/null | grep -v "not installed" || \
        command -v "$pkg" &>/dev/null && echo "(бинарный)" || echo "не установлен")
  echo "   $pkg: $ver"
done

echo ""
echo "8. ПОРТЫ (прослушивание)"
ss -tlnp 2>/dev/null | grep LISTEN | awk '{print "   "$4"\t"$6}' | sort

echo ""
echo "9. СЕРТИФИКАТЫ TLS"
for cert_dir in /etc/ssl/certs /etc/harbor/ssl /etc/vault.d/tls /etc/docker/certs.d; do
  [ -d "$cert_dir" ] || continue
  while IFS= read -r cert; do
    subj=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/subject=//' | xargs)
    exp=$(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)
    echo "   $(basename $cert): $subj | до $exp"
  done < <(find "$cert_dir" -name "*.crt" -o -name "*.pem" 2>/dev/null | head -10)
done

echo ""
echo "================================================================"
echo "  Конец инвентаря"
echo "================================================================"
} | tee "$INVENTORY_FILE"

echo ""
echo "Инвентарь сохранён: $INVENTORY_FILE"
