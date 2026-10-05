FROM oven/bun:1.3-debian

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg ca-certificates curl python3 \
  && rm -rf /var/lib/apt/lists/* \
  && curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
       -o /usr/local/bin/yt-dlp \
  && chmod a+rx /usr/local/bin/yt-dlp

WORKDIR /app
COPY package.json tsconfig.json ./
COPY src ./src

ENV PORT=8080 \
    CACHE_DIR=/tmp/cc-music-cache \
    CACHE_TTL_MS=3600000 \
    AUDIO_FORMAT=mp3 \
    REQUIRE_CC_UA=true \
    YTDLP_PATH=/usr/local/bin/yt-dlp \
    FFMPEG_PATH=/usr/bin/ffmpeg \
    YTDLP_JS_RUNTIME=bun

RUN mkdir -p /tmp/cc-music-cache
EXPOSE 8080
CMD ["bun", "run", "src/server.ts"]
