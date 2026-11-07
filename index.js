#!/usr/bin/env node
// =============================================================================
// index.js —— Wispbyte Node.js 镜像的兜底入口
//
// 这个镜像的启动命令固定是 `node <JS_FILE>`，不会把 .sh 当脚本执行。
// 若面板不允许把整条 Startup Command 改成 `sh /home/container/start.sh`，
// 就把「主文件 / JS_FILE / Startup file」指向本文件，由它转交 start.sh。
//
// 优先方案仍是直接改 Startup Command（少一个常驻 node 进程，512 MB 更省）：
//     sh /home/container/start.sh
// =============================================================================
'use strict';
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const dir = __dirname;
const script = path.join(dir, 'start.sh');

if (!fs.existsSync(script)) {
  console.error('[boot] 找不到 start.sh，请确认部署文件都在容器根目录');
  process.exit(1);
}

console.log('[boot] 转交 start.sh，工作目录=' + dir + '，node=' + process.version);

// 用 sh 显式解释执行，绕开上传后常见的 644 无执行权限问题
const child = spawn('sh', [script], {
  cwd: dir,
  stdio: 'inherit',
  env: process.env,
});

child.on('error', (err) => {
  console.error('[boot] 启动 start.sh 失败:', err);
  process.exit(1);
});
child.on('exit', (code, signal) => {
  console.log('[boot] start.sh 已退出 code=' + code + ' signal=' + signal);
  process.exit(typeof code === 'number' ? code : 1);
});

// 转发信号，保证面板 Stop / Restart 能正确结束子进程
['SIGTERM', 'SIGINT', 'SIGHUP'].forEach((sig) => {
  process.on(sig, () => {
    try { child.kill(sig); } catch (_) { /* ignore */ }
  });
});
