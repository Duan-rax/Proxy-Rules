#!/bin/bash

# 1. 停止冲突服务 & 安装依赖
echo "📦 正在准备环境..."
systemctl stop shadowsocks-rust 2>/dev/null
systemctl disable shadowsocks-rust 2>/dev/null
docker stop ss-rust xray_reality 2>/dev/null
apt-get update && apt-get install -y wget curl tar xz-utils openssl ca-certificates

# 2. 获取架构并下载最新版 Shadowsocks-Rust
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    target="x86_64-unknown-linux-gnu"
elif [[ "$ARCH" == "aarch64" ]]; then
    target="aarch64-unknown-linux-gnu"
else
    echo "不支持的架构: $ARCH"
    exit 1
fi

echo "⬇️ 正在获取最新版本..."
LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${target}.tar.xz"

echo "⬇️ 下载中: $LATEST_VER"
wget -qO ss-rust.tar.xz "$DOWNLOAD_URL"
tar -xf ss-rust.tar.xz
mv ssserver /usr/local/bin/
chmod +x /usr/local/bin/ssserver
rm ss-rust.tar.xz sslocal ssurl ssmanager ssmanager-systemd-notify 2>/dev/null

# 3. 生成配置
echo "⚙️ 生成配置文件..."
SS_PASSWORD=$(openssl rand -base64 16)
SS_PORT=443
SS_METHOD="aes-256-gcm"
mkdir -p /etc/shadowsocks-rust

cat > /etc/shadowsocks-rust/config.json <<EOF
{
    "server": "0.0.0.0",
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "$SS_METHOD",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF

# 4. 创建 Systemd 服务 (开机自启)
cat > /etc/systemd/system/shadowsocks-rust.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network.target

[Service]
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
User=root
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

# 5. 启动服务
systemctl daemon-reload
systemctl enable shadowsocks-rust
systemctl restart shadowsocks-rust

# 6. 生成链接并输出
PUBLIC_IP=$(curl -s ifconfig.me)
RAW_STR="${SS_METHOD}:${SS_PASSWORD}@${PUBLIC_IP}:${SS_PORT}"
B64_STR=$(echo -n "${RAW_STR}" | base64 -w 0)
SS_LINK="ss://${B64_STR}#🇦🇷 AR-Chained-SS"

echo ""
echo "========================================================"
echo "✅ Shadowsocks-Rust (原生版) 部署完成！"
echo "========================================================"
echo "服务器 IP  : ${PUBLIC_IP}"
echo "端口       : ${SS_PORT}"
echo "密码       : ${SS_PASSWORD}"
echo "加密方式   : ${SS_METHOD}"
echo "--------------------------------------------------------"
echo "🔗 分享链接 (Sub-Store 专用):"
echo ""
echo "${SS_LINK}"
echo ""
echo "========================================================"
