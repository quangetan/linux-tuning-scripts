#!/usr/bin/env bash
#
# 一键配置：zram + zswap（开机自启）
#
# 用法：
#   sudo ./enable-zram-zswap.sh [rn] [nc]
#
#   rn : zram 大小 = rn × 物理内存      （默认 2）
#   nc : zswap 最大池大小 = nc × 物理内存（默认 1）
#
#   例如：
#     sudo ./enable-zram-zswap.sh        # zram=2×RAM, zswap<=1×RAM
#     sudo ./enable-zram-zswap.sh 1 0    # zram=1×RAM, zswap 关闭（或保持默认）
#     sudo ./enable-zram-zswap.sh 3 1    # zram=3×RAM, zswap<=1×RAM
#

set -euo pipefail

# ========= 颜色输出 =========
if [ -t 1 ]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  BLUE="\033[34m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()    { echo -e "${GREEN}[OK]  ${RESET} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()   { echo -e "${RED}[ERR] ${RESET} $*"; }

# ========= 参数 =========
RN=${1:-2}  # zram 倍数
NC=${2:-1}  # zswap 倍数

BOOT_SCRIPT=/usr/local/sbin/zram-zswap-boot.sh
SERVICE_FILE=/etc/systemd/system/zram-zswap.service

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行：sudo $0 [rn] [nc]"
    exit 1
  fi
}

check_systemd() {
  if ! [ -d /run/systemd/system ]; then
    err "当前系统似乎不是 systemd（/run/systemd/system 不存在），不支持本脚本。"
    exit 1
  fi
}

validate_int() {
  local name="$1"
  local val="$2"
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then
    err "$name 必须为非负整数，当前：$val"
    exit 1
  fi
}

create_boot_script() {
  local rn="$1"
  local nc="$2"

  # zswap 百分比：nc × 100；>100 截断为 100
  local zswap_percent=$(( nc * 100 ))
  local zswap_clamped=$zswap_percent
  if [ "$zswap_clamped" -gt 100 ]; then
    zswap_clamped=100
  fi

  cat >"$BOOT_SCRIPT" <<EOF
#!/usr/bin/env bash
# 本脚本在开机时运行：配置 zram + zswap
set -euo pipefail

RN=${rn}
NC=${nc}
ZSWAP_PERCENT=${zswap_clamped}

MEM_KB=\$(grep MemTotal /proc/meminfo | awk '{print \$2}')
[ -n "\$MEM_KB" ] || exit 0

# ========== zram ==========
if modprobe zram 2>/dev/null; then
  swapoff /dev/zram0 2>/dev/null || true

  # zram 大小 = RN × 物理内存
  # MEM_KB 是 KB，乘以 RN 再乘 1024 -> bytes
  ZRAM_BYTES=\$(( MEM_KB * 1024 * RN ))
  echo "\$ZRAM_BYTES" > /sys/block/zram0/disksize

  # 压缩算法：优先 lz4，其次 zstd
  if [ -e /sys/block/zram0/comp_algorithm ]; then
    ALGS=\$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
    if echo "\$ALGS" | grep -qw lz4; then
      echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    elif echo "\$ALGS" | grep -qw zstd; then
      echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    fi
  fi

  mkswap -f /dev/zram0
  swapon -p 200 /dev/zram0
fi

# ========== zswap ==========
PARAM_DIR=/sys/module/zswap/parameters
if [ -d "\$PARAM_DIR" ] && [ "\$ZSWAP_PERCENT" -gt 0 ]; then
  if [ -e "\$PARAM_DIR/max_pool_percent" ]; then
    echo "\$ZSWAP_PERCENT" > "\$PARAM_DIR/max_pool_percent" 2>/dev/null || true
  fi

  if [ -e "\$PARAM_DIR/compressor" ]; then
    ALGS=\$(cat "\$PARAM_DIR/compressor" 2>/dev/null || echo "")
    if echo "\$ALGS" | grep -qw lz4; then
      echo lz4 > "\$PARAM_DIR/compressor" 2>/dev/null || true
    elif echo "\$ALGS" | grep -qw zstd; then
      echo zstd > "\$PARAM_DIR/compressor" 2>/dev/null || true
    fi
  fi

  if [ -e "\$PARAM_DIR/enabled" ]; then
    echo Y > "\$PARAM_DIR/enabled" 2>/dev/null || echo 1 > "\$PARAM_DIR/enabled" 2>/dev/null || true
  fi
fi
EOF

  chmod +x "$BOOT_SCRIPT"

  # 如果 nc>1 被截断，启动时你看不到提示，所以在外层脚本里提示一次
  if [ "$zswap_percent" -gt 100 ]; then
    warn "nc=${nc} => zswap 百分比=${zswap_percent}%，已在内部截断为 100%。"
  fi
}

create_service() {
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Configure zram + zswap on boot (RN=${RN}, NC=${NC})
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
ExecStart=$BOOT_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

show_summary() {
  info "参数：rn=${RN}（zram=${RN}×RAM），nc=${NC}（zswap 最大=${NC}×RAM，上限 100%）"
  echo

  ok "当前 swap 设备："
  swapon --show || echo "  (无)"

  if [ -d /sys/module/zswap/parameters ]; then
    echo
    ok "当前 zswap 参数（如果已启用）："
    grep . /sys/module/zswap/parameters/* 2>/dev/null || true
  else
    echo
    warn "内核未发现 zswap 模块目录：/sys/module/zswap/parameters"
  fi

  echo
  ok "已创建并启用 systemd 服务：$(basename "$SERVICE_FILE")"
  echo "  开机后会自动按 rn=${RN}, nc=${NC} 重新配置 zram + zswap。"
}

main() {
  need_root
  check_systemd

  validate_int "rn" "$RN"
  validate_int "nc" "$NC"

  info "生成开机配置脚本：$BOOT_SCRIPT"
  create_boot_script "$RN" "$NC"

  info "生成 systemd 服务：$SERVICE_FILE"
  create_service

  info "重新加载 systemd 并启用服务..."
  systemctl daemon-reload
  systemctl enable --now "$(basename "$SERVICE_FILE")"

  show_summary
}

main "$@"
