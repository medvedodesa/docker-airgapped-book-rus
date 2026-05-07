#!/usr/bin/env bash
# Установка Docker из статических бинарных файлов (нестандартные дистрибутивы).
# Использование: sudo bash install-docker-binary.sh [архив_docker.tgz]
set -euo pipefail

ARCHIVE="${1:-./docker*.tgz}"
INSTALL_DIR="/usr/local/bin"

echo "=== Установка Docker из статических бинарников ==="

# Найти архив
archive=$(ls $ARCHIVE 2>/dev/null | head -1)
[ -n "$archive" ] && [ -f "$archive" ] || { echo "Архив Docker не найден: $ARCHIVE"; exit 1; }
echo "  Архив: $archive"

# Распаковка
echo ""
echo "--- Распаковка ---"
tar xzf "$archive" -C /tmp/
docker_dir=$(ls -d /tmp/docker 2>/dev/null || ls -d /tmp/docker-* 2>/dev/null | head -1)
echo "  Распакован в $docker_dir"

# Копирование бинарников
echo ""
echo "--- Установка бинарников ---"
cp "$docker_dir"/docker* "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/docker*
echo "  Установлено в $INSTALL_DIR:"
ls "$INSTALL_DIR"/docker* | xargs -I{} basename {} | sort

# Создание группы docker
groupadd docker 2>/dev/null || true

# systemd-юниты
echo ""
echo "--- Создание systemd-юнитов ---"

cat > /etc/systemd/system/containerd.service << 'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/docker.service << 'EOF'
[Unit]
Description=Docker Application Container Engine
Documentation=https://docs.docker.com
After=network-online.target containerd.service
Wants=network-online.target
Requires=docker.socket containerd.service

[Service]
Type=notify
ExecStart=/usr/local/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock
ExecReload=/bin/kill -s HUP $MAINPID
TimeoutStartSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/docker.socket << 'EOF'
[Unit]
Description=Docker Socket for the API

[Socket]
ListenStream=/var/run/docker.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

systemctl daemon-reload
systemctl start containerd
systemctl enable containerd
systemctl start docker
systemctl enable docker

docker version && echo "" && echo "[OK] Docker установлен из бинарников и запущен"
rm -rf "$docker_dir"
