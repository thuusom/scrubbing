# generator/Dockerfile
FROM alpine:3.20
RUN apk add --no-cache ffmpeg inotify-tools bash coreutils jq dos2unix imagemagick
WORKDIR /app
COPY run.sh /app/run.sh
RUN dos2unix /app/run.sh && chmod +x /app/run.sh
VOLUME ["/input", "/output"]
ENTRYPOINT ["/app/run.sh"]