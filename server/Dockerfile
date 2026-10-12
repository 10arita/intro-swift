FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY index.mjs external.mjs chorus-reports.mjs manual-chorus.mjs manual-chorus.json sqlite-chorus.mjs catalog.json ./
COPY corpus ./corpus
COPY public ./public
RUN mkdir -p /app/data && chown -R node:node /app/data
ENV NODE_ENV=production PORT=3000 DATA_DIR=/app/data
EXPOSE 3000
USER node
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD node -e "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "index.mjs"]
