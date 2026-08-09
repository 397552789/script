#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "❌ 请使用 root 权限运行此脚本 (例如: sudo bash $0)"
    exit 1
fi

echo "=========================================="
echo "    VPS 监控与安全一体化脚本 - 安装/更新向导    "
echo "=========================================="
echo ""

# 配置文件持久化路径（如果已存在，尝试读取旧配置避免重复输入）
CONFIG_FILE="/etc/vps_monitor.conf"
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "ℹ️ 检测到已有配置文件，自动加载之前的 Token 和 Chat ID..."
    echo ""
fi

# 交互式获取或确认配置
read -p "请输入你的 Telegram Bot Token [${TOKEN:-}]: " input_token
[ -n "$input_token" ] && TOKEN="$input_token"

read -p "请输入你的 Telegram Chat ID [${CHAT_ID:-}]: " input_chat
[ -n "$input_chat" ] && CHAT_ID="$input_chat"

read -p "请输入网卡名称 (默认 ens4): " input_dev
[ -n "$input_dev" ] && INTERFACE="$input_dev"
[ -z "${INTERFACE:-}" ] && INTERFACE="ens4"

# 保存配置到本地
cat << CONF > "$CONFIG_FILE"
TOKEN="$TOKEN"
CHAT_ID="$CHAT_ID"
INTERFACE="$INTERFACE"
CONF
chmod 600 "$CONFIG_FILE"

# 1. 写入综合监控脚本 /root/vps_monitor.sh
cat << 'MONITOR_EOF' > /root/vps_monitor.sh
#!/usr/bin/env bash
set -euo pipefail

# 加载公共配置
source /etc/vps_monitor.conf

API_URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
MONTH_LIMIT_GIB="200"
CPU_WARN_PERCENT=85
MEM_WARN_PERCENT=85
NET_RATE_LIMIT_KB=5120
DAILY_TRAGB_LIMIT_MB=800
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

# -------- 1. vnStat 流量报告逻辑（支持定时触发或独立运行）--------
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

        # 如果通过 crontab 传参或者在特定时间（0点或15点），发送完整出站报告
        CURRENT_HOUR=$(date +%H)
        if [ "${1:-}" = "report" ] || [ "$CURRENT_HOUR" = "00" ] || [ "$CURRENT_HOUR" = "15" ]; then
            MESSAGE="🚦 GCP出站流量报告 
接口: ${INTERFACE} 
本月累计(入站): ${MONTH_TOTAL_RX_GIB} GiB 
本月累计(出站): ${MONTH_TOTAL_GIB} GiB
今日流量(出站): ${DAY_TOTAL_GIB} GiB 
已用比例(出站): ${USED_PERCENT}%"
            timeout 15 curl -s -X POST "$API_URL" -d "chat_id=${CHAT_ID}" --data-urlencode "text=${MESSAGE}" >/dev/null
        fi
    fi
fi

# -------- 2. 系统资源与异常攻击巡检逻辑 --------
CPU_USAGE_INT=$(top -b -n 2 -d 1 | grep "Cpu(s)" | tail -n 1 | awk '{print int(105 - $8)}')
if [ "$CPU_USAGE_INT" -ge "$CPU_WARN_PERCENT" ]; then
    TOP_CPU_PROCS=$(get_top_processes)
    send_telegram "⚠️ VPS CPU 告警" "当前 CPU 负载高达 ${CPU_USAGE_INT}%！%0A*Top 进程:*%0A\`\`\`%0A${TOP_CPU_PROCS}%0A\`\`\`"
fi

MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
MEM_USED=$(free -m | grep Mem | awk '{print $3}')
MEM_PERCENT=$(( 100 * MEM_USED / MEM_TOTAL ))
if [ "$MEM_PERCENT" -ge "$MEM_WARN_PERCENT" ]; then
    send_telegram "⚠️ VPS 内存告警" "当前内存占用率高达 ${MEM_PERCENT}% (${MEM_USED}M/${MEM_TOTAL}M)"
fi

# 网络吞吐与 PPS 检测
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
    send_telegram "🚨 异常包速率告警 (PPS)" "每秒总包数高达 ${TOTAL_PPS} PPS（可能遭遇端口扫描或DDoS）"
fi

if command -v ss &> /dev/null; then
    CURRENT_ESTAB=$(ss -ant | grep -c ESTAB)
    if [ "$CURRENT_ESTAB" -ge "$MAX_TCP_ESTAB" ]; then
        send_telegram "🚨 TCP 连接数异常告警" "活跃连接数高达 ${CURRENT_ESTAB} 个！"
    fi
fi
MONITOR_EOF

chmod +x /root/vps_monitor.sh

# 2. 写入 SSH 登录通知脚本 /root/ssh_notify.sh
cat << 'SSH_EOF' > /root/ssh_notify.sh
#!/usr/bin/env bash
source /etc/vps_monitor.conf

API_URL="https://api.telegram.org/bot${TOKEN}/sendMessage"
LOGIN_IP="${PAM_RHOST:-$SSH_CLIENT}"
[ -z "$LOGIN_IP" ] && LOGIN_IP="本地/内网登录"
LOGIN_USER="${PAM_USER:-$USER}"
CURRENT_TIME="$(date '+%Y-%m-%d %H:%M:%S')"

TITLE="🚨 VPS 收到新的 SSH 登录"
BODY="用户: \`${LOGIN_USER}\`%0A来源IP: \`${LOGIN_IP}\`%0A时间: \`${CURRENT_TIME}\`"
MESSAGE="*${TITLE}*%0A${BODY}"

curl -s -X POST "$API_URL" -d "chat_id=${CHAT_ID}" --data-urlencode "text=${MESSAGE}" -d "parse_mode=Markdown" >/dev/null &
SSH_EOF

chmod +x /root/ssh_notify.sh

# 3. 绑定 SSH PAM 钩子
if ! grep -q "pam_exec.so seteuid /root/ssh_notify.sh" /etc/pam.d/sshd; then
    echo "session optional pam_exec.so seteuid /root/ssh_notify.sh" >> /etc/pam.d/sshd
    echo "✅ SSH 登录实时通知已绑定成功"
fi

# 4. 配置 Crontab 定时任务
# - 每 5 分钟运行一次监控巡检（异常即时告警）
# - 每天 0点 和 15点 强制发送流量报告
(crontab -l 2>/dev/null | grep -v "vps_monitor.sh"; \
 echo "*/5 * * * * /bin/bash /root/vps_monitor.sh"; \
 echo "0 0,15 * * * /bin/bash /root/vps_monitor.sh report") | crontab -
echo "✅ 定时任务配置成功（巡检每5分钟一次，流量报告0点/15点准时发送）"

# 5. 注册全局一键更新命令 vps-update
cat << 'UPDATE_EOF' > /usr/local/bin/vps-update
#!/bin/bash
# 替换为你的 GitHub Raw 链接
REPO_RAW_URL="https://raw.githubusercontent.com/397552789/script/refs/heads/main/install.sh"
echo "🔄 正在从 GitHub 检查并更新 VPS 监控脚本..."
bash <(curl -sL "$REPO_RAW_URL")
UPDATE_EOF

chmod +x /usr/local/bin/vps-update

echo ""
echo "=========================================="
echo "🎉 安装与部署全部完成！"
echo "👉 后续如果修改了 GitHub 代码，只需在任意终端敲入: vps-update 即可一键升级。"
echo "=========================================="
