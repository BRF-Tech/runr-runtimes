ARG VERSION=10.0
# The .NET SDK of the version: it builds every function (runr-build) into a self-contained
# application that runs on ghcr.io/brf-tech/runr/reqs/dotnet-runtime-deps:<version>-chiseled-extra
# (build.runImage of runtime.yaml), so the SDK never runs a function in RunR
FROM ghcr.io/brf-tech/runr/reqs/dotnet-sdk:${VERSION}
ARG VERSION

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_GENERATE_ASPNET_CERTIFICATE=false \
    DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1 \
    MSBUILDDISABLENODEREUSE=1 \
    NUGET_XMLDOC_MODE=skip \
    RUNR_DOTNET_VERSION=${VERSION} \
    PATH=/opt/runr/bin:${PATH} \
    HOME=/home/app

COPY host/ /opt/runr/dotnet/
COPY --chmod=0755 runr-build runr-start /opt/runr/bin/

# Functions build (and run, on the chiseled runtime-deps image) as app (1654), the non-root user
# of Microsoft's .NET images. /build is the function build's working directory (RunR copies the
# code to /build/code, the output goes to /build/out), owned by app so the build may write there.
RUN mkdir -p /build/code /build/out /app/code \
    && chown -R 1654:1654 /build
USER 1654:1654

# A function without code published once: the NuGet cache (~/.nuget/packages) then holds the
# runtime packs of this SDK's .NET runtime for this architecture, so a function build fetches
# only the function's own packages. What records when NuGet and MSBuild ran is removed (it
# differs in every build; the build is reproducible: lib/patch.sh).
RUN mkdir -p /tmp/warm \
    && RUNR_BUILD_DIR=/tmp/warm-src runr-build publish /tmp/warm /tmp/warm-out \
    && find /tmp -mindepth 1 -maxdepth 1 -user 1654 -exec rm -rf {} + \
    && rm -rf /home/app/.local/share/NuGet /home/app/.dotnet/TelemetryStorageService /home/app/.nuget/NuGet

WORKDIR /app

ENV RUNR_MODE=http
ENV RUNR_HANDLER=Handler
ENV RUNR_FILENAME=Function.cs

EXPOSE 8080

ENTRYPOINT ["/opt/runr/bin/runr-start"]
