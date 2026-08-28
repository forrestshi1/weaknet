#!/bin/bash
#
# weaknet.sh —— macOS 一键弱网工具
#
# 基于系统自带的 dnctl (dummynet) + pfctl 对「整机全部流量」做限速 / 加延迟 / 丢包。
# 无需安装任何第三方软件。需要 sudo(脚本会自动申请)。
#
# 用法:
#   ./weaknet.sh on <preset>      开启弱网,preset 见下方列表
#   ./weaknet.sh off              关闭弱网,恢复正常网络
#   ./weaknet.sh status           查看当前状态
#   ./weaknet.sh list             列出所有预设档位
#   ./weaknet.sh custom <bw> <delay_ms> <plr>   自定义(如 custom 1Mbit/s 100 0.05)
#
# 例子:
#   ./weaknet.sh on 3g
#   ./weaknet.sh on weakwifi
#   ./weaknet.sh off
#
# 说明:delay 为「单向」延迟,一来一回 RTT 约为 2×delay;plr 为丢包率(0~1)。
#

set -euo pipefail

PIPE_ID=1
ANCHOR="weaknet"
STATE_DIR="/tmp/weaknet"
TOKEN_FILE="$STATE_DIR/pf.token"
CONF_BACKUP="$STATE_DIR/pf.conf.bak"

# ---------- 预设档位:名称 -> "带宽 单向延迟(ms) 丢包率 说明" ----------
get_preset() {
  case "$1" in
    2g)       echo "50Kbit/s 300 0.05 慢速2G/GPRS(极慢+高延迟+丢包)" ;;
    edge)     echo "240Kbit/s 150 0.02 2.5G EDGE" ;;
    3g)       echo "1Mbit/s 100 0.01 普通3G" ;;
    4g)       echo "10Mbit/s 40 0.002 4G/LTE" ;;
    weakwifi) echo "1Mbit/s 150 0.05 弱WiFi(带宽一般+明显丢包)" ;;
    lossy)    echo "2Mbit/s 250 0.20 高延迟高丢包(20%丢包)" ;;
    verybad)  echo "100Kbit/s 500 0.30 极端恶劣(几乎不可用)" ;;
    *)        return 1 ;;
  esac
}

PRESET_ORDER="2g edge 3g 4g weakwifi lossy verybad"

# 记录原始参数,供 need_root 重新以 sudo 拉起
ORIG_ARGS=("$@")

# 仅在需要改网络的命令里申请 sudo(list/help 不打扰)
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    exec sudo "$0" "${ORIG_ARGS[@]}"
  fi
  mkdir -p "$STATE_DIR"
}

msg()  { printf '%s\n' "$*"; }
err()  { printf '错误: %s\n' "$*" >&2; }
pct()  { awk -v p="$1" 'BEGIN{printf "%g%%", p*100}'; }

apply() {
  local bw="$1" delay="$2" plr="$3"

  # 1) 配置 dummynet 管道
  dnctl -q flush 2>/dev/null || true
  dnctl pipe "$PIPE_ID" config bw "$bw" delay "$delay" plr "$plr"

  # 2) 备份并载入 pf 规则(保留原有 /etc/pf.conf,追加 dummynet 锚点)
  if [ ! -f "$CONF_BACKUP" ]; then
    cp /etc/pf.conf "$CONF_BACKUP" 2>/dev/null || : >"$CONF_BACKUP"
  fi
  {
    cat /etc/pf.conf 2>/dev/null || true
    echo "dummynet-anchor \"$ANCHOR\""
    echo "anchor \"$ANCHOR\""
  } | pfctl -q -f - 2>/dev/null

  # 3) 把整机进出流量导入管道
  {
    echo "dummynet in all pipe $PIPE_ID"
    echo "dummynet out all pipe $PIPE_ID"
  } | pfctl -q -a "$ANCHOR" -f - 2>/dev/null

  # 4) 启用 pf(记录 token,off 时精确释放,不影响别人开的 pf)
  if [ ! -f "$TOKEN_FILE" ]; then
    local out
    out=$(pfctl -E 2>&1 || true)
    echo "$out" | awk '/Token/{print $3}' >"$TOKEN_FILE"
  fi
}

disable() {
  # 移除锚点规则
  echo "" | pfctl -q -a "$ANCHOR" -f - 2>/dev/null || true
  # 恢复原始 pf 规则
  if [ -f "$CONF_BACKUP" ]; then
    pfctl -q -f "$CONF_BACKUP" 2>/dev/null || true
    rm -f "$CONF_BACKUP"
  fi
  # 清空 dummynet 管道
  dnctl -q flush 2>/dev/null || true
  # 释放我们持有的 pf enable 引用
  if [ -f "$TOKEN_FILE" ]; then
    local token
    token=$(cat "$TOKEN_FILE")
    [ -n "$token" ] && pfctl -X "$token" 2>/dev/null || true
    rm -f "$TOKEN_FILE"
  fi
}

cmd_on() {
  local name="${1:-}"
  if [ -z "$name" ]; then
    err "请指定档位,例如: $0 on 3g   (查看全部: $0 list)"
    exit 1
  fi
  local spec
  if ! spec=$(get_preset "$name"); then
    err "未知档位: $name   (查看全部: $0 list)"
    exit 1
  fi
  read -r bw delay plr desc <<<"$spec"
  apply "$bw" "$delay" "$plr"
  local rtt=$((delay * 2))
  msg "✅ 已开启弱网 [$name] — $desc"
  msg "   带宽 $bw | 延迟 ${delay}ms/单向(RTT≈${rtt}ms) | 丢包 $(pct "$plr")"
  msg "   关闭请运行: $0 off"
}

cmd_custom() {
  local bw="${1:-}" delay="${2:-}" plr="${3:-}"
  if [ -z "$bw" ] || [ -z "$delay" ] || [ -z "$plr" ]; then
    err "用法: $0 custom <bw> <delay_ms> <plr>   例: $0 custom 1Mbit/s 100 0.05"
    exit 1
  fi
  apply "$bw" "$delay" "$plr"
  local rtt=$((delay * 2))
  msg "✅ 已开启自定义弱网 — 带宽 $bw | 延迟 ${delay}ms/单向(RTT≈${rtt}ms) | 丢包 $(pct "$plr")"
  msg "   关闭请运行: $0 off"
}

cmd_off() {
  disable
  msg "✅ 已关闭弱网,网络恢复正常。"
}

cmd_status() {
  if [ -f "$TOKEN_FILE" ]; then
    msg "状态: 🔴 弱网已开启"
    msg "----- dummynet 管道 -----"
    dnctl list 2>/dev/null || true
    msg "----- pf 锚点规则 -----"
    pfctl -a "$ANCHOR" -s all 2>/dev/null || true
  else
    msg "状态: 🟢 正常(未开启弱网)"
  fi
}

cmd_list() {
  msg "可用档位:"
  printf '  %-10s %-12s %-14s %-8s %s\n' "档位" "带宽" "延迟(RTT)" "丢包" "说明"
  for name in $PRESET_ORDER; do
    read -r bw delay plr desc <<<"$(get_preset "$name")"
    local rtt=$((delay * 2))
    printf '  %-10s %-12s %-14s %-8s %s\n' \
      "$name" "$bw" "${delay}ms(${rtt})" "$(pct "$plr")" "$desc"
  done
  msg ""
  msg "用法: $0 on <档位>   例如 $0 on 3g"
}

# ---------- 入口 ----------
case "${1:-}" in
  on)     need_root; shift; cmd_on "$@" ;;
  off)    need_root; cmd_off ;;
  custom) need_root; shift; cmd_custom "$@" ;;
  status) need_root; cmd_status ;;
  list)   cmd_list ;;
  ""|-h|--help|help)
    msg "macOS 一键弱网工具"
    msg ""
    msg "  $0 on <档位>       开启弱网 (档位见 list)"
    msg "  $0 off             关闭弱网"
    msg "  $0 status          查看状态"
    msg "  $0 list            列出所有档位"
    msg "  $0 custom <bw> <delay_ms> <plr>   自定义"
    ;;
  *)
    err "未知命令: $1"
    msg "运行 '$0 help' 查看用法"
    exit 1
    ;;
esac
