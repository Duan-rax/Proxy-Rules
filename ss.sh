#!/bin/bash

# ==================================================
# Shadowsocks-Rust 交互式安装脚本 (通用适配版)
# ==================================================

# 1. 权限检查
if [ "$(id -u)" != "0" ]; then echo "❌ 需 root 权限"; exit 1; fi

# ==================================================
# [交互环节] 用户设定端口
# ==================================================
echo "------------------------------------------------"
read -p "👉 请输入 Shadowsocks 端口 (默认 443): " input_port
SS_PORT=${input_port:-443}
echo "------------------------------------------------"
echo "🔧 目标端口: $SS_PORT"

# 2. 安装必要依赖 (加入 psmisc 用于管理端口进程)
echo "📦 正在更新软件源并安装依赖..."
# psmisc 包含 fuser 命令，用于精准查杀端口
apt-get update -qq && apt-get install -y -qq wget curl tar xz-utils openssl ca-certificates python3 psmisc

# ==================================================
# [逻辑核心] 端口占用检测与释放
# ==================================================
echo "🔍 检查端口 $SS_PORT 占用情况..."

# 使用 fuser 检测 TCP 端口
if fuser "$SS_PORT/tcp" >/dev/null 2>&1; then
    PID=$(fuser "$SS_PORT/tcp" 2>/dev/null)
    echo "⚠️ 警告: 端口 $SS_PORT 正被进程 (PID: $PID) 占用"
    echo "🔪 正在终止占用进程以释放端口..."
    
    # 强制杀掉占用该端口的进程
    fuser -k -n tcp "$SS_PORT"
    
    # 等待释放
    sleep 2
    
    # 二次检查
    if fuser "$SS_PORT/tcp" >/dev/null 2>&1; then
        echo "❌ 端口释放失败，请手动检查！"
        exit 1
    else
        echo "✅ 端口已释放"
    fi
else
    echo "✅ 端口空闲，准备部署"
fi

# 3. 架构检测与下载
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then target="x86_64-unknown-linux-gnu"; elif [[ "$ARCH" == "aarch64" ]]; then target="aarch64-unknown-linux-gnu"; else echo "不支持架构"; exit 1; fi

echo "⬇️ 下载 Shadowsocks-Rust 内核..."
LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
wget -qO ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${target}.tar.xz"
tar -xf ss-rust.tar.xz && mv ssserver /usr/local/bin/ && chmod +x /usr/local/bin/ssserver && rm ss-rust.tar.xz* 2>/dev/null

# 4. 生成配置 (使用用户指定的端口)
SS_PASSWORD=$(openssl rand -base64 16)
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

# 5. 配置 Systemd
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

# 6. 获取 IPv4 地址与自动命名
echo "🌍 正在识别 IPv4 位置..."
PUBLIC_IP=$(curl -4s ifconfig.me)

# 自动命名逻辑
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

# 7. 生成链接
RAW_STR="${SS_METHOD}:${SS_PASSWORD}@${PUBLIC_IP}:${SS_PORT}"
B64_STR=$(echo -n "${RAW_STR}" | base64 -w 0)
SS_LINK="ss://${B64_STR}#${SS_NAME}"

echo ""
echo "========================================================"
echo "✅ 部署成功"
echo "========================================================"
echo "服务器 IP  : ${PUBLIC_IP}"
echo "端口       : ${SS_PORT}"
echo "节点名称   : ${SS_NAME}"
echo "--------------------------------------------------------"
echo "🔗 Sub-Store 链接:"
echo ""
echo "${SS_LINK}"
echo ""
echo "========================================================"
