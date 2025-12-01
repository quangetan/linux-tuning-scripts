#!/usr/bin/env bash
#!/usr/bin/env bash
#
# 一键开启 zram + zswap（systemd 系统）
# 使用前请确认：内核已启用 zram/zswap（大部分发行版默认开启模块）。
#

set -u

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "本脚本需要 root 权限，请使用 sudo 运行："
    echo "  sudo $0"
    exit 1
  fi
}

check_systemd() {
  if ! [ -d /run/systemd/system ]; then
    echo "看起来当前系统不是 systemd（/run/systemd/system 不存在），本脚本暂不支持。"
    exit 1
  fi
}

create_zram_script() {
  cat >/usr/local/sbin/setup-zram-swap.sh <<'EOF'
#!/usr/bin/env bash

# 配置 zram0 为压缩 swap

# 如已有 zram0 swap，先关掉
swapoff /dev/zram0 2>/dev/null || true

# 加载 zram 模块
if ! modprobe zram; then
  echo "无法加载 zram 模块，可能内核未启用。"
  exit 0
fi

# 使用 CPU 核数作为并发压缩流数（某些新内核已不需要，可忽略失败）
if command -v nproc >/dev/null 2>&1; then
  CPUS=$(nproc)
  if [ -e /sys/block/zram0/max_comp_streams ]; then
    echo "$CPUS" > /sys/block/zram0/max_comp_streams 2>/dev/null || true
  fi
fi

# 选择压缩算法：优先 lz4，其次 zstd，最后保持默认
if [ -e /sys/block/zram0/comp_algorithm ]; then
  ALGS=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null || echo "")
  if echo "$ALGS" | grep -qw lz4; then
    echo lz4 > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  elif echo "$ALGS" | grep -qw zstd; then
    echo zstd > /sys/block/zram0/comp_algorithm 2>/dev/null || true
  fi
fi

# 根据总内存计算 zram 大小，这里取 75% 作为示例
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [ -z "$MEM_KB" ]; then
  echo "无法获取内存大小，跳过 zram 配置。"
  exit 0
fi

# 75% 的内存
ZRAM_KB=$(( MEM_KB * 75 / 100 ))
ZRAM_BYTES=$(( ZRAM_KB * 1024 ))

echo "$ZRAM_BYTES" > /sys/block/zram0/disksize

# 建立并启用 swap，优先级设高一点（200）
mkswap -f /dev/zram0
swapon -p 200 /dev/zram0

echo "zram swap 已启用："
swapon --show | grep zram || swapon --show
EOF

  chmod +x /usr/local/sbin/setup-zram-swap.sh
}

create_zram_service() {
  cat >/etc/systemd/system/zram-swap.service <<'EOF'
[Unit]
Description=Configure zram swap
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-zram-swap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

create_zswap_script() {
  cat >/usr/local/sbin/setup-zswap.sh <<'EOF'
#!/usr/bin/env bash

# 启用并调整 zswap 参数（如果内核支持）

PARAM_DIR="/sys/module/zswap/parameters"

if [ ! -d "$PARAM_DIR" ]; then
  echo "内核似乎未启用 zswap 模块（$PARAM_DIR 不存在），跳过 zswap 配置。"
  exit 0
fi

# 选择压缩算法：优先 lz4，其次 zstd
if [ -e "$PARAM_DIR/compressor" ]; then
  ALGS=$(cat "$PARAM_DIR/compressor" 2>/dev/null || echo "")
  if echo "$ALGS" | grep -qw lz4; then
    echo lz4 > "$PARAM_DIR/compressor" 2>/dev/null || true
  elif echo "$ALGS" | grep -qw zstd; then
    echo zstd > "$PARAM_DIR/compressor" 2>/dev/null || true
  fi
fi

# 选择 zpool：优先 z3fold，其次 zbud，若都不支持则保持默认
if [ -e "$PARAM_DIR/zpool" ]; then
  ZPOOLS=$(cat "$PARAM_DIR/zpool" 2>/dev/null || echo "")
  if echo "$ZPOOLS" | grep -qw z3fold; then
    echo z3fold > "$PARAM_DIR/zpool" 2>/dev/null || true
  elif echo "$ZPOOLS" | grep -qw zbud; then
    echo zbud > "$PARAM_DIR/zpool" 2>/dev/null || true
  fi
fi

# 控制 zswap 使用的最大内存百分比（相对于系统内存）
if [ -e "$PARAM_DIR/max_pool_percent" ]; then
  echo 20 > "$PARAM_DIR/max_pool_percent" 2>/dev/null || true   # 20% 作为示例
fi

# 接受到达某百分比后才开始写回后端 swap（降低抖动）
if [ -e "$PARAM_DIR/accept_threshold_percent" ]; then
  echo 90 > "$PARAM_DIR/accept_threshold_percent" 2>/dev/null || true
fi

# 真正启用 zswap
if [ -e "$PARAM_DIR/enabled" ]; then
  echo Y > "$PARAM_DIR/enabled" 2>/dev/null || echo 1 > "$PARAM_DIR/enabled" 2>/dev/null || true
fi

echo "zswap 参数已尝试配置："
for f in enabled compressor zpool max_pool_percent accept_threshold_percent; do
  [ -e "$PARAM_DIR/$f" ] && echo "$f=$(cat "$PARAM_DIR/$f")"
done
EOF

  chmod +x /usr/local/sbin/setup-zswap.sh
}

create_zswap_service() {
  cat >/etc/systemd/system/zswap.service <<'EOF'
[Unit]
Description=Configure zswap
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/setup-zswap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
}

enable_services() {
  systemctl daemon-reload
  systemctl enable --now zram-swap.service
  systemctl enable --now zswap.service || true

  echo
  echo "当前 swap 设备："
  swapon --show || echo "当前没有启用任何 swap 设备。"

  echo
  echo "zswap 当前参数（如果支持）："
  if [ -d /sys/module/zswap/parameters ]; then
    grep . /sys/module/zswap/parameters/* 2>/dev/null || true
  else
    echo "内核未发现 zswap 模块。"
  fi
}

main() {
  need_root
  check_systemd

  echo "创建 zram 配置脚本和 systemd 服务..."
  create_zram_script
  create_zram_service

  echo "创建 zswap 配置脚本和 systemd 服务..."
  create_zswap_script
  create_zswap_service

  echo "启用并立即启动相关服务..."
  enable_services

  echo
  echo "完成。重启后 zram + zswap 会自动生效。"
}

main "$@"
