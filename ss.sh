#!/bin/bash

# ==================================================
# Shadowsocks-Rust 部署脚本 (只停不删版)
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
# [核心逻辑] 智能端口清理
# ==================================================
echo "🔍 正在检查端口 $SS_PORT..."

# 1. 优先处理 Docker 容器 (只停止，不删除)
if command -v docker >/dev/null 2>&1; then
    # 查找映射了该端口的容器 ID
    DOCKER_CONFLICTS=$(docker ps -q --filter "publish=$SS_PORT")
    
    if [ -n "$DOCKER_CONFLICTS" ]; then
        # 获取容器名字用于显示
        CONTAINER_NAMES=$(docker ps --format "{{.Names}}" --filter "publish=$SS_PORT" | tr '\n' ' ')
        echo "🐳 发现 Docker 容器占用端口: $CONTAINER_NAMES"
        echo "⏸️  正在停止容器 (保留容器实例)..."
        
        # 仅执行 stop，不执行 rm
        docker stop $DOCKER_CONFLICTS >/dev/null 2>&1
        
        echo "✅ 容器已暂停，端口释放"
        sleep 2
    fi
fi

# 2. 清理本地残留进程 (Systemd/Binary)
lsof_output=$(lsof -n -P -i:"$SS_PORT" 2>/dev/null | grep "(LISTEN)")

if [ -n "$lsof_output" ]; then
    echo "⚠️  检测到 $SS_PORT 端口仍被以下服务监听："
    echo "$lsof_output" | awk '{print $1, "(PID: " $2 ")", "User: " $3, "State: " $NF}'
    
    echo "------------------------------------------------"
    echo "⏳ 3秒后将尝试停止监听进程..."
    sleep 3

    PIDS=$(echo "$lsof_output" | awk '{print $2}' | sort -u)
    
    if [ -n "$PIDS" ]; then
        for pid in $PIDS; do
            PROCESS_NAME=$(ps -p $pid -o comm= 2>/dev/null)
            UNIT=$(ps -p $pid -o unit= 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
            
            # --- Docker 守护进程白名单 ---
            if [[ "$UNIT" == "docker.service" || "$UNIT" == "docker.socket" || "$UNIT" == "containerd.service" ]]; then
                echo "🛡️  PID $pid ($PROCESS_NAME) 是 Docker 守护进程，跳过停止..."
                # 尝试杀掉残留的 proxy 子进程，但不杀 Daemon
                kill -9 $pid 2>/dev/null
                continue
            fi
            
            if [[ -n "$UNIT" ]] && [[ "$UNIT" == *.service ]]; then
                echo "💡 PID $pid ($PROCESS_NAME) 属于服务: $UNIT"
                echo "🛑 正在停止服务: $UNIT ..."
                systemctl stop "$UNIT" 2>/dev/null
                systemctl disable "$UNIT" 2>/dev/null
            else
                echo "🔪 PID $pid ($PROCESS_NAME) 不属于服务，强制停止..."
                kill -9 $pid 2>/dev/null
            fi
        done
    fi
    sleep 2
fi

# 二次验证
if lsof -n -P -i:"$SS_PORT" 2>/dev/null | grep -q "(LISTEN)"; then
    echo "❌ 端口清理失败！仍有进程在监听 $SS_PORT"
    exit 1
else
    echo "✅ 端口 $SS_PORT 准备就绪"
fi

# ==================================================
# [部署流程]
# ==================================================
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then 
    target="x86_64-unknown-linux-gnu"
elif [[ "$ARCH" == "aarch64" ]]; then 
    target="aarch64-unknown-linux-gnu"
else 
    echo "❌ 不支持的架构"
    exit 1
fi

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

# ==================================================
# [输出信息]
# ==================================================
echo "🌍 正在识别位置..."
PUBLIC_IP=$(curl -4s ifconfig.me)

API_JSON=$(curl -s "http://ip-api.com/json/${PUBLIC_IP}")
COUNTRY_CODE=$(echo "$API_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('countryCode', 'UN'))")
COUNTRY=$(echo "$API_JSON" | python3 -c "import sys, json; data=json.load(sys.stdin); print(data.get('country', 'Unknown'))")

FLAG=$(python3 -c "
try:
    flag = ''.join([chr(ord(c) + 127397) for c in '${COUNTRY_CODE}'.upper()])
    print(flag)
except:
    print('🏳️')
")

RAW_STR="${SS_METHOD}:${SS_PASSWORD}@${PUBLIC_IP}:${SS_PORT}"
B64_STR=$(echo -n "${RAW_STR}" | base64 -w 0)
SS_URI="ss://${B64_STR}#${FLAG}${COUNTRY_CODE}"
SS_URI_ALT="${SS_METHOD}://${SS_PASSWORD}@${PUBLIC_IP}:${SS_PORT}"

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║            ✅ Shadowsocks 部署成功！               ║"
echo "╚════════════════════════════════════════════════════╝"
echo ""
echo "📍 服务器信息："
echo "   IP 地址    : ${PUBLIC_IP}"
echo "   端口       : ${SS_PORT}"
echo "   加密方式   : ${SS_METHOD}"
echo "   地区       : ${FLAG} ${COUNTRY}"
echo ""
echo "🔑 认证信息："
echo "   用户名     : (留空)"
echo "   密码       : ${SS_PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔗 标准 URI 格式 (推荐):"
echo ""
echo "${SS_URI}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔗 简化格式 (备用):"
echo ""
echo "${SS_URI_ALT}"
echo ""
echo "════════════════════════════════════════════════════"
