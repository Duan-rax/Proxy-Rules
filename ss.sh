#!/bin/bash

# ==================================================
# Shadowsocks-Rust 一键安装脚本 (IPv4 强制版)
# ==================================================

if [ "$(id -u)" != "0" ]; then echo "❌ 需 root 权限"; exit 1; fi

echo "📦 环境准备..."
systemctl stop shadowsocks-rust 2>/dev/null
apt-get update -qq && apt-get install -y -qq wget curl tar xz-utils openssl ca-certificates python3

# 架构检测
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then target="x86_64-unknown-linux-gnu"; elif [[ "$ARCH" == "aarch64" ]]; then target="aarch64-unknown-linux-gnu"; else echo "不支持架构"; exit 1; fi

# 下载核心
echo "⬇️ 下载最新内核..."
LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
wget -qO ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${target}.tar.xz"
tar -xf ss-rust.tar.xz && mv ssserver /usr/local/bin/ && chmod +x /usr/local/bin/ssserver && rm ss-rust.tar.xz* 2>/dev/null

# 配置生成
SS_PASSWORD=$(openssl rand -base64 16)
SS_PORT=443
SS_METHOD="aes-256-gcm"
mkdir -p /etc/shadowsocks-rust

cat > /etc/shadowsocks-rust/config.json <<EOF
{
    "server": "::", 
    "server_port": $SS_PORT,
    "password": "$SS_PASSWORD",
    "method": "$SS_METHOD",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF
# 注意：server 写 "::" 可以同时监听 IPv4 和 IPv6，但我们分享链接只给 IPv4

# Systemd
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

systemctl daemon-reload && systemctl enable shadowsocks-rust && systemctl restart shadowsocks-rust

# 【核心修改】强制获取 IPv4 地址
echo "🌍 正在识别 IPv4 位置..."
PUBLIC_IP=$(curl -4s ifconfig.me)

# 自动命名 (基于 IPv4 查询)
API_JSON=$(curl -s "http://ip-api.com/json/${PUBLIC_IP}")
SS_NAME=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    code = data.get('countryCode', 'UN')
    flag = ''.join([chr(ord(c) + 127397) for c in code.upper()])
    print(f'{flag} {code}-Chained-SS')
except:
    print('🏳️ Unknown-Chained-SS')
" "$API_JSON")

# 生成链接
RAW_STR="${SS_METHOD}:${SS_PASSWORD}@${PUBLIC_IP}:${SS_PORT}"
B64_STR=$(echo -n "${RAW_STR}" | base64 -w 0)
SS_LINK="ss://${B64_STR}#${SS_NAME}"

echo ""
echo "========================================================"
echo "✅ 部署成功 (IPv4)"
echo "========================================================"
echo "服务器 IP  : ${PUBLIC_IP}"
echo "节点名称   : ${SS_NAME}"
echo "--------------------------------------------------------"
echo "🔗 Sub-Store 链接:"
echo ""
echo "${SS_LINK}"
echo ""
echo "========================================================"
