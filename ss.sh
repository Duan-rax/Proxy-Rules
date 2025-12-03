#!/bin/bash

# ==================================================
# Shadowsocks-Rust 一键安装脚本 (自动国旗命名版)
# 适用于: Debian / Ubuntu
# 功能: 自动安装最新内核、随机密码、自动识别IP归属地生成国旗名
# ==================================================

# 1. 检查权限与清理环境
if [ "$(id -u)" != "0" ]; then
   echo "❌ 错误: 必须使用 root 权限运行此脚本"
   exit 1
fi

echo "📦 正在清理旧环境并安装依赖..."
systemctl stop shadowsocks-rust 2>/dev/null
docker stop ss-rust xray_reality 2>/dev/null
apt-get update -qq && apt-get install -y -qq wget curl tar xz-utils openssl ca-certificates python3

# 2. 架构检测与下载核心
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    target="x86_64-unknown-linux-gnu"
elif [[ "$ARCH" == "aarch64" ]]; then
    target="aarch64-unknown-linux-gnu"
else
    echo "❌ 不支持的架构: $ARCH"
    exit 1
fi

echo "⬇️ 获取 Shadowsocks-Rust 最新版本..."
LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_VER" ]; then
    echo "❌ 获取版本失败，请检查网络或 GitHub API 限制"
    exit 1
fi

echo "⬇️ 正在下载版本: $LATEST_VER"
wget -qO ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${target}.tar.xz"
tar -xf ss-rust.tar.xz
mv ssserver /usr/local/bin/
chmod +x /usr/local/bin/ssserver
rm ss-rust.tar.xz sslocal ssurl ssmanager* 2>/dev/null

# 3. 生成配置
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

# 4. 配置 Systemd 服务
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

systemctl daemon-reload
systemctl enable shadowsocks-rust
systemctl restart shadowsocks-rust

# 5. 【核心逻辑】使用公共 API 自动命名
echo "🌍 正在识别服务器位置..."
PUBLIC_IP=$(curl -s ifconfig.me)

# 使用 ip-api.com (免费/无Token)
# 注意：该接口对于同一 IP 有每分钟 45 次的限制，对于部署脚本来说绰绰有余
API_JSON=$(curl -s "http://ip-api.com/json/${PUBLIC_IP}")

# 使用 Python 解析并生成 Emoji
# 逻辑：读取 countryCode (如 AR)，转为 Emoji (🇦🇷)
SS_NAME=$(python3 -c "
import sys, json
try:
    data = json.loads(sys.argv[1])
    code = data.get('countryCode', 'UN')
    # ASCII 转 Unicode 区域指示符算法
    flag = ''.join([chr(ord(c) + 127397) for c in code.upper()])
    print(f'{flag} {code}-Chained-SS')
except:
    print('🏳️ Unknown-Chained-SS')
" "$API_JSON")

# 6. 生成分享链接
RAW_STR="${SS_METHOD}:${SS_PASSWORD}@${PUBLIC_IP}:${SS_PORT}"
B64_STR=$(echo -n "${RAW_STR}" | base64 -w 0)
SS_LINK="ss://${B64_STR}#${SS_NAME}"

# 7. 输出
echo ""
echo "========================================================"
echo "✅ 部署成功！"
echo "========================================================"
echo "服务器 IP  : ${PUBLIC_IP}"
echo "自动命名   : ${SS_NAME}"
echo "--------------------------------------------------------"
echo "🔗 Sub-Store 导入链接:"
echo ""
echo "${SS_LINK}"
echo ""
echo "========================================================"
