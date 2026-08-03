# XUI-VPS — multi-arch Docker image (linux/amd64 + linux/arm64)
# Uses Node 24 built-in node:sqlite — zero native deps, runs on any arch.
# Build:  docker build -t xui-vps .
# Run:    docker run -d -p 8787:8787 -v xui-data:/data xui-vps
FROM node:24-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY . .

ENV NODE_ENV=production \
    PORT=8787 \
    HOST=0.0.0.0 \
    DATABASE_PATH=/data/xui.db

EXPOSE 8787
VOLUME ["/data"]

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8787/health || exit 1

CMD ["node", "server.js"]
