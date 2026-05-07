#!/usr/bin/env bash
# Установка CoreDNS из локального архива с базовым Corefile и systemd-юнитом
# Использование: bash install-coredns.sh [архив.tgz] [внутренняя_зона] [адрес_корп_dns]
set -euo pipefail

ARCHIVE="${1:-./coredns_*_linux_amd64.tgz}"
ZONE="${2:-internal.company.local}"
UPSTREAM_DNS="${3:-192.168.1.1}"
INSTALL_DIR="/usr/local/bin"
CONF_DIR="/etc/coredns"
ZONE_DIR="$CONF_DIR/zones"

echo "=== Установка CoreDNS ==="

archive=$(ls $ARCHIVE 2>/dev/null | head -1)
[ -f "$archive" ] || { echo "Архив не найден: $ARCHIVE"; exit 1; }

tar xzf "$archive" -C /tmp/
cp /tmp/coredns "$INSTALL_DIR/coredns"
chmod +x "$INSTALL_DIR/coredns"
echo "[OK] CoreDNS установлен: $INSTALL_DIR/coredns ($(coredns --version 2>/dev/null | head -1))"

mkdir -p "$ZONE_DIR"

# Corefile
cat > "$CONF_DIR/Corefile" << COREFILE
$ZONE:53 {
    file $ZONE_DIR/$ZONE
    log
    errors
}

.:53 {
    forward . $UPSTREAM_DNS
    cache 300
    log
    errors
}
COREFILE

# Zone file
cat > "$ZONE_DIR/$ZONE" << ZONEFILE
\$ORIGIN $ZONE.
\$TTL 300
@   IN SOA ns1 admin (
        $(date +%Y%m%d01) ; serial
        3600 900 604800 300 )
    IN NS  ns1
ns1         IN A $(hostname -I | awk '{print $1}')
harbor      IN A 192.168.1.20
vault       IN A 192.168.1.30
gitlab      IN A 192.168.1.40
ZONEFILE

# systemd unit
cat > /etc/systemd/system/coredns.service << UNIT
[Unit]
Description=CoreDNS DNS server
After=network.target

[Service]
ExecStart=$INSTALL_DIR/coredns -conf $CONF_DIR/Corefile
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now coredns
echo "[OK] CoreDNS запущен. Проверка: dig @127.0.0.1 harbor.$ZONE"
