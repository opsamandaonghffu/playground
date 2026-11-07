# Wispbyte 部署 SillyTavern + 内置 Komari 探针（容器感知版）

一套文件，Wispbyte 免费容器（512 MB / 1 GB / Node.js 镜像）里同时跑云酒馆和 Komari 性能探针。

**两个重点：**
1. 探针上报的是**容器自己**的 CPU / 内存 / 磁盘 / 网络，不是宿主机（见「四」）。
2. 内置 **CPU 限额 + 跳过前端编译**，专门解决平台「平均 CPU 使用率过高 → 自动停服」（见「三·六」）。

---

## 一、文件清单

| 文件 | 作用 |
|---|---|
| `start.sh` | **主入口**，Startup Command 填 `sh /home/container/start.sh` |
| `index.js` | **兜底入口**：面板只允许指定 `node <主文件>` 时，把主文件指向它，由它转交 `start.sh` |
| `komari.conf` | **你只需要改这个**：面板地址 + token + `CPU_LIMIT`（后面自己填） |
| `proc-shim.sh` | 容器感知核心：从 cgroup 读真值，生成影子 `/proc` |
| `cpu-limit.sh` | **CPU 硬上限**：纯 shell 占空比节流，把主进程压在 `CPU_LIMIT%` 内 |
| `prebuilt-lib.js` | 预编译好的前端产物（1.9 MB），用来跳过 205 秒满核 webpack 编译 |
| `prebuilt-lib.js.sha` | 产物对应的 `public/lib.js` 哈希，源码版本不符时自动回退到现场编译 |
| `prebuilt-patch.js` | 一次性给 SillyTavern 打最小补丁，在运行时把产物放到正确目录并跳过编译 |
| `.gitignore` | 排除凭据、二进制、源码（避免公开仓库带 token） |
| `README.md` | 本文 |

运行时自动生成的（不用管）：`SillyTavern/`（浅克隆源码）、`komari-agent`（二进制）、`.proc-shim/`（影子 /proc）、`.komari-runtime.json`、`komari-agent.log`。

---

## 二、部署三步

### 1. 建服务器
- 镜像选 **Node.js 20 或 22**。SillyTavern 的 `engines` 是 `node >= 20`；若平台实际给的是 **v19.x**，`npm install` 会报 `EBADENGINE` 警告，建议到 **Startup → Docker image** 选 `nodejs_22` 并点 **Use this image**（改镜像要重启）。
- 把本仓库文件放进容器根目录（GitHub 集成拉取，或网页文件管理器上传）。**Files 面板打开就是这些文件，看不到 `/home/container` 这一层是正常的**——它就是当前目录，别新建同名文件夹。

### 2. Startup：把启动命令改成 sh

进 **Startup** 页，点右上角 **✏️ Edit**，把默认那一整条（结尾是 `/usr/local/bin/node /home/container/start.sh`）**整条删空**，只填：

```
sh /home/container/start.sh
```

保存后重启。

> ⚠️ **别把「主文件 / JS_FILE」变量指向 `start.sh`**：这个镜像固定用 `node <主文件>` 启动，会把 `.sh` 当 JS 解析，报 `SyntaxError: Invalid or unexpected token`（指向 `start.sh:2`）。
> 若面板不允许整条编辑、只能改变量值，就把主文件改成 **`index.js`**（包里已附，它内部转交 `start.sh`，代价是多一个常驻 node 进程）。
> 相对路径 `sh start.sh` 也行——`start.sh` 用自身所在目录定位同伴文件。

> 端口不用管，`start.sh` 会探测 `SERVER_PORT` / `PORT` / `P_PORT`，默认 8000，并自动写进酒馆 `config.yaml`。若面板端口变量名不同，在 **Environment** 里加 `SERVER_PORT=<分配的端口>`。
> 整条替换后，平台原来那段 `git pull` / `npm install` 会一起消失，没关系——`start.sh` 自己会 clone + install。**Packages** 保持空。

### 3. 填 `komari.conf`（可以后填，不影响酒馆启动）

仓库里两项都是**占位符 / 空值**，部署前把两行都改成自己的：

```sh
KOMARI_ENDPOINT=https://你的面板域名        # 原为 https://YOUR_PANEL_DOMAIN
KOMARI_TOKEN=粘贴面板添加节点后给出的那串 token   # 原为空
```

> 两项都填了探针才会启动；只填一个（或还留着 `YOUR_PANEL_DOMAIN`）探针会跳过，酒馆照常能开。
> 保存后重启服务器。也可以不改文件，直接在 Wispbyte 环境变量里设 `AGENT_ENDPOINT` / `AGENT_TOKEN`（优先级更高）。

`CPU_LIMIT` 是**CPU 上限**（默认 `25`，单位 %）——站内通知「平均 CPU 37.03% → 服务器已停止」就是它要防的。
**不用改，默认就行**；详见「三·六」。想临时关掉可设 `0` 或环境变量 `CPU_LIMIT=0`（有再次被停服的风险）。

> `REPORT_INTERVAL` 别设成 1：影子目录固定每 1 秒刷新一次，agent 采样间隔必须大于它，否则可能两次采样读到同一份 `stat`、CPU 使用率算成 0。默认 3 即可。

---

## 三、验收（按顺序看）

1. **Console 日志**出现这几行就说明链路起来了：
   ```
   [start] 源码与预编译产物匹配，跳过 webpack 编译（省约 205 秒满核 / 避免 CPU 停服）
   [start] 启动 SillyTavern（CPU 上限 25%，跳过编译=1）...
   [start] CPU 节流器已启动：pid=... 上限=25%
   [prebuilt] webpack compile skipped -> .../dist/_webpack/.../output/lib.js
   [proc-shim] mem=xxx/512 MB cores=1 cpu.usage=... HOST_PROC=/home/container/.proc-shim
   [start] komari-agent 已启动 pid=...
   ```
   > 看到 `源码与预编译产物匹配` + `CPU 节流器已启动` 就说明**不会再因 CPU 被停服**；
   > 若看到 `回退现场编译` 也不慌，节流器仍在，只是首次要多等几分钟。
2. **Komari 面板**：节点上线，内存总量 ≈ 512 MB（不是几十 GB），CPU 核数 ≈ 配额核数（不是 32/64），CPU 使用率随聊天/导入卡波动。
3. **酒馆**：打开分配的 `IP:端口`，先弹 BasicAuth（用户 `admin`，密码在 `SillyTavern/config.yaml`，或环境变量 `ST_USER`/`ST_PASS` 自定义），导卡发一句话看回复是否完整。
4. 想确认探针读到的是不是容器值，可在 Console 直接跑：
   ```sh
   HOST_PROC=/home/container/.proc-shim ./komari-agent check-mem --memory-include-cache
   ```
   输出 `[includeCache] Total: ... (512 MiB)` 就对了。

### 本地已验证（真实 agent 1.5.11 + 假面板抓包）

制作时在 8 GiB / 4 核的容器里跑过端到端验证：用最小假面板接收 v2 JSON-RPC，
真 agent 上报的 `agent.basicInfo` / `agent.report` 逐帧解包核对，并在中途制造 2 核满载负载。

| 指标 | 实测上报值 | 宿主机真值 | 结论 |
|---|---|---|---|
| 内存总量 `mem_total` | 8,589,934,592 B = 8192 MiB | 约 123 GiB | ✅ 容器值 |
| 内存已用 `ram.used` | ≈ 1946 MiB | — | ✅ 容器值 |
| CPU 核数 `cpu_cores` | 4 | 32 | ✅ 容器值 |
| CPU 使用率（空闲） | 1.6% → 5.4% | — | ✅ 接近 0 |
| CPU 使用率（2 核满载） | 52.4% ~ 52.5% | — | ✅ 2/4 核，随负载变化 |
| 进程数 / TCP 连接数 | 49~51 / 51~85 | — | ✅ 走真实 `/proc`，pidns/netns 隔离 |
| 虚拟化 `virtualization` | docker | — | ✅ |

裸跑官方 agent 的基线是 **123 GB / 32 核**，加影子 /proc 后变为 **8 GB / 4 核**，
CPU 使用率从恒定 0.001% 变为真实随负载波动。

还按 `start.sh` 的**原样启动序列**复测过一次（默认 `interval=3`、含影子目录重建、后台 loop、
`HOST_PROC` 启动）：假面板故意不支持 WebSocket，agent 约 6 秒切到 **v2 POST fallback**，
随后 6 帧 report 的 CPU 为 `2.6% → 52.5% → 39.3% → 52.4% → 52.3% → 52.4%`，
内存稳定 `1958/8192 MiB`，磁盘已用 `0.1 GiB`，进程数 51，TCP 连接 71→119，日志无 error。

---

## 三·五、1GB 磁盘 / 512MB 内存实测（重要）

在沙箱里造了 **1GB tmpfs 磁盘 + 512MB cgroup 内存硬限制**，1:1 复现首次安装与编译，逐项量过。

### 磁盘账单（SillyTavern 1.19.0 release）

| 阶段 / 组成 | 占用 | 占 1GB |
|---|---|---|
| `git clone --depth 1` 后（含 `.git` 37M） | 98M | 10% |
| 装完依赖 `node_modules` | 334M | 33% |
| `npm install` 产生的缓存 | 86M | 8% |
| **安装瞬间峰值**（源码+`.git`+依赖+缓存） | **518M** | **51%** |
| webpack 编译产物 `dist/_webpack` | 14M | 1.4% |
| komari-agent 二进制 | 12M | 1.2% |
| **清理缓存后的稳态** | **≈ 396M** | **≈ 40%** |

> **你看到的「40% 多」是正常的稳态，不是磁盘满了。** 稳态里 `node_modules` 一项就占 334M（`onnxruntime-web` 66M + `sillytavern-transformers` 53M + `tiktoken` 23M 等），这是刚性依赖，删了启动直接报错，别动。

**真正把 1GB 撑满的是 npm 缓存累积**：`npm install` 的下载缓存默认落在 `$HOME/.npm`，多次重装只增不减（实测沙箱累积到 1.3GB），远超单次那 86M。`start.sh` 现在每次启动都会清 `$HOME/.npm/_cacache`、`_logs`、`/tmp/npm-*`，并把首次安装的缓存指定到独立目录、装完即删。

另外两处别删：
- **`.git`（37M）**：webpack 缓存目录名由 `[pkgVersion, gitRevision, webpack.version]` 哈希而来，`gitRevision` 来自 `git.revparse`。删了 `.git` 会让它变 `null`、缓存 key 改变，下次启动**重新全量编译**。
- **`SillyTavern/dist/_webpack`（14M）**：前端编译缓存，删了每次重启都要重编译。

### 内存真相（512MB 是最大风险，不是磁盘）

| 场景 | 峰值 VmRSS | 结果 |
|---|---|---|
| 内存放宽 3G + 首次编译 | **966 MiB** | 编译成功，产物 14M |
| **512MB 硬限 + 首次编译（不限堆）** | 524 MiB | **6 秒 OOM 被杀** |
| 512MB 硬限 + 首次编译 + `--max-old-space-size=320` | 542 MiB | **5 秒 OOM 被杀（限堆无效）** |
| **512MB 硬限 + 已有 webpack 缓存、重启** | **300 MiB** | **2 秒启动，稳过** |

`Compiling frontend libraries...` 那一步 webpack 峰值接近 1GB，且主要来自 Buffer/原生内存，`--max-old-space-size` 压不住。**你日志里能 `compiled successfully in 205561 ms` 并 listening，说明 Wispbyte 实际给的内存超过标称 512MB（或有 swap/未硬限），不是真卡死。**

由此得出最关键一条：**编译一次成功后，务必让 `dist/_webpack` 缓存留在盘上**。之后重启是 2 秒 / 300MB，安全；若缓存丢失被迫重编译，在真 512MB 下就会 OOM。所以别删 `dist/`、别删 `.git`、别手动清空源码目录。

> 补充纠正：日志末尾的 `Server marked as offline` **不是崩溃、也不是 OOM**，而是平台因「平均 CPU 使用率过高」主动停服（见下一节）。内存和 CPU 是两个独立的坑。

---

## 三·六、CPU 限额：为什么会被平台停服，以及怎么防（重要）

### 症状与真实原因

站内通知原文：

> 由于 CPU 使用率过高，服务器已停止，平均 cpu 比例 37.03%

**我上一轮把日志末尾的 `Server marked as offline` 判断成「停止动作、不是崩溃」，这是错的**——那是平台按公平使用策略主动停服，不是你手动停、也不是 OOM。

Wispbyte 免费档的规则（官网 + KB）：免费服务器**前 ~90 秒给满核**专门让 `npm install` 别太慢，之后限速；Fair Use Policy 要求 CPU 保持在限额内，判据是**一段时间的平均 CPU 比例**，实测平均 **37.03%** 即触发停服。

根因在 SillyTavern 源码：`src/server-main.js` 里的
`await webpackMiddleware.runWebpackCompiler({ pruneCache: true })` 是**无条件调用**，没有任何跳过开关，每次启动都现场编译前端。在 1 核免费容器上这一步实测 **205561 ms（约 3.4 分钟）满核**，日志顺序正好是 `compiled successfully` → `listening` → `stopping` → `offline`。这段持续满核把平均 CPU 拉过阈值，于是编译刚完就被停。

### 两层防护

| 层 | 做法 | 效果 |
|---|---|---|
| **① 从根上不编译** | 随包带 `prebuilt-lib.js`（1.9 MB 已编译前端产物）。`start.sh` 用 `prebuilt-lib.js.sha` 校验当前 `public/lib.js` 哈希，匹配则由 `prebuilt-patch.js` 给源码打一个最小补丁，运行时把产物放进 webpack 的 output 目录并**跳过编译** | 首次启动从 **205 秒 → 6 秒**，满核尖峰直接消失 |
| **② CPU 硬上限兜底** | `cpu-limit.sh` 用 `SIGSTOP/SIGCONT` 占空比把酒馆主进程（独立进程组）压在 `CPU_LIMIT%` 内，纯 shell，无需 `cpulimit` 或 cgroup 权限 | 即使源码版本变了、补丁没匹配上必须现场编译，或运行时突发峰值，平均 CPU 也**不会再超阈值** |

两层是「或」的关系：**版本匹配走 ①（最省事），不匹配自动回退到现场编译但仍有 ② 兜底**，不会挂。补丁只改 `src/middleware/webpack-serve.js` 一处、幂等，产物路径由 `getPublicLibConfig()` 在运行时算出，不写死 hash 目录名，换 gitRevision / 换 dataRoot 都不会放错位置。

### 实测数据（本机 1GB tmpfs 硬约束 + 全新无缓存源码）

| 场景 | 结果 |
|---|---|
| 原版首次启动 | 编译约 205 秒（1 核满跑）→ 平均 CPU 37.03% → **停服** |
| 改版首次启动 | **6 秒 listening**，`[prebuilt] webpack compile skipped`，无 `Compiling` 行 |
| `GET /` / `GET /lib.js` | 200 / 200（734 KB / 1.9 MB），前端完全正常 |
| 节流器精度 | 设 25% → 实测 **25.2%**；设 40% → 40.2%；不节流 100% |
| 磁盘 | 427 MB / 1.0 GB，无异常 |
| 探针 | basicInfo 8192 MiB / 4 核 / docker（仍是容器值，未被节流误伤） |

节流器只作用于 `setsid` 拉起的**酒馆主进程组**；`proc-shim.sh`、`komari-agent` 在别的进程组，不受影响。

### 配置与代价

`komari.conf` 里 `CPU_LIMIT=25`（也可用平台环境变量 `CPU_LIMIT` 覆盖，优先级更高）：

- `25`（默认）：低于触发值 37.03%，留足余量。
- `0`：完全不节流，响应最跟手，但**有再次被停服的风险**。
- `1`~`99`：按百分比，**别设到 37 以上**。
- 代价：200 ms 周期里最多暂停 150 ms，聊天/导卡几乎无感；只在真有 CPU 负载时才表现为「慢一点」。

### 你现在最省事的动作

**重启一次服务器就行**：你日志里 `compiled successfully` 已经成功，`dist/_webpack` 缓存已落在盘上（Wispbyte 磁盘持久化），重启会命中缓存、2 秒起来，不会再有那 205 秒满核。

但要让防护长期生效，仍建议**重新拉一次这个仓库**（或至少覆盖 `start.sh`、`cpu-limit.sh`、`prebuilt-lib.js`、`prebuilt-lib.js.sha`、`prebuilt-patch.js`），这样以后重装、缓存丢失或平台重建容器也不会再被停。

---

## 四、为什么不会探到宿主机（原理）

Komari 官方 agent **不感知 cgroup**：`Ram()` 直接读 `/proc/meminfo`，`Cpu()` 用 `cpu.Counts()`，
`Load()` 读 `/proc/loadavg`——在容器里这些全是宿主机值。实测本机容器限额 8 GB / 4 核，
裸跑探针却上报 **123 GB / 32 核**，正是你担心的那个问题。

本套方案用三层把它纠正：

| 层 | 做法 |
|---|---|
| **影子 /proc** | `proc-shim.sh` 从 `memory.max`/`memory.current`、`cpu.max`/`cpu.stat` 读容器真值，生成 `meminfo`、`stat`、`cpuinfo`、`loadavg`、`net/dev`，由后台循环持续刷新 |
| **HOST_PROC 重定向** | gopsutil（agent 的采集库）支持标准环境变量 `HOST_PROC`，把它读 `/proc` 的根指到影子目录。内存、CPU 使用率、核数、负载、网络于是全部来自容器 |
| **JSON 覆盖 host_proc** | Komari 自己的 `HostProc` 字段环境变量**同名**。config.json 里把 `host_proc` 设为空串（JSON 优先级最高），覆盖 `loadFromEnv` 的值 → 进程数、TCP/UDP 连接数走**真实 `/proc`**，而容器 pidns/netns 天然隔离，读到的正是容器自己的进程与连接 |

配套开关：
- `memory_include_cache: true` —— 强制 `Ram()` 走 gopsutil 的 `VirtualMemory()`（读影子 meminfo），绕开 `ReadProcMeminfo()` 里**硬编码** `/proc/meminfo` 的 htopLike 分支
- `include_mountpoints` —— 只统计容器数据目录，绕开宿主机分区枚举
- `exclude_nics` —— 排除 lo / veth / docker 等虚拟网卡
- `disable_auto_update: true` —— 锁死 1.5.11，避免容器里自更新把二进制换掉
- `max_retries: 2` / `reconnect_interval: 2` —— WebSocket 连不上时约 6 秒切到 v2 POST fallback（默认 3 次 × 5 秒，要 ~20 秒才上线）

### 已知边界（如实说明）
| 指标 | 状态 |
|---|---|
| 内存 total/used、CPU 使用率、CPU 核数、网络收发、TCP/UDP 连接数、进程数、系统信息、Ping 任务、流量统计、磁盘**已用/使用率** | ✅ 容器值 |
| **磁盘总容量 `disk_total`** | ⚠️ `disk.Usage()` 走 `statfs()` 系统调用，`HOST_PROC` 管不到；若平台用共享文件系统，可能显示底层/宿主机总容量（本地实测沙箱显示 256 GiB）。`include_mountpoints` 只能限制统计哪些挂载点，改不了总容量；磁盘**已用/使用率**仍是容器可写层真实值 |
| **uptime** | ⚠️ gopsutil 用 `sysinfo()` 系统调用读内核启动时间，纯用户态无法重定向，会显示宿主机 uptime。面板一般只用于"已运行多久"，影响很小 |
| **swap** | ⚠️ Komari 的 `Swap()` 硬编码 `/proc/meminfo`，读到宿主机 swap；容器通常禁用 swap，多数场景显示为 0 |
| **load1/5/15** | ⚠️ 容器没有独立的 load average（`/proc/loadavg` 是宿主机全局），这里降级为 0，避免误报宿主机负载 |
| GPU / 温度 | 容器默认无 GPU，`gpu` 未开启（免费套餐也用不上） |
| WebSSH / 远程执行 | 默认关闭（`disable_web_ssh: true`），安全起见；要开可在 `.komari-runtime.json` 改 |

这些是 Komari 官方 agent 在容器里的固有限制，靠纯用户态脚本能修的都修了，剩下三项是内核/硬编码路径，不是配置问题。

---

## 五、版本说明

- 你给的 **面板 1.5.1 (f0cc0fb)**：`f0cc0fb` 已核对，正是 `komari-monitor/komari` 的 `1.5.1` tag commit（`fix: pin 1.5.1 frontend release source`，2026-09-24）。
- **agent 独立发版**，与面板版本号不同。这里锁定 `1.5.11`（2026-09-17，1.5.1 面板同期稳定版），走 **v2 协议**，与 1.5.1 面板兼容。
- 若面板提示协议不兼容，把 `start.sh` 里 `AGENT_URLS` 的 `1.5.11` 换成 `1.5.10` 或 `1.5.0` 重试。

---

## 六、排错

| 现象 | 原因 / 处理 |
|---|---|
| **`SyntaxError: Invalid or unexpected token`，指向 `start.sh:2`** | 主文件 / `JS_FILE` 被设成了 `start.sh`，平台用 `node` 把它当 JS 跑。见「二、2」：Startup 点 Edit 整条改成 `sh /home/container/start.sh`，或把主文件改为 `index.js` |
| `EBADENGINE` / `npm WARN EBADENGINE`、Node 是 v19.x | SillyTavern 要求 `node >= 20`。Startup → Docker image 选 `nodejs_22` → **Use this image** → 重启 |
| 面板不显示节点 | 先看 `komari-agent.log`；多半是 token 没填、面板地址没带 `https://`、或容器出站连不上面板域名 |
| 日志刷 `Failed to connect to WebSocket: 404` | 面板反代没放开 WebSocket，属正常；已设 `max_retries: 2` / `reconnect_interval: 2`，约 6 秒自动切 v2 POST fallback，确认日志出现 `Entering v2 POST fallback mode` 后数据照常上报 |
| 自签证书报错 | `komari.conf` 里 `IGNORE_CERT=1` |
| 内存仍显示几十 GB | 说明 `HOST_PROC` 没生效：确认 Startup Command 是 `sh start.sh`（不是 `node server.js`），日志有没有 `[proc-shim]` 行 |
| CPU 使用率恒为 0 / 0.001% | shim 没在刷新：日志里 `[proc-shim]` 行应每秒持续出现；确认 `REPORT_INTERVAL` > 1；删掉 `.proc-shim/` 重启以重建 CPU 基准 |
| 酒馆打不开 / Forbidden | 确认 `config.yaml` 里 `whitelistMode: false`；端口是否等于面板分配端口 |
| 磁盘占用 40% 多 / 接近满 | **40% 是正常稳态**（`node_modules` 334M 是刚性依赖，别删）。真凶是 npm 缓存累积：`$HOME/.npm/_cacache` 只增不减。`start.sh` 已每次自动清；也可在 Console 手动跑 `du -sh ~/.npm 2>/dev/null; rm -rf ~/.npm/_cacache ~/.npm/_logs /tmp/npm-*` 立即释放。别导大世界书/图片包 |
| 站内通知「**由于 CPU 使用率过高，服务器已停止，平均 cpu 比例 37.03%**」 | 平台按平均 CPU 停服，根因是首次 webpack 编译满核 205 秒。见「三·六」：拉新版包（带 `prebuilt-lib.js` + `cpu-limit.sh`），或至少**重启一次**让已生成的编译缓存命中。别把 `CPU_LIMIT` 设到 37 以上 |
| `Compiling frontend libraries...` 卡很久 / 面板判离线 | 说明预置产物没生效（版本不匹配或补丁失败），回退到现场编译了。1 核约 205 秒属正常；此时 CPU 节流器仍在工作，不会被停服但会慢。检查 Console 有没有 `源码与预编译产物匹配` 和 `prebuilt-lib.js` 是否在根目录。**别删 `dist/_webpack` 和 `.git`** |
| `Server marked as offline` 且日志无报错 | 多半就是平台因平均 CPU 过高**主动停服**（见「三·六」），不是崩溃也不是 OOM。确认上一行有 `listening` 就说明酒馆其实起来了；重开后若 2 秒内再次 `listening` 即缓存命中。拉新版包后不再出现 |
| 页面偶尔顿一下 / 首次启动变慢 | `cpu-limit.sh` 在削 CPU 峰值，200ms 周期最多暂停 150ms，聊天无感。想最快响应可在 `komari.conf` 设 `CPU_LIMIT=0`，但会失去停服保护 |
| `prebuilt-lib.js` 版本不匹配、日志提示「回退现场编译」 | SillyTavern 升级改了 `public/lib.js`。不影响使用（有节流器兜底），或重新拉一次本仓库拿匹配的新产物 |
| GitHub clone 失败 | 改用 Wispbyte 网页文件管理器上传 SillyTavern 源码包到 `SillyTavern/` |

## 七、安全

- `komari.conf` 含 token，**不要提交到公开仓库**（`.gitignore` 已排除）。
- 酒馆 BasicAuth 密码别用常用密码；临时玩别填常用付费 API Key。
- Wispbyte 免费档需 **每 14 天登录一次**保活，30 天不登录会归档（可恢复）。
