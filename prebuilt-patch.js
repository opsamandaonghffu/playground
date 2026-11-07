#!/usr/bin/env node
// =============================================================================
// prebuilt-patch.js <SillyTavern 目录>
//
// 给 SillyTavern 源码打一个最小补丁：当 start.sh 判定「随包分发的编译产物与
// 当前源码版本匹配」时，runWebpackCompiler() 直接把产物放到 webpack 的 output
// 目录并跳过编译，从根上消除首次启动那次 1 核满跑约 205 秒的前端编译。
//
// 幂等；路径由 getPublicLibConfig() 在运行时算出，不写死 hash 目录名，因此
// 换 gitRevision / 换 dataRoot 都不会放错位置。任何异常都会回落为正常编译。
// =============================================================================
'use strict';
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) {
    console.error('[prebuilt] usage: node prebuilt-patch.js <SillyTavern dir>');
    process.exit(1);
}

const file = path.join(root, 'src', 'middleware', 'webpack-serve.js');
let s;
try {
    s = fs.readFileSync(file, 'utf8');
} catch (e) {
    console.error('[prebuilt] 读不到 ' + file + ': ' + e.message);
    process.exit(1);
}

const MARK = '[prebuilt]';
if (s.includes(MARK)) {
    console.log('[prebuilt] already patched');
    process.exit(0);
}

// 1) 补一个 fs import（webpack-serve.js 原本只 import 了 path / webpack / config）
if (!s.includes("import fsSync from 'node:fs';")) {
    const a = "import path from 'node:path';";
    if (!s.includes(a)) { console.error('[prebuilt] import anchor 未找到'); process.exit(1); }
    s = s.replace(a, a + "\nimport fsSync from 'node:fs';");
}

// 2) 在 runWebpackCompiler 开头插入跳过分支
const anchor = 'devMiddleware.runWebpackCompiler = ({ forceDist = false, pruneCache = false } = {}) => {';
if (!s.includes(anchor)) { console.error('[prebuilt] runWebpackCompiler anchor 未找到，源码可能已改版'); process.exit(1); }

const inject = `
    // [prebuilt] 直接用随包分发的编译产物，跳过 CPU 密集的 webpack 编译
    if (process.env.SKIP_WEBPACK && process.env.PREBUILT_LIB) {
        try {
            const cfg = getPublicLibConfig({ forceDist, pruneCache });
            const dst = path.join(cfg.output.path, cfg.output.filename);
            if (!fsSync.existsSync(dst)) {
                fsSync.mkdirSync(cfg.output.path, { recursive: true });
                fsSync.copyFileSync(process.env.PREBUILT_LIB, dst);
            }
            console.log('[prebuilt] webpack compile skipped -> ' + dst);
            return Promise.resolve();
        } catch (e) {
            console.log('[prebuilt] inject failed, fallback to compile: ' + e.message);
        }
    }
`;
s = s.replace(anchor, anchor + inject);
fs.writeFileSync(file, s);
console.log('[prebuilt] patched OK');
