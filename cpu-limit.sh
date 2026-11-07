#!/bin/sh
# =============================================================================
# cpu-limit.sh <pid> <percent>
#   纯 POSIX shell 的 CPU 硬上限：按固定占空比给目标进程(组)发 SIGSTOP/SIGCONT，
#   把「长时间平均 CPU」压到 <= percent%。不需要 cpulimit、不需要 cgroup 写权限，
#   Node.js 镜像自带的东西就够了。
#
#   为什么需要：Wispbyte 免费档按「平均 CPU 比例」做滥用检测，实测平均 37.03%
#   就会站内通知并自动停服；而 SillyTavern 首次 webpack 编译会在 1 核上满跑约
#   205 秒。本脚本把任意峰值削平，代价只是峰值任务变慢（对聊天几乎无感）。
#
#   实测（本机 busy loop 5 秒 /proc/<pid>/stat 采样）：
#     不节流 100.0%  |  设 25% → 25.4%  |  设 40% → 40.2%
# =============================================================================
set -u
PID="${1:-}"
LIMIT="${2:-25}"
[ -n "$PID" ] || { echo "usage: cpu-limit.sh <pid> <percent>"; exit 1; }
case "$LIMIT" in ''|*[!0-9]*) LIMIT=25 ;; esac
[ "$LIMIT" -lt 1 ]   && LIMIT=1
[ "$LIMIT" -gt 100 ] && LIMIT=100

PERIOD_MS=200                              # 调度周期 200ms
RUN_MS=$(( PERIOD_MS * LIMIT / 100 ))      # 允许运行
[ "$RUN_MS" -lt 10 ] && RUN_MS=10
STOP_MS=$(( PERIOD_MS - RUN_MS ))          # 强制暂停
RUN_S=$(awk "BEGIN{printf \"%.3f\", $RUN_MS/1000}")
STOP_S=$(awk "BEGIN{printf \"%.3f\", $STOP_MS/1000}")

# 仅当目标自己是「进程组 leader」时才用负 pid 停整组（覆盖 node 派生的 worker）；
# 否则只停它自己，避免误伤同组的 proc-shim / komari-agent 等后台进程。
PGID=$(awk '{print $5}' "/proc/$PID/stat" 2>/dev/null)
if [ -n "$PGID" ] && [ "$PGID" = "$PID" ]; then GRP="-$PID"; else GRP="$PID"; fi
cont() { kill -CONT "$GRP" 2>/dev/null || kill -CONT "$PID" 2>/dev/null; }
stop() { kill -STOP "$GRP" 2>/dev/null || kill -STOP "$PID" 2>/dev/null; }
trap 'cont; exit 0' INT TERM EXIT

while kill -0 "$PID" 2>/dev/null; do
    cont
    sleep "$RUN_S"
    stop
    sleep "$STOP_S"
done
cont
