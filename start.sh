#!/bin/sh
set -eu

# 平台会注入 PORT；没注入时退回 SillyTavern 官方默认端口
export SILLYTAVERN_PORT="${PORT:-8000}"

# 公网部署必须用 BasicAuth。缺用户名/密码时直接退出，
# 避免用官方默认的 user / password 裸奔在公网上
if [ -z "${SILLYTAVERN_BASICAUTHUSER_USERNAME:-}" ] || [ -z "${SILLYTAVERN_BASICAUTHUSER_PASSWORD:-}" ]; then
    echo "ERROR: 请在平台的环境变量里设置 SILLYTAVERN_BASICAUTHUSER_USERNAME 和 SILLYTAVERN_BASICAUTHUSER_PASSWORD，否则拒绝启动。" >&2
    exit 1
fi

echo "SillyTavern starting on port ${SILLYTAVERN_PORT} ..."
exec /home/node/app/docker-entrypoint.sh
