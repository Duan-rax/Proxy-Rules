#!/bin/bash

# ==================================================
# Shadowsocks-Rust 部署脚本 (逻辑优化版)
# ==================================================

if [ "$(id -u)" != "0" ]; then echo "❌ 需 root 权限"; exit 1; fi

# [交互环节]
echo "------------------------------------------------"
read -p "👉 请输入 Shadowsocks 端口 (默认 443): " input_port
SS_PORT=${input_port:-443}
echo "------------------------------------------------"

# [安装依赖]
echo "📦 更新基础工具..."
# 加入 lsof (端口检查) 和 procps (ps命令高级功能)
apt-get update -qq && apt-get install -y -qq wget curl tar xz-utils openssl ca-certificates python3 lsof procps

# ==================================================
# [核心逻辑] 端口占用检测与处理
# 参考自: wulabing/install.sh port_exist_check 函数
# ==================================================
echo "🔍 正在检查端口 $SS_PORT..."

# 1. 检测端口是否被监听 (参考 wulabing 逻辑)
if [[ 0 -ne $(lsof -i:"$SS_PORT" | grep -i -c "listen") ]]; then
    echo "⚠️  检测到 $SS_PORT 端口被占用，占用信息如下："
    # 2. 打印占用详情 (让用户知道是谁)
    lsof -i:"$SS_PORT"
    
    echo "------------------------------------------------"
    echo "⏳ 3秒后将尝试自动停止相关进程..."
    sleep 3

    # 3. 获取 PID 列表
    # 使用 -t 参数直接获取纯 PID，比 awk 处理更稳健
    PIDS=$(lsof -t -i:"$SS_PORT")
    
    for pid in $PIDS; do
        # --- 智能升级：Systemd 服务反查 ---
        # 很多时候 kill -9 杀不死由 Systemd 管理的服务(会自动重启)
        # 这里我们通过 PID 反查它属于哪个服务，然后优雅停止
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
    
    sleep 2
    
    # 4. 二次验证结果
    if [[ 0 -ne $(lsof -i:"$SS_PORT" | grep -i -c "listen") ]]; then
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
