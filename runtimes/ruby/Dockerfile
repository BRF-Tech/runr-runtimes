ARG VERSION=3.4
FROM ghcr.io/brf-tech/runr/reqs/ruby:${VERSION}-slim

ENV HOME=/home/runr \
    PATH=/opt/runr/bin:${PATH}

COPY server.rb /opt/runr/server.rb
COPY --chmod=0755 runr-bundle /opt/runr/bin/

# Functions run (and install their gems) as runr (10001), not root. The user is written into
# /etc/passwd and /etc/group directly: useradd would also date its /etc/shadow entry, and the build
# is reproducible (the same sources and base give the same image: lib/patch.sh). /build is the
# dependency build's working directory (RunR copies the code to /build/code, runr-bundle installs
# into /build/gems), owned by runr so the build may write there.
RUN echo 'runr:x:10001:' >> /etc/group \
    && echo 'runr:x:10001:10001:RunR function:/home/runr:/usr/sbin/nologin' >> /etc/passwd \
    && mkdir -p /home/runr /build/code /build/gems /app/code \
    && chown -R 10001:10001 /home/runr /build
USER 10001:10001

WORKDIR /app

ENV RUNR_MODE=http
ENV RUNR_HANDLER=handler
ENV RUNR_FILENAME=main.rb

EXPOSE 8080

ENTRYPOINT ["ruby", "/opt/runr/server.rb"]
