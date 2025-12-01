#!/usr/bin/env bash
# 交互菜单：配置 zram / zswap（仅当前运行期生效，重启后恢复）
# 选项：
#   1) 同时开启 zram + zswap
#   2) 只开启 zswap
#   3) 只开启 zram
#   4) 关闭 zram + zswap
#   q) 退出

set -euo pipefail

# 可按需修改默认比例
DEFAULT_ZRAM_PERCENT=75      # zram 默认占用内存百分比
DEFAULT_ZSWAP_MAX_PERCENT=20 # zswap 池大小占内存百分比

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行：sudo $0"
    exit 1
  fi
}

enable_zram() {
  echo "==> 启用 zram swap..."

  read -rp "zram 占用内存百分比 (默认 ${DEFAULT_ZRAM_PERCENT}%): " ZP
  ZP=${ZP:-$DEFAULT_ZRAM_PERCENT}

  if ! modprobe zram 2>/dev/null; then
    echo "无法加载 zram 模块，可能内核不支持。"
    return 1
  fi

  swapoff /dev/zram0 2>/dev/null || true

  MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  if [ -z "$MEM_KB" ]; then
    echo "无法获取内存大小，退出。"
    return 1
  fi

  ZRAM_KB=$(( MEM_KB * ZP / 100 ))
  echo $(( ZRAM_KB * 1024 )) > /sys/block/zram0/disksize

  if [ -e /sys/block/zram0/comp_algorithm ]; then
    ALGS=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
    if echo "$ALGS" | grep -qw lz4; then
      echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    elif echo "$ALGS" | grep -qw zstd; then
      echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    fi
  fi

  mkswap -f /dev/zram0
  swapon -p 200 /dev/zram0

  echo "zram 已启用："
  swapon --show | grep zram || swapon --show || true
}

enable_zswap() {
  echo "==> 启用 zswap（内核支持才会成功）..."

  PARAM_DIR=/sys/module/zswap/parameters
  if [ ! -d "$PARAM_DIR" ]; then
    echo "未发现 zswap 模块参数目录 ($PARAM_DIR)，可能内核未启用 zswap。"
    return 1
  fi

  read -rp "zswap 最大池大小占内存百分比 (默认 ${DEFAULT_ZSWAP_MAX_PERCENT}%): " MP
  MP=${MP:-$DEFAULT_ZSWAP_MAX_PERCENT}

  if [ -e "$PARAM_DIR/max_pool_percent" ]; then
    echo "$MP" > "$PARAM_DIR/max_pool_percent" 2>/dev/null || true
  fi

  if [ -e "$PARAM_DIR/compressor" ]; then
    ALGS=$(cat "$PARAM_DIR/compressor" 2>/dev/null || echo "")
    if echo "$ALGS" | grep -qw lz4; then
      echo lz4 > "$PARAM_DIR/compressor" 2>/dev/null || true
    elif echo "$ALGS" | grep -qw zstd; then
      echo zstd > "$PARAM_DIR/compressor" 2>/dev/null || true
    fi
  fi

  if [ -e "$PARAM_DIR/enabled" ]; then
    echo Y > "$PARAM_DIR/enabled" 2>/dev/null || echo 1 > "$PARAM_DIR/enabled" 2>/dev/null || true
  fi

  echo "当前 zswap 参数："
  grep . "$PARAM_DIR"/* 2>/dev/null || true
}

disable_all() {
  echo "==> 关闭 zram + zswap..."

  swapoff /dev/zram0 2>/dev/null || true

  PARAM_DIR=/sys/module/zswap/parameters
  if [ -e "$PARAM_DIR/enabled" ]; then
    echo N > "$PARAM_DIR/enabled" 2>/dev/null || echo 0 > "$PARAM_DIR/enabled" 2>/dev/null || true
  fi

  echo "已尝试关闭。当前 swap："
  swapon --show || echo "没有启用的 swap。"
}

show_status() {
  echo
  echo "==== 当前状态 ===="
  echo "swap 设备："
  swapon --show || echo "无"

  if [ -d /sys/module/zswap/parameters ]; then
    echo
    echo "zswap 参数："
    grep . /sys/module/zswap/parameters/* 2>/dev/null || true
  else
    echo
    echo "zswap：内核未发现模块 /sys/module/zswap/parameters"
  fi
  echo "==================="
  echo
}

menu() {
  while true; do
    echo "请选择操作："
    echo "  1) 同时开启 zram + zswap"
    echo "  2) 只开启 zswap"
    echo "  3) 只开启 zram"
    echo "  4) 关闭 zram + zswap"
    echo "  q) 退出"
    read -rp "输入选项: " choice

    case "$choice" in
      1)
        enable_zram || true
        enable_zswap || true
        show_status
        ;;
      2)
        enable_zswap || true
        show_status
        ;;
      3)
        enable_zram || true
        show_status
        ;;
      4)
        disable_all
        show_status
        ;;
      q|Q)
        echo "退出。"
        break
        ;;
      *)
        echo "无效选项。"
        ;;
    esac
  done
}

need_root
menu
