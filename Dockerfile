# 给 Infrlo 这类「贴 GitHub 仓库链接就部署」的 PaaS 用的最小 SillyTavern 镜像
# 关键：直接用官方预构建镜像，不在 512MB 免费实例上跑 npm install（必 OOM）
FROM ghcr.io/sillytavern/sillytavern:latest

# 非敏感的固定配置写这里；账号密码走平台的环境变量，绝不写进公开仓库
ENV NODE_ENV=production \
    SILLYTAVERN_LISTEN=true \
    SILLYTAVERN_WHITELISTMODE=false \
    SILLYTAVERN_BASICAUTHMODE=true

COPY start.sh /start.sh
RUN chmod +x /start.sh

# 官方镜像自带 tini，保留它做 PID 1，正确转发信号
EXPOSE 8000
ENTRYPOINT ["tini", "--", "/start.sh"]
