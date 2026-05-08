# syntax=docker/dockerfile:1.7
FROM node:20-slim

WORKDIR /app

# Install dependencies first for layer caching. Copy only the manifest so
# source changes don't bust the deps layer.
COPY package.json package-lock.json* ./
RUN npm install --omit=dev

# Copy the application source.
COPY . .

# Run as a non-root user (matches node:20-slim's built-in 'node' user).
USER node

# The Python backend reaches us on this port via ``RING_SIP_BRIDGE_URL``.
EXPOSE 3000

ENV NODE_ENV=production
ENV PORT=3000
ENV MEDIAMTX_RTSP_URL=rtsp://mediamtx:8554/ring

CMD ["node", "index.js"]
