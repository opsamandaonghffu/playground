#!/bin/sh
# =============================================================================
# start.sh —— Wispbyte Startup Command 填这一条即可：  sh /home/container/start.sh
#            （若工作目录不是 /home/container，把路径换成实际目录）
#
# 一个进程树里同时跑三件事：
#   1) proc-shim.sh  后台常驻，持续把容器 cgroup 真值写进影子 /proc
#   2) komari-agent  后台常驻，读影子 /proc，把容器性能上报到面板
#   3) SillyTavern   前台主进程（Wispbyte 靠它判定服务器在线，不能放后台）
#
# 依赖：预置镜像选 Node.js 20/22；首次启动会自动浅克隆 SillyTavern 并 npm install。
# =============================================================================
set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
cd "$BASE" || exit 1
ST_DIR="$BASE/SillyTavern"
SHIM_DIR="$BASE/.proc-shim"
AGENT_BIN="$BASE/komari-agent"
CONF="$BASE/komari.conf"
RUNTIME_CONF="$BASE/.komari-runtime.json"
LOG="$BASE/komari-agent.log"

log() { printf '[start] %s\n' "$*" | tee -a "$LOG"; }
log "启动，工作目录=$BASE，内核=$(uname -srm 2>/dev/null || echo unknown)"

# -----------------------------------------------------------------------------
# 0) 读取用户配置
# -----------------------------------------------------------------------------
KOMARI_ENDPOINT=""; KOMARI_TOKEN=""; IGNORE_CERT=0; REPORT_INTERVAL=3; NODE_NAME=""
if [ -r "$CONF" ]; then
    . "$CONF"
else
    log "警告：找不到 komari.conf，探针将不启动"
fi
# 也允许用平台环境变量覆盖（方便不改文件）
[ -n "${AGENT_ENDPOINT:-}" ] && KOMARI_ENDPOINT="$AGENT_ENDPOINT"
[ -n "${AGENT_TOKEN:-}" ]    && KOMARI_TOKEN="$AGENT_TOKEN"

# -----------------------------------------------------------------------------
# 1) 准备 SillyTavern（幂等：已存在就跳过）
# -----------------------------------------------------------------------------
if [ ! -f "$ST_DIR/server.js" ]; then
    log "首次启动：浅克隆 SillyTavern release 分支 ..."
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 -b release https://github.com/SillyTavern/SillyTavern.git "$ST_DIR" \
            >>"$LOG" 2>&1 || log "git clone 失败（可改用网页上传源码包）"
    else
        log "镜像里没有 git：请改用 Wispbyte 网页文件管理器上传 SillyTavern 源码到 $ST_DIR"
    fi
fi

if [ -f "$ST_DIR/package.json" ] && [ ! -d "$ST_DIR/node_modules" ]; then
    log "首次启动：安装依赖 npm install --omit=dev（这一步可能要几分钟）..."
    ( cd "$ST_DIR" && npm install --omit=dev --no-audit --no-fund ) >>"$LOG" 2>&1 \
        || log "npm install 失败，酒馆可能起不来，详见 $LOG"
fi

# 生成 SillyTavern 的 config.yaml（端口对接面板、关白名单、开 BasicAuth）
if [ -f "$ST_DIR/server.js" ]; then
    PORT="${SERVER_PORT:-${PORT:-${P_PORT:-8000}}}"
    ST_USER="${ST_USER:-admin}"
    ST_PASS="${ST_PASS:-}"
    if [ -z "$ST_PASS" ]; then
        ST_PASS=$( (head -c 24 /dev/urandom 2>/dev/null || date +%s) | od -An -tx1 | tr -d ' \n' | cut -c1-20 )
    fi
    cat > "$ST_DIR/config.yaml" <<EOF
# 由 start.sh 自动生成（Wispbyte 容器部署）
dataRoot: ./data
listen: true
port: $PORT
whitelistMode: false
whitelist:
  - 127.0.0.1
basicAuthMode: true
basicAuthUser:
  username: $ST_USER
  password: $ST_PASS
enableCorsProxy: false
disableCsrf: false
EOF
    log "SillyTavern 配置就绪：port=$PORT user=$ST_USER（密码见 $ST_DIR/config.yaml）"
fi

# -----------------------------------------------------------------------------
# 2) 准备 Komari agent 二进制（幂等：已存在就跳过；离线时也可用网页上传）
#    面板 1.5.1(f0cc0fb) 对应 agent 稳定版 1.5.11，协议 v2 兼容
# -----------------------------------------------------------------------------
AGENT_URLS="
https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64
https://gh-proxy.com/https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64
https://ghfast.top/https://github.com/komari-monitor/komari-agent/releases/download/1.5.11/komari-agent-linux-amd64
"
if [ ! -x "$AGENT_BIN" ]; then
    if [ -n "$KOMARI_TOKEN" ]; then
        log "首次启动：下载 komari-agent 1.5.11 ..."
        for u in $AGENT_URLS; do
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL --max-time 120 "$u" -o "$AGENT_BIN.tmp" >>"$LOG" 2>&1 && break
            elif command -v wget >/dev/null 2>&1; then
                wget -q -T 120 -O "$AGENT_BIN.tmp" "$u" >>"$LOG" 2>&1 && break
            fi
        done
        if [ -s "$AGENT_BIN.tmp" ] && chmod +x "$AGENT_BIN.tmp" && "$AGENT_BIN.tmp" --help >/dev/null 2>&1; then
            mv -f "$AGENT_BIN.tmp" "$AGENT_BIN"
            log "komari-agent 下载完成"
        else
            rm -f "$AGENT_BIN.tmp"
            log "下载失败：请手动把 komari-agent-linux-amd64 放到 $AGENT_BIN（探针本次不启动）"
        fi
    else
        log "KOMARI_TOKEN 为空，跳过探针下载（酒馆照常启动）"
    fi
fi

# -----------------------------------------------------------------------------
# 3) 生成 proc 影子 + 起刷新循环 + 起探针
# -----------------------------------------------------------------------------
PROBE_ON=0
if [ -x "$AGENT_BIN" ] && [ -n "$KOMARI_TOKEN" ] && [ -n "$KOMARI_ENDPOINT" ]; then
    PROBE_ON=1
else
    [ -x "$AGENT_BIN" ] && [ -z "$KOMARI_TOKEN" ] && log "token 未填，探针不启动"
    [ -z "$KOMARI_ENDPOINT" ] && log "面板地址未填，探针不启动"
fi

if [ "$PROBE_ON" = 1 ]; then
    # shim 必须刷得比 agent 采样更勤，否则 gopsutil 两次采样会读到同一份 stat，
    # 导致 CPU 使用率算成 0。固定 1 秒刷新，agent 间隔 REPORT_INTERVAL(默认 3s)。
    SHIM_TICK=1
    # 每次启动重建影子目录：Wispbyte 磁盘是持久化的，残留的 .cpu-state 会带着
    # 上次启动的 BASE_WALL，导致 d_wall 变成巨大旧值、CPU 使用率被稀释成 ~0。
    rm -rf "$SHIM_DIR"
    # 先生成第一份快照（agent 启动立刻要读）
    sh "$BASE/proc-shim.sh" "$SHIM_DIR" "$SHIM_TICK" 2>&1 | tee -a "$LOG"

    # 后台常驻刷新，保持 stat/meminfo 随容器用量变化
    sh "$BASE/proc-shim.sh" "$SHIM_DIR" "$SHIM_TICK" --loop >>"$LOG" 2>&1 &
    SHIM_PID=$!

    # 生成 agent 运行时 JSON 配置
    #   host_proc 必须为空：覆盖环境变量，让进程数/连接数走真实 /proc（容器隔离、准确）
    #   memory_include_cache：强制 Ram() 走 gopsutil -> HOST_PROC/meminfo
    #   include_mountpoints：只统计容器数据盘，绕开宿主机分区枚举
    #   max_retries/reconnect_interval：面板反代不支持 WebSocket 时，约 6 秒
    #     即从重试切到 v2 POST fallback，避免节点迟迟不上线（默认要 ~20 秒）
    MOUNTPOINT="${INCLUDE_MOUNTPOINTS:-$BASE}"
    IGNORE_JSON=false; [ "$IGNORE_CERT" = 1 ] && IGNORE_JSON=true
    cat > "$RUNTIME_CONF" <<EOF
{
  "endpoint": "$KOMARI_ENDPOINT",
  "token": "$KOMARI_TOKEN",
  "interval": $REPORT_INTERVAL,
  "host_proc": "",
  "memory_include_cache": true,
  "include_mountpoints": "$MOUNTPOINT",
  "exclude_nics": "lo,docker*,veth*,br-*,cni*,sit*,tun*,tap*",
  "disable_auto_update": true,
  "disable_web_ssh": true,
  "ignore_unsafe_cert": $IGNORE_JSON,
  "disable_compression": false,
  "info_report_interval": 5,
  "max_retries": 2,
  "reconnect_interval": 2
}
EOF
    log "探针配置就绪：endpoint=$KOMARI_ENDPOINT mount=$MOUNTPOINT"

    # HOST_PROC 只对 agent 进程生效；shim 自己不能带这个变量（否则它读自己造的文件）
    # shellcheck disable=SC2086
    HOST_PROC="$SHIM_DIR" "$AGENT_BIN" --config "$RUNTIME_CONF" >>"$LOG" 2>&1 &
    AGENT_PID=$!
    log "komari-agent 已启动 pid=$AGENT_PID，影子目录=$SHIM_DIR"
    log "面板里应看到：内存≈容器限额、CPU核数≈配额核数，而不是宿主机数值"
else
    log "探针未启用，仅启动 SillyTavern"
fi

# -----------------------------------------------------------------------------
# 4) 前台启动 SillyTavern（保持主进程，Wispbyte 才认为服务器在线）
# -----------------------------------------------------------------------------
if [ -f "$ST_DIR/server.js" ]; then
    log "启动 SillyTavern ..."
    cd "$ST_DIR" || exit 1
    exec node server.js --listen
else
    log "SillyTavern 源码缺失：请上传源码到 $ST_DIR 后重启；此处保持空转以便排查"
    while :; do sleep 60; done
fi
