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
# 0) 每次启动清理「可再生缓存」—— 1GB 磁盘档的关键
#    npm install 的下载缓存默认落在 $HOME/.npm，多次重装会不断累积（实测沙箱
#    累积到 1.3GB），这是撑满 1GB 配额的头号元凶。这些全是可再生文件，删掉不影响
#    已装好的 node_modules，也不影响运行；下次 npm install 会按需重新下载。
# -----------------------------------------------------------------------------
cleanup_disk() {
    rm -rf "$BASE/.npm-cache" 2>/dev/null
    for d in "${HOME:-}" "$BASE" /home/container; do
        [ -n "$d" ] || continue
        rm -rf "$d/.npm/_cacache" "$d/.npm/_logs" 2>/dev/null
    done
    rm -rf /tmp/npm-* 2>/dev/null
}
cleanup_disk
log "磁盘清理完成，当前占用：$(du -sh "$BASE" 2>/dev/null | awk '{print $1}')（node_modules 属刚性依赖，勿删）"

# -----------------------------------------------------------------------------
# 1) 读取用户配置
# -----------------------------------------------------------------------------
# 环境变量优先：先存下来，等 conf 读完再覆盖回去
_ENV_CPU_LIMIT="${CPU_LIMIT:-}"
KOMARI_ENDPOINT=""; KOMARI_TOKEN=""; IGNORE_CERT=0; REPORT_INTERVAL=3; NODE_NAME=""
CPU_LIMIT=25            # 主进程 CPU 上限（%），0 = 不限制。见下方「CPU 节流」段
if [ -r "$CONF" ]; then
    . "$CONF"
else
    log "警告：找不到 komari.conf，探针将不启动"
fi
# 也允许用平台环境变量覆盖（方便不改文件）
[ -n "${AGENT_ENDPOINT:-}" ] && KOMARI_ENDPOINT="$AGENT_ENDPOINT"
[ -n "${AGENT_TOKEN:-}" ]    && KOMARI_TOKEN="$AGENT_TOKEN"
[ -n "$_ENV_CPU_LIMIT" ]     && CPU_LIMIT="$_ENV_CPU_LIMIT"

# -----------------------------------------------------------------------------
# 1) 准备 SillyTavern（幂等：已存在就跳过）
# -----------------------------------------------------------------------------
if [ ! -f "$ST_DIR/server.js" ]; then
    log "首次启动：浅克隆 SillyTavern release 分支 ..."
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 -b release https://github.com/SillyTavern/SillyTavern.git "$ST_DIR" \
            >>"$LOG" 2>&1 || log "git clone 失败（可改用网页上传源码包）"
        # 注意：不要删 .git！webpack 缓存目录名由 [pkgVersion, gitRevision, webpack.version]
        # 哈希而来，gitRevision 来自 git.revparse。删了 .git 会让它变 null、缓存 key 改变，
        # 导致下次启动重新全量编译（1核约205秒/峰值近1GB内存，512MB 下会 OOM）。
        # 37MB 的 .git 换来这个风险不划算，留着。
    else
        log "镜像里没有 git：请改用 Wispbyte 网页文件管理器上传 SillyTavern 源码到 $ST_DIR"
    fi
fi

if [ -f "$ST_DIR/package.json" ] && [ ! -d "$ST_DIR/node_modules" ]; then
    log "首次启动：安装依赖 npm install --omit=dev（这一步可能要几分钟）..."
    # 省盘：npm 缓存默认落在 HOME/.npm，实测 86 MB+，且多次重装会不断累积撑满 1GB。
    # 显式指定缓存目录，装完立即删除，保证稳态干净（不依赖容器 HOME 在哪）。
    NPM_CACHE="$BASE/.npm-cache"
    ( cd "$ST_DIR" && npm_config_cache="$NPM_CACHE" npm install --omit=dev --no-audit --no-fund ) >>"$LOG" 2>&1 \
        || log "npm install 失败，酒馆可能起不来，详见 $LOG"
    rm -rf "$NPM_CACHE"
    log "已清理 npm 缓存（省约 86 MB+）"
fi

# 别删 SillyTavern/dist 与 data/_webpack：那是 webpack 前端编译缓存（约 14 MB）。
# 1 核容器首次编译要 ~205 秒 / 峰值近 1 GB 内存；有缓存后重启仅 2 秒 / 300 MB。

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
browserLaunch:
  enabled: false
EOF
    log "SillyTavern 配置就绪：port=$PORT user=$ST_USER（密码见 $ST_DIR/config.yaml）"
fi

# -----------------------------------------------------------------------------
# 1.5) 预置前端编译产物 —— 消除「首次启动 205 秒满核编译」
#      Wispbyte 免费档按「平均 CPU 比例」做滥用检测，实测平均 37.03% 就会
#      站内通知并自动停服；而 server-main.js 里的 runWebpackCompiler() 是
#      无条件调用，1 核上要满跑约 205 秒。这里在版本匹配时直接注入 1.9 MB
#      的产物并跳过编译，从根上把这次 CPU 尖峰去掉。
#      版本不匹配 / 打补丁失败 → 自动回退到现场编译，仍有 CPU 节流器兜底。
# -----------------------------------------------------------------------------
SKIP_WEBPACK=0
PB_LIB="$BASE/prebuilt-lib.js"
PB_SHA="$BASE/prebuilt-lib.js.sha"
if [ -f "$ST_DIR/server.js" ] && [ -f "$PB_LIB" ] && [ -f "$PB_SHA" ]; then
    CUR_SHA=$( cd "$ST_DIR" && node -e "const c=require('crypto'),f=require('fs');process.stdout.write(c.createHash('sha256').update(f.readFileSync('public/lib.js')).digest('hex'))" 2>/dev/null )
    WANT_SHA=$(tr -d ' \r\n' < "$PB_SHA" 2>/dev/null)
    if [ -n "$CUR_SHA" ] && [ "$CUR_SHA" = "$WANT_SHA" ]; then
        if node "$BASE/prebuilt-patch.js" "$ST_DIR" >>"$LOG" 2>&1; then
            SKIP_WEBPACK=1
            PREBUILT_LIB="$PB_LIB"
            export SKIP_WEBPACK PREBUILT_LIB
            log "源码与预编译产物匹配，跳过 webpack 编译（省约 205 秒满核 / 避免 CPU 停服）"
        else
            log "预编译补丁未应用，回退现场编译（CPU 节流器仍生效）"
        fi
    else
        log "源码版本与预编译产物不一致，回退现场编译（CPU 节流器仍生效）"
    fi
else
    log "未找到预置产物，按原方式现场编译（CPU 节流器仍生效）"
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
#    同时给主进程套 CPU 节流器：按固定占空比 SIGSTOP/SIGCONT，把长时间平均
#    CPU 硬压在 CPU_LIMIT% 以内。这样即使预置产物没生效、必须现场编译，或
#    运行时突然来个 CPU 峰值，也不会再触发平台「平均 CPU 过高」自动停服。
# -----------------------------------------------------------------------------
if [ -f "$ST_DIR/server.js" ]; then
    cd "$ST_DIR" || exit 1
    case "$CPU_LIMIT" in ''|*[!0-9]*) CPU_LIMIT=25 ;; esac
    if [ "$CPU_LIMIT" -gt 0 ] 2>/dev/null && [ "$CPU_LIMIT" -lt 100 ] 2>/dev/null; then
        log "启动 SillyTavern（CPU 上限 ${CPU_LIMIT}%，跳过编译=$SKIP_WEBPACK）..."
        # setsid 让 node 成为独立进程组 leader，节流器才能安全地停整组
        # （覆盖 webpack 派生进程），又不会误伤同目录的 shim / agent 后台进程。
        if command -v setsid >/dev/null 2>&1; then
            setsid node server.js --listen &
        else
            node server.js --listen &
        fi
        NODE_PID=$!
        sh "$BASE/cpu-limit.sh" "$NODE_PID" "$CPU_LIMIT" >>"$LOG" 2>&1 &
        log "CPU 节流器已启动：pid=$NODE_PID 上限=${CPU_LIMIT}%（CPU_LIMIT=0 可关闭）"
        # 平台 Stop/Restart 发信号时把 node 一起带走，别留孤儿进程
        trap 'kill "$NODE_PID" 2>/dev/null' TERM INT
        wait "$NODE_PID"
    else
        log "启动 SillyTavern（CPU 未限制，跳过编译=$SKIP_WEBPACK）..."
        exec node server.js --listen
    fi
else
    log "SillyTavern 源码缺失：请上传源码到 $ST_DIR 后重启；此处保持空转以便排查"
    while :; do sleep 60; done
fi
