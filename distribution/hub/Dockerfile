# UltraDic Hub – runs on the NAS behind `tailscale serve` (https PORT → 127.0.0.2:3013).
FROM node:24-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:24-alpine
WORKDIR /app
ARG GIT_SHA=unknown
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000 DATA_DIR=/app/data GIT_SHA=${GIT_SHA}
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
USER 1003:100
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:3000/api/health || exit 1
CMD ["node", "--max-old-space-size=64", "dist/index.js"]
