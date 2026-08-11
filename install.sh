#!/bin/bash
set -eo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
fi

INSTALL_DIR="/opt/vps-monitor"
mkdir -p "$INSTALL_DIR"

echo "=========================================="
echo "    VPS 监控与安全一体化脚本 - 安装/更新向导    "
echo "=========================================="
echo ""

# 配置文件持久化路径
CONFIG_FILE="/etc/vps_monitor.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "ℹ️ 检测到已有配置文件，自动加载之前的参数..."
    echo ""
fi

read -p "请输入你的 Telegram Bot Token [${TOKEN:-}]: " input_token
[ -n "$input_token" ] && TOKEN="$input_token"

read -p "请输入你的 Telegram Chat ID [${CHAT_ID:-}]: " input_chat
[ -n "$input_chat" ] && CHAT_ID="$input_chat"

read -p "请输入网卡名称 (默认 ens4): " input_dev
[ -n "$input_dev" ] && INTERFACE="$input_dev"
[ -z "${INTERFACE:-}" ] && INTERFACE="ens4"

# 新增：询问是否开启防夜间扣费定时断网功能
echo ""
read -p "是否开启夜间定时断网/防扣费功能？(y/N): " enable_net_control
enable_net_control=${enable_net_control:-N}

if [[ "$enable_net_control" =~ ^[Yy]$ ]]; then
    read -p "请输入每天断网开始时间 (24小时制，例如 02): " net_stop_hour
    net_stop_hour=${net_stop_hour:-2}
    read -p "请输入每天恢复网络时间 (24小时制，例如 06): " net_start_hour
    net_start_hour=${net_start_hour:-6}
    ENABLE_NET_LIMIT="true"
else
    ENABLE_NET_LIMIT="false"
    net_stop_hour="2"
    net_start_hour="6"
fi

cat << CONF > "$CONFIG_FILE"
TOKEN="$TOKEN"
CHAT_ID="$CHAT_ID"
INTERFACE="$INTERFACE"
ENABLE_NET_LIMIT="$ENABLE_NET_LIMIT"
NET_STOP_HOUR="$net_stop_hour"
NET_START_HOUR="$net_start_hour"
CONF
chmod 600 "$CONFIG_FILE"

# ==========================================
# 1. 写入综合监控脚本 /opt/vps-monitor/vps_monitor.sh
# ==========================================
cat << 'MONITOR_EOF' > "$INSTALL_DIR/vps_monitor.sh"
#!/usr/bin/env bash
set -eo pipefail

source /etc/vps_monitor.conf

API_URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
MONTH_LIMIT_GIB="200"
CPU_WARN_PERCENT=90
MEM_WARN_PERCENT=90
NET_RATE_LIMIT_KB=102400
DAILY_TRAGB_LIMIT_MB=5000
MAX_TCP_ESTAB=300
MAX_PPS=2500

send_telegram() {
    local title="$1"
    local body="$2"
    local message="*${title}*%0A${body}"
    curl -s -X POST "$API_URL" -d "chat_id=${CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" >/dev/null
}

get_top_processes() {
    ps -eo pid,%cpu,%mem,comm --sort=-%cpu | head -n 4 | tail -n +1
}

if command -v vnstat &> /dev/null; then
    JSON_DATA="$(timeout 10 vnstat --json || echo "{}")"
    if [ "$JSON_DATA" != "{}" ]; then
        MONTH_RX_KIB="$(echo "$JSON_DATA" | jq -r --arg iface "$INTERFACE" '.interfaces[] | select(.name==$iface) |.traffic.month[-1].rx // 0')"
        MONTH_TX_KIB="$(echo "$JSON_DATA" | jq -r --arg iface "$INTERFACE" '.interfaces[] | select(.name==$iface) | .traffic.month[-1].tx // 0')"
        DAY_RX_KIB="$(echo "$JSON_DATA" | jq -r --arg iface "$INTERFACE" '.interfaces[]| select(.name==$iface) | .traffic.day[-1].rx // 0')"
        DAY_TX_KIB="$(echo "$JSON_DATA" | jq -r --arg iface "$INTERFACE" '.interfaces[] | select(.name==$iface) | .traffic.day[-1].tx // 0')"

        MONTH_TOTAL_GIB="$(awk "BEGIN {printf \"%.4f\", $MONTH_TX_KIB / 1024 / 1024 / 1024}")"
        MONTH_TOTAL_RX_GIB="$(awk "BEGIN {printf \"%.4f\", $MONTH_RX_KIB / 1024 / 1024 / 1024}")"
        DAY_TOTAL_GIB="$(awk "BEGIN {printf \"%.4f\", $DAY_TX_KIB / 1024 / 1024}")"
        USED_PERCENT="$(awk "BEGIN {printf \"%.1f\", ($MONTH_TOTAL_GIB / $MONTH_LIMIT_GIB) * 100}")"

        if [ "${1:-}" = "report" ]; then
            MESSAGE="🚦 GCP出站流量报告 
接口: ${INTERFACE} 
本月累计(入站): ${MONTH_TOTAL_RX_GIB} GiB 
本月累计(出站): ${MONTH_TOTAL_GIB} GiB
今日流量(出站): ${DAY_TOTAL_GIB} MiB 
已用比例(出站): ${USED_PERCENT}%"
            timeout 15 curl -s -X POST "$API_URL" -d "chat_id=${CHAT_ID}" --data-urlencode "text=${MESSAGE}" >/dev/null
            exit 0
        fi
    fi
fi

CPU_HIGH_COUNT=0
for i in {1..3}; do
    CURRENT_CPU=$(top -b -n 1 | grep "Cpu(s)" | awk '{print int(105 - $8)}')
    if [ "$CURRENT_CPU" -ge "$CPU_WARN_PERCENT" ]; then
        CPU_HIGH_COUNT=$((CPU_HIGH_COUNT + 1))
    fi
    sleep 1
done

if [ "$CPU_HIGH_COUNT" -ge 3 ]; then
    TOP_CPU_PROCS=$(get_top_processes)
    send_telegram "⚠️ VPS CPU 告警" "检测到 CPU 持续高负载！%0A*Top 进程:*%0A\`\`\`%0A${TOP_CPU_PROCS}%0A\`\`\`"
fi

MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
MEM_USED=$(free -m | grep Mem | awk '{print $3}')
MEM_PERCENT=$(( 100 * MEM_USED / MEM_TOTAL ))
if [ "$MEM_PERCENT" -ge "$MEM_WARN_PERCENT" ]; then
    send_telegram "⚠️ VPS 内存告警" "当前内存占用率高达 ${MEM_PERCENT}% (${MEM_USED}M/${MEM_TOTAL}M)"
fi

R1_BYTES=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $2}')
R1_PACKETS=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $3}')
T1_BYTES=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $10}')
T1_PACKETS=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $11}')

sleep 1

R2_BYTES=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $2}')
R2_PACKETS=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $3}')
T2_BYTES=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $10}')
T2_PACKETS=$(cat /proc/net/dev | grep "$INTERFACE" | awk '{print $11}')

RX_RATE_KB=$(( (R2_BYTES - R1_BYTES) / 1024 ))
TX_RATE_KB=$(( (T2_BYTES - T1_BYTES) / 1024 ))
RX_PPS=$(( R2_PACKETS - R1_PACKETS ))
TX_PPS=$(( T2_PACKETS - T1_PACKETS ))
TOTAL_PPS=$(( RX_PPS + TX_PPS ))

if [ "$RX_RATE_KB" -ge "$NET_RATE_LIMIT_KB" ] || [ "$TX_RATE_KB" -ge "$NET_RATE_LIMIT_KB" ]; then
    send_telegram "🚨 VPS 网络流量突增告警" "网卡 $INTERFACE 异常！%0A下行: ${RX_RATE_KB} KB/s%0A上行: ${TX_RATE_KB} KB/s"
fi

if [ "$TOTAL_PPS" -ge "$MAX_PPS" ]; then
    send_telegram "🚨 异常包速率告警 (PPS)" "每秒总包数高达 ${TOTAL_PPS} PPS"
fi

if command -v ss &> /dev/null; then
    CURRENT_ESTAB=$(ss -ant | grep -c ESTAB)
    if [ "$CURRENT_ESTAB" -ge "$MAX_TCP_ESTAB" ]; then
        send_telegram "🚨 TCP 连接数异常告警" "活跃连接数高达 ${CURRENT_ESTAB} 个！"
    fi
fi
MONITOR_EOF

chmod +x "$INSTALL_DIR/vps_monitor.sh"

# ==========================================
# 2. 写入 SSH 登录/退出通知脚本 /opt/vps-monitor/ssh_notify.sh
# ==========================================
cat << 'SSH_EOF' > "$INSTALL_DIR/ssh_notify.sh"
#!/usr/bin/env bash
source /etc/vps_monitor.conf

API_URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
LOGIN_IP="${PAM_RHOST:-$SSH_CLIENT}"
[ -z "$LOGIN_IP" ] && LOGIN_IP="本地/内网登录"
LOGIN_USER="${PAM_USER:-$USER}"
CURRENT_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

if [ "${PAM_TYPE:-}" = "close_session" ]; then
    TITLE="🚪 VPS SSH 会话已断开"
    BODY="用户: \`${LOGIN_USER}\`%0A来源IP: \`${LOGIN_IP}\`%0A时间: \`${CURRENT_TIME}\`"
else
    TITLE="🚨 VPS 收到新的 SSH 登录"
    BODY="用户: \`${LOGIN_USER}\`%0A来源IP: \`${LOGIN_IP}\`%0A时间: \`${CURRENT_TIME}\`"
fi

MESSAGE="*${TITLE}*%0A${BODY}"

curl -s -X POST "$API_URL" -d "chat_id=${CHAT_ID}" --data-urlencode "text=${MESSAGE}" -d "parse_mode=Markdown" >/dev/null &
SSH_EOF

chmod +x "$INSTALL_DIR/ssh_notify.sh"

# ==========================================
# 3. 写入防火墙断网控制脚本 /opt/vps-monitor/net_control.sh
# ==========================================
cat << 'NET_EOF' > "$INSTALL_DIR/net_control.sh"
#!/usr/bin/env bash
source /etc/vps_monitor.conf
ACTION="${1:-}"

if [ "$ACTION" = "stop" ]; then
    iptables -I INPUT -i "$INTERFACE" -j DROP 2>/dev/null || true
    iptables -I OUTPUT -o "$INTERFACE" -j DROP 2>/dev/null || true
    echo "$(date): 防火墙已拦截所有网络流量 (防扣费生效)" >> /var/log/vps_net_control.log
elif [ "$ACTION" = "start" ]; then
    iptables -D INPUT -i "$INTERFACE" -j DROP 2>/dev/null || true
    iptables -D OUTPUT -o "$INTERFACE" -j DROP 2>/dev/null || true
    echo "$(date): 网络流量已恢复" >> /var/log/vps_net_control.log
fi
NET_EOF

chmod +x "$INSTALL_DIR/net_control.sh"

# 4. 绑定 SSH PAM 钩子
if ! grep -q "pam_exec.so seteuid $INSTALL_DIR/ssh_notify.sh" /etc/pam.d/sshd; then
    echo "session optional pam_exec.so seteuid $INSTALL_DIR/ssh_notify.sh" >> /etc/pam.d/sshd
    echo "✅ SSH 登录/退出实时通知已绑定成功"
fi

# ==========================================
# 5. 配置干净且精准的 Crontab 定时任务
# ==========================================
# 清理所有旧的 vps-monitor 相关定时任务
crontab -l 2>/dev/null | grep -v "vps_monitor.sh" | grep -v "net_control.sh" | crontab -

# 写入常规巡检与流量报告任务
(crontab -l 2>/dev/null; echo "*/5 * * * * /bin/bash $INSTALL_DIR/vps_monitor.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 0,15 * * * /bin/bash $INSTALL_DIR/vps_monitor.sh report") | crontab -

# 如果用户开启了夜间防扣费定时断网，则写入对应的防火墙开关任务
if [ "$ENABLE_NET_LIMIT" = "true" ]; then
    (crontab -l 2>/dev/null; echo "0 $NET_STOP_HOUR * * * /bin/bash $INSTALL_DIR/net_control.sh stop") | crontab -
    (crontab -l 2>/dev/null; echo "0 $NET_START_HOUR * * * /bin/bash $INSTALL_DIR/net_control.sh start") | crontab -
    echo "✅ 定时断网防扣费已启用: 每天 ${NET_STOP_HOUR}:00 至 ${NET_START_HOUR}:00 自动拦截流量"
fi

echo "✅ 定时任务配置成功"

# ==========================================
# 6. 注册全局一键更新命令 vps-update
# ==========================================
cat << UPDATE_EOF > /usr/local/bin/vps-update
#!/bin/bash
REPO_RAW_URL="https://raw.githubusercontent.com/397552789/script/refs/heads/main/install.sh"
echo "🔄 正在从 GitHub 检查并更新 VPS 监控脚本..."
bash <(curl -sL "\$REPO_RAW_URL")
UPDATE_EOF

chmod +x /usr/local/bin/vps-update

echo ""
echo "=========================================="
echo "🎉 脚本安装与更新全部完成！"
echo "👉 以后升级只需在终端敲入: vps-update"
echo "=========================================="
