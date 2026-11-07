ARG VERSION=1.4
FROM ghcr.io/brf-tech/runr/reqs/bun:${VERSION}-slim

ENV HOME=/home/runr \
    PATH=/opt/runr/bin:${PATH} \
    BUN_RUNTIME_TRANSPILER_CACHE_PATH=0 \
    DO_NOT_TRACK=1

COPY server.ts /opt/runr/server.ts
COPY --chmod=0755 runr-install /opt/runr/bin/

# Functions run (and install their packages) as runr (10001), not root. The user is written into
# /etc/passwd and /etc/group directly: useradd would also date its /etc/shadow entry, and the build
# is reproducible (the same sources and base give the same image: lib/patch.sh). /build is the
# dependency build's working directory (RunR copies the code to /build/code, runr-install installs
# into /build/deps), owned by runr so the build may write there.
RUN echo 'runr:x:10001:' >> /etc/group \
    && echo 'runr:x:10001:10001:RunR function:/home/runr:/usr/sbin/nologin' >> /etc/passwd \
    && mkdir -p /home/runr /build/code /build/deps /app/code \
    && chown -R 10001:10001 /home/runr /build
USER 10001:10001

WORKDIR /app

ENV RUNR_MODE=http
ENV RUNR_HANDLER=handler
ENV RUNR_FILENAME=main.ts

EXPOSE 8080

ENTRYPOINT ["bun", "/opt/runr/server.ts"]
