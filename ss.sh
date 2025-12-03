#!/bin/bash

# ==================================================
# Shadowsocks-Rust 通用部署脚本 (lsof 暴力清理版)
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

# 2. 安装依赖 (加入 lsof 用于精准查找端口占用)
echo "📦 更新基础工具..."
# lsof: 最标准的查看端口占用工具
apt-get update -qq && apt-get install -y -qq wget curl tar xz-utils openssl ca-certificates python3 lsof

# ==================================================
# [核心逻辑] 朴实无华的“端口霸占”清理
# ==================================================
echo "🔍 检查端口 $SS_PORT..."

# 使用 lsof 检查端口 ( -i :端口号 )
# -t 参数只输出 PID，方便脚本处理
PIDS=$(lsof -t -i:"$SS_PORT")

if [ -n "$PIDS" ]; then
    echo "⚠️ 发现端口 $SS_PORT 被占用，PID: $PIDS"
    
    # 获取占用程序的名称，让用户知道死的是谁
    PROCESS_NAMES=$(lsof -p $PIDS | awk 'NR==2{print $1}')
    echo "🔪 正在处决进程: $PROCESS_NAMES ..."

    # 暴力强杀 (kill -9 是系统底层的强制终止信号)
    # xargs 将 PID 列表传给 kill
    echo "$PIDS" | xargs kill -9
    
    sleep 2
    
    # 二次确认
    if lsof -t -i:"$SS_PORT" >/dev/null; then
        echo "❌ 端口清理失败，这就是个顽固分子！请手动检查。"
        exit 1
    else
        echo "✅ 端口已清理干净"
    fi
else
    echo "✅ 端口本来就是空的，无需清理"
fi

# ==================================================
# [常规部署流程]
# ==================================================
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then target="x86_64-unknown-linux-gnu"; elif [[ "$ARCH" == "aarch64" ]]; then target="aarch64-unknown-linux-gnu"; else echo "不支持架构"; exit 1; fi

echo "⬇️ 下载 Shadowsocks-Rust..."
LATEST_VER=$(curl -s "https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
wget -qO ss-rust.tar.xz "https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_VER}/shadowsocks-${LATEST_VER}.${target}.tar.xz"
tar -xf ss-rust.tar.xz && mv ssserver /usr/local/bin/ && chmod +x /usr/local/bin/ssserver && rm ss-rust.tar.xz* 2>/dev/null

# 配置生成
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

# ==================================================
# [输出]
# ==================================================
echo "🌍 识别位置..."
PUBLIC_IP=$(curl -4s ifconfig.me)

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
