#!/bin/bash

# ==================================================
# Shadowsocks-Rust 部署脚本 (防误杀修复版)
# ==================================================

if [ "$(id -u)" != "0" ]; then echo "❌ 需 root 权限"; exit 1; fi

# [交互]
echo "------------------------------------------------"
read -p "👉 请输入 Shadowsocks 端口 (默认 443): " input_port
SS_PORT=${input_port:-443}
echo "------------------------------------------------"

# [依赖]
echo "📦 更新基础工具..."
apt-get update -qq && apt-get install -y -qq wget curl tar xz-utils openssl ca-certificates python3 lsof procps

# ==================================================
# [核心逻辑] 端口占用检测 (精准识别 LISTEN)
# ==================================================
echo "🔍 正在检查端口 $SS_PORT..."

# 1. 检测端口是否被监听 (只看 LISTEN 状态)
if [[ 0 -ne $(lsof -i:"$SS_PORT" -sTCP:LISTEN | grep -i -c "listen") ]]; then
    echo "⚠️  检测到 $SS_PORT 端口被系统服务占用："
    # 打印占用详情 (只显示监听者)
    lsof -i:"$SS_PORT" -sTCP:LISTEN
    
    echo "------------------------------------------------"
    echo "⏳ 3秒后将尝试停止占用端口的服务..."
    sleep 3

    # 2. 获取 PID 列表 (关键修复：只获取 LISTEN 状态的 PID，防止误杀哪吒等客户端)
    PIDS=$(lsof -t -i:"$SS_PORT" -sTCP:LISTEN)
    
    if [ -n "$PIDS" ]; then
        for pid in $PIDS; do
            # Systemd 服务反查
            UNIT=$(ps -p $pid -o unit= 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
            
            if [[ -n "$UNIT" ]] && [[ "$UNIT" == *.service ]]; then
                echo "💡 识别到进程属于系统服务: $UNIT"
                echo "🛑 正在停止服务: $UNIT ..."
                systemctl stop "$UNIT"
                systemctl disable "$UNIT" 2>/dev/null
            else
                echo "🔪 进程不属于服务，执行强制处决 (PID: $pid)..."
                kill -9 $pid 2>/dev/null
            fi
        done
    fi
    
    sleep 2
    
    # 3. 二次验证结果
    if [[ 0 -ne $(lsof -i:"$SS_PORT" -sTCP:LISTEN | grep -i -c "listen") ]]; then
         echo "❌ 端口清理失败，可能有顽固进程无法停止，请手动检查。"
         exit 1
    else
         echo "✅ 端口清理完成"
    fi
else
    echo "✅ $SS_PORT 端口未被占用"
fi

# ==================================================
# [部署流程]
# ==================================================
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then target="x86_64-unknown-linux-gnu"; elif [[ "$ARCH" == "aarch64" ]]; then target="aarch64-unknown-linux-gnu"; else echo "不支持架构"; exit 1; fi

echo "⬇️ 下载最新内核..."
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

# Systemd 配置
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

# [信息输出]
echo "🌍 正在识别位置..."
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
echo "端口       : $SS_PORT"
echo "节点名称   : ${SS_NAME}"
echo "--------------------------------------------------------"
echo "🔗 Sub-Store 导入链接:"
echo ""
echo "${SS_LINK}"
echo ""
echo "========================================================"
