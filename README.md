# SillyTavern 最小部署仓库（给 Infrlo 这类 PaaS 用）

只要把**公开仓库的链接**贴给平台就能拉起来。仓库里故意只有两个必要文件，避免在 512 MB 免费实例上跑 `npm install` 触发 OOM。

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 基于官方预构建镜像 `ghcr.io/sillytavern/sillytavern:latest`，写死非敏感配置 |
| `start.sh` | 把平台注入的 `PORT` 同步给酒馆；检查 BasicAuth 是否配置；调官方 entrypoint |
| `.env.example` | 环境变量模板，复制到平台控制台用，不要提交真实密码 |

## 三步部署

1. GitHub 新建一个 **Public** 仓库（名字随意，如 `st-temp`），把本目录的 `Dockerfile`、`start.sh` 上传上去（网页上 Add file → Create new file 即可，不用装 git）。
2. 复制仓库的 HTTPS 链接（如 `https://github.com/你的用户名/st-temp`），粘贴到 Infrlo 控制台，分支填 `main`/`master`。如果控制台有 Build/Run Command 输入框：留空或选 Dockerfile 模式；不要再填 `npm install`。
3. 在控制台 Environment Variables 里按 `.env.example` 填上 **用户名和密码**，部署。

> 平台只需要能读到这个**公开仓库**，通常不需要把 GitHub 账号 OAuth 授权给它。若控制台弹出 GitHub 授权，只给「只读单个仓库」的最小权限，不要给全部 repo 权限。

## 必须配的环境变量

| 变量 | 值 | 不配会怎样 |
|---|---|---|
| `SILLYTAVERN_BASICAUTHUSER_USERNAME` | 自定 | `start.sh` 会拒绝启动（防止用默认 `user/password` 裸奔） |
| `SILLYTAVERN_BASICAUTHUSER_PASSWORD` | 强密码 | 同上 |
| `NODE_ENV` | `production` | 无害但建议 |
| `SILLYTAVERN_PERFORMANCE_MEMORYCACHECAPACITY` | `32mb`（可选） | 省内存，默认 100mb |
| `SILLYTAVERN_PORT` | 一般不用填 | `start.sh` 已自动取平台的 `PORT`；端口对不上才手动指定 |

`SILLYTAVERN_WHITELISTMODE=false` 和 `SILLYTAVERN_BASICAUTHMODE=true` 已写进 Dockerfile：前者不关会一直 `Blocked connection`/403（默认白名单只放行 127.0.0.1），后者不设时 SillyTavern 的安全检查会拒绝在 `listen:true` 下启动。

## 验收（5 分钟）

1. 打开平台分配的域名 → 应弹出 BasicAuth 输入框，用刚设的账号进去。
2. 导入一张角色卡，发一句话，看回复是否完整（不半截断开）。
3. 手动重启一次 App，看卡还在不在。**丢了属正常**（免费层不保证持久卷），临时玩重新导入即可。
4. 多导几张卡 / 装扩展，若开始 502 或反复重启，就是 512 MB 到顶了，别死磕。

## 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| 日志报 `ERROR: 请设置 ... USERNAME/PASSWORD` | 没在控制台配环境变量 | 按 `.env.example` 补上 |
| 502 / 一直连不上 | 端口没对上 | 看日志里 `starting on port X`，把 `SILLYTAVERN_PORT` 手动设成平台注入的 `PORT` 值 |
| 页面 `Blocked connection` / 403 | 白名单没关 | 确认 Dockerfile 里 `SILLYTAVERN_WHITELISTMODE=false` 生效 |
| 构建阶段被杀 / OOM | 平台在跑 `npm install` | 确认走的是 Dockerfile 模式，Build Command 留空 |
| AI 回复说一半断了 / 空回复 | 边缘代理掐长连接 | 平台侧无法调超时，只能换平台 |
| 容器起不来，提示安全检查 | `listen:true` 但没开认证 | 确认 `SILLYTAVERN_BASICAUTHMODE=true` |

## Plan B：平台不认 Dockerfile

如果它只提供 Build Command / Run Command（buildpack 模式）：fork SillyTavern 官方仓库的 `release` 分支，Build 填 `npm install --omit=dev`，Run 填 `node server.js --listen --port $PORT`，环境变量照上表配。构建阶段在 512 MB 下比 Dockerfile 路线更容易 OOM，跑不通就换平台，别耗。

## 临时玩的安全底线

- 只填**小额 / 免费额度**的 API Key（AI Horde、小额中转），别用常用付费 Key；BasicAuth 密码别复用常用密码。
- 角色卡、预设、世界书在本地留一份副本，平台随时可能清数据或停用。
- 不要把 GitHub 账号密码、TOTP 密钥、PAT 写进仓库或发给平台；部署只需要一个公开仓库链接。
