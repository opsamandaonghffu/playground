#!/bin/sh
# =============================================================================
# proc-shim.sh —— 让 Komari agent 在容器里"看见"容器自己，而不是宿主机
#
# 原理：
#   gopsutil(agent 用的采集库) 支持标准环境变量 HOST_PROC，把它读 /proc 的
#   根路径重定向到一个影子目录。本脚本从 cgroup 读取容器的真实限额/用量，
#   生成一份"缩小版 /proc"喂给它，于是：
#     - 内存 total/used  -> memory.max / memory.current   (不再显示宿主 123G)
#     - CPU 核数/使用率   -> cpu.max 配额 / cpu.stat       (不再显示宿主 32 核)
#     - 负载 load1/5/15   -> 由容器 CPU 用量换算
#     - 网络收发          -> 真实 /proc/net/dev（netns 本就隔离，直接拷贝）
#     - 磁盘              -> include_mountpoints 指向容器挂载点
#
#   Komari 自己读的那部分（进程数、TCP/UDP 连接数）不受 HOST_PROC 影响吗？
#   会。但我们在 config.json 里把 host_proc 设为空字符串（JSON 优先级最高），
#   覆盖 loadFromEnv 读到的 HOST_PROC，于是这部分走真实 /proc —— 而容器
#   pidns/netns 天然隔离，读到的正是容器自己的进程与连接。两全其美。
#
# 用法： proc-shim.sh <影子目录> [刷新间隔秒]
#   通常由 start.sh 后台循环调用，或由本脚本自己 --loop 常驻。
# =============================================================================
set -u

SHIM_DIR="${1:-./.proc-shim}"
INTERVAL="${2:-2}"
# 必须在任何 set -- 之前保存：下面读取 cpu.max 会用 set -- 重置位置参数，
# 若到文件末尾再判断 $3，--loop 标志早已被冲掉，常驻循环永远不会启动。
LOOP_FLAG="${3:-}"

# ---- cgroup 版本自探测 ----
CG=""
if [ -r /sys/fs/cgroup/memory.max ] || [ -r /sys/fs/cgroup/cpu.max ]; then
    CG="/sys/fs/cgroup"          # cgroup v2 (统一层级)
elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
    CG="/sys/fs/cgroup"          # cgroup v1 (分离层级)
fi

read_first() {  # read_first <文件> <默认值>
    [ -r "$1" ] && head -n1 "$1" 2>/dev/null || echo "$2"
}
num() {  # 只取数字，非法则返回默认
    v=$(echo "$1" | tr -cd '0-9')
    [ -n "$v" ] && echo "$v" || echo "${2:-0}"
}

# ---- 内存：限额 + 当前用量（字节）----
mem_limit=0; mem_used=0
if [ -n "$CG" ] && [ -r "$CG/memory.max" ]; then
    raw=$(read_first "$CG/memory.max" "")
    [ "$raw" != "max" ] && mem_limit=$(num "$raw" 0)
    mem_used=$(num "$(read_first "$CG/memory.current" 0)" 0)
elif [ -n "$CG" ] && [ -r "$CG/memory/memory.limit_in_bytes" ]; then
    raw=$(num "$(read_first "$CG/memory/memory.limit_in_bytes" 0)" 0)
    # v1 无限制时是个天文数字，超过 1PB 视为无限制
    [ "$raw" -lt 1000000000000000 ] 2>/dev/null && mem_limit="$raw"
    mem_used=$(num "$(read_first "$CG/memory/memory.usage_in_bytes" 0)" 0)
fi
# 回退：拿不到 cgroup 限额时用 /proc/meminfo（至少不会是 0）
if [ "$mem_limit" -le 0 ] 2>/dev/null; then
    kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    mem_limit=$(( $(num "$kb" 0) * 1024 ))
    kb_used=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    mem_used=$(( mem_limit - $(num "$kb_used" 0) * 1024 ))
fi
[ "$mem_used" -lt 0 ] 2>/dev/null && mem_used=0
[ "$mem_used" -gt "$mem_limit" ] 2>/dev/null && mem_used="$mem_limit"

# ---- CPU：配额核数 + 累计使用（微秒）----
cpu_quota=0; cpu_period=100000; cpu_usage=0
if [ -n "$CG" ] && [ -r "$CG/cpu.max" ]; then
    set -- $(read_first "$CG/cpu.max" "max 100000")
    q="$1"; p="${2:-100000}"
    [ "$q" != "max" ] && cpu_quota=$(num "$q" 0)
    cpu_period=$(num "$p" 100000)
    [ "$cpu_period" -le 0 ] 2>/dev/null && cpu_period=100000
    cpu_usage=$(num "$(awk '/^usage_usec/{print $2}' "$CG/cpu.stat" 2>/dev/null)" 0)
elif [ -n "$CG" ] && [ -r "$CG/cpu/cpu.cfs_quota_us" ]; then
    q=$(num "$(read_first "$CG/cpu/cpu.cfs_quota_us" -1)" -1)
    [ "$q" -gt 0 ] 2>/dev/null && cpu_quota="$q"
    cpu_period=$(num "$(read_first "$CG/cpu/cpu.cfs_period_us" 100000)" 100000)
    [ "$cpu_period" -le 0 ] 2>/dev/null && cpu_period=100000
    cpu_usage=$(num "$(read_first "$CG/cpuacct/cpuacct.usage" 0)" 0)
fi
# 核数：优先配额换算，其次 cpuset，最后 nproc
if [ "$cpu_quota" -gt 0 ] 2>/dev/null; then
    cpu_cores=$(( (cpu_quota + cpu_period - 1) / cpu_period ))
else
    cpuset=""
    [ -r "$CG/cpuset.cpus.effective" ] && cpuset=$(read_first "$CG/cpuset.cpus.effective" "")
    [ -z "$cpuset" ] && [ -r "$CG/cpuset/cpuset.cpus" ] && cpuset=$(read_first "$CG/cpuset/cpuset.cpus" "")
    if [ -n "$cpuset" ]; then
        cpu_cores=$(echo "$cpuset" | awk -F, '{n=0;for(i=1;i<=NF;i++){if($i~/^-?[0-9]+-[0-9]+$/){split($i,a,"-");n+=a[2]-a[1]+1}else n++}print n}')
    else
        cpu_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    fi
fi
[ "$cpu_cores" -lt 1 ] 2>/dev/null && cpu_cores=1

# CPU 累计 jiffies（USER_HZ=100, 1 jiffy = 10000 usec）
# gopsutil 的 cpu.Percent(0,false) 在进程内缓存上一次 TimesStat，靠两次采样差值：
#   total = user+system+nice+idle+iowait+irq+softirq+steal
#   busy  = total - idle - iowait
#   usage = (Δbusy)/(Δtotal)   （若 t2Busy<=t1Busy 或 t2All<=t1All 会返回 0 或 1）
#
# 关键：用「相对基准 + 状态文件」让 jiffies 从 0 开始单调增长，
# 贴近真实 /proc/stat 的数值形态（避免绝对 epoch 大数），并保证每次刷新都推进：
#   used_jif  = (当前 cgroup usage - 基准 usage)/10000      -> 容器真实 CPU 用量
#   total_jif = (当前墙钟秒 - 基准墙钟秒)*100*核数          -> 容器可分配的总 CPU 时间
#   idle_jif  = total_jif - used_jif
# 于是 Δbusy/Δtotal = 实际占用核数 / 配额核数 = 正确的 CPU 使用率(0~100%)
# 目录必须先建好，否则首次运行写 .cpu-state 会失败（Directory nonexistent）
mkdir -p "$SHIM_DIR" "$SHIM_DIR/1" "$SHIM_DIR/self" "$SHIM_DIR/net"

STATE="$SHIM_DIR/.cpu-state"
now_s=$(date +%s)
if [ -r "$STATE" ]; then
    . "$STATE"          # 载入 BASE_USAGE BASE_WALL
else
    BASE_USAGE=$cpu_usage
    BASE_WALL=$now_s
    printf 'BASE_USAGE=%s\nBASE_WALL=%s\n' "$BASE_USAGE" "$BASE_WALL" > "$STATE"
fi
d_usage=$(( cpu_usage - BASE_USAGE ))
d_wall=$(( now_s - BASE_WALL ))
[ "$d_usage" -lt 0 ] 2>/dev/null && d_usage=0      # cgroup 重置时兜底
[ "$d_wall" -lt 1 ] 2>/dev/null && d_wall=1        # 保证 total 每次都推进
cpu_busy_jif=$(( d_usage / 10000 ))
wall_jif=$(( d_wall * 100 * cpu_cores ))
# 保证 total 严格大于 busy，且每次刷新至少比上次多（配合高频刷新避免采样撞同值）
[ "$wall_jif" -le "$cpu_busy_jif" ] 2>/dev/null && wall_jif=$(( cpu_busy_jif + 100 ))
cpu_idle_jif=$(( wall_jif - cpu_busy_jif ))
[ "$cpu_idle_jif" -lt 0 ] 2>/dev/null && cpu_idle_jif=0

# 负载：用"最近 CPU 占用核数"近似（容器没有独立的 /proc/loadavg）
# 简化为 0，避免把宿主机 load 误报；Komari 面板会显示 0，属可接受降级
load1="0.00"; load5="0.00"; load15="0.00"

# ---- 生成影子 /proc ----
mkdir -p "$SHIM_DIR/1" "$SHIM_DIR/self" "$SHIM_DIR/net"

# meminfo（gopsutil 需要 MemTotal / MemFree / MemAvailable / Buffers / Cached ...）
mem_total_kb=$(( mem_limit / 1024 ))
mem_free_kb=$(( (mem_limit - mem_used) / 1024 ))
cat > "$SHIM_DIR/meminfo.tmp" <<EOF
MemTotal:       $mem_total_kb kB
MemFree:        $mem_free_kb kB
MemAvailable:   $mem_free_kb kB
Buffers:               0 kB
Cached:                0 kB
SwapCached:            0 kB
Active:                0 kB
Inactive:              0 kB
SwapTotal:             0 kB
SwapFree:              0 kB
Dirty:                 0 kB
Writeback:             0 kB
AnonPages:             0 kB
Mapped:                0 kB
Shmem:                 0 kB
Slab:                  0 kB
SReclaimable:          0 kB
SUnreclaim:            0 kB
KernelStack:           0 kB
PageTables:            0 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:    $mem_total_kb kB
Committed_AS:          0 kB
VmallocTotal:          0 kB
VmallocUsed:           0 kB
VmallocChunk:          0 kB
EOF
mv -f "$SHIM_DIR/meminfo.tmp" "$SHIM_DIR/meminfo"

# stat：第一行是总 CPU（cpu.Percent 用），再给每核一行（cpu.Counts 备用）
# 字段顺序：user nice system idle iowait irq softirq steal guest guest_nice
# 只在 user 放累计用量，避免 busy 翻倍；每核行按核数平摊
per_core_busy=$(( cpu_busy_jif / cpu_cores ))
per_core_idle=$(( cpu_idle_jif / cpu_cores ))
{
    printf 'cpu  %s 0 0 %s 0 0 0 0 0 0\n' "$cpu_busy_jif" "$cpu_idle_jif"
    i=0
    while [ "$i" -lt "$cpu_cores" ]; do
        printf 'cpu%s %s 0 0 %s 0 0 0 0 0 0\n' "$i" "$per_core_busy" "$per_core_idle"
        i=$(( i + 1 ))
    done
    printf 'intr 0 0\nctxt 0\nbtime 0\nprocesses 1\nprocs_running 1\nprocs_blocked 0\n'
} > "$SHIM_DIR/stat.tmp"
mv -f "$SHIM_DIR/stat.tmp" "$SHIM_DIR/stat"

# cpuinfo：cpu.Counts(true) 数 "processor" 行数；cpu.Info() 取 model name
model=$(awk -F: '/^model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}' /proc/cpuinfo 2>/dev/null)
[ -z "$model" ] && model="Container vCPU"
: > "$SHIM_DIR/cpuinfo.tmp"
i=0
while [ "$i" -lt "$cpu_cores" ]; do
    cat >> "$SHIM_DIR/cpuinfo.tmp" <<EOF
processor	: $i
vendor_id	: GenuineContainer
model name	: $model
cpu MHz		: 0.000
cache size	: 0 KB
physical id	: 0
siblings	: $cpu_cores
core id		: $i
cpu cores	: $cpu_cores
flags		: fpu

EOF
    i=$(( i + 1 ))
done
mv -f "$SHIM_DIR/cpuinfo.tmp" "$SHIM_DIR/cpuinfo"

printf '%s %s %s 1/1 1\n' "$load1" "$load5" "$load15" > "$SHIM_DIR/loadavg.tmp"
mv -f "$SHIM_DIR/loadavg.tmp" "$SHIM_DIR/loadavg"

# 网络：容器 netns 已隔离，直接拷贝真实计数（gopsutil 读 HOST_PROC/net/dev）
cp -f /proc/net/dev "$SHIM_DIR/net/dev.tmp" 2>/dev/null && mv -f "$SHIM_DIR/net/dev.tmp" "$SHIM_DIR/net/dev"
# 磁盘分区：给一份只含根挂载的 mountinfo，避免枚举到宿主机分区
cat > "$SHIM_DIR/1/mountinfo.tmp" <<EOF
1 1 0:1 / / rw,relatime - overlay overlay rw
EOF
mv -f "$SHIM_DIR/1/mountinfo.tmp" "$SHIM_DIR/1/mountinfo"
cp -f "$SHIM_DIR/1/mountinfo" "$SHIM_DIR/self/mountinfo" 2>/dev/null

# 输出一行诊断，方便在 Wispbyte Console 里核对"探的是不是容器"
printf '[proc-shim] mem=%s/%s MB cores=%s cpu.usage=%sus HOST_PROC=%s\n' \
    "$(( mem_used / 1048576 ))" "$(( mem_limit / 1048576 ))" "$cpu_cores" "$cpu_usage" "$SHIM_DIR"

# ---- 常驻循环（--loop 时）----
if [ "$LOOP_FLAG" = "--loop" ]; then
    while :; do
        sleep "$INTERVAL"
        # 必须用 sh 显式解释执行：本文件经网页/文件管理器上传后常是 644，
        # 直接 "$0" 会 permission denied，导致 stat 永不刷新、CPU 使用率恒为 0。
        sh "$0" "$SHIM_DIR" "$INTERVAL" >/dev/null 2>&1 || true
    done
fi
