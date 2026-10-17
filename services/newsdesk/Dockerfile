# Node 24 ships SQLite built in (node:sqlite), so there are no native modules to compile.
FROM node:24-alpine

WORKDIR /app

COPY package*.json ./
RUN npm ci --omit=dev

COPY config.default.json ./
COPY src ./src
COPY public ./public

ENV PORT=3000
ENV DATA_DIR=/app/data
# node:sqlite still prints an "experimental" warning on startup; it's harmless.
ENV NODE_NO_WARNINGS=1

EXPOSE 3000

CMD ["node", "src/server.js"]
