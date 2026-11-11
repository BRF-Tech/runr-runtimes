ARG VERSION=25.0

# Apache Maven, for the dependencies of a function's pom.xml (runr-deps): from Maven Central,
# checked against its SHA-512 (the JDK image has no curl)
FROM ghcr.io/brf-tech/runr/reqs/curl:latest AS maven
ARG MAVEN_VERSION=3.10.0
ARG MAVEN_SHA512=908b1501bfb420bf7c8affb855534a9c407fd6099367bfb9f2f2dcb8e9799102bffb84518cde74c679bd76870247c6528683abdd620581bffa90f95d92d175aa
RUN curl -fsSL --retry 5 --retry-all-errors --retry-delay 10 --connect-timeout 30 -o /tmp/maven.tar.gz \
      "https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/${MAVEN_VERSION}/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
    && echo "${MAVEN_SHA512}  /tmp/maven.tar.gz" | sha512sum -c - \
    && mkdir -p /tmp/maven \
    && tar -xzf /tmp/maven.tar.gz -C /tmp/maven --strip-components=1 \
    && rm /tmp/maven.tar.gz

# The version is the JDK's major line (exec-java:21.0 is Temurin 21): the JDK compiles the function
# (javac) and runs it, so a function's image is this one plus its classes
FROM ghcr.io/brf-tech/runr/reqs/eclipse-temurin:${VERSION}-jdk

ARG MAVEN_DEPENDENCY_PLUGIN=3.11.0
ENV MAVEN_HOME=/opt/maven \
    PATH=/opt/runr/bin:/opt/maven/bin:${PATH} \
    RUNR_MAVEN_DEPENDENCY_PLUGIN=${MAVEN_DEPENDENCY_PLUGIN} \
    HOME=/home/runr
COPY --from=maven /tmp/maven /opt/maven

# The handler server, compiled once
COPY runr/ /tmp/runr-src/
RUN javac -encoding UTF-8 -d /opt/runr/classes $(find /tmp/runr-src -name '*.java' | sort) \
    && rm -rf /tmp/runr-src
COPY --chmod=0755 runr-build runr-deps runr-start /opt/runr/bin/

# Functions run (and build) as runr (10001), not root. The user is written into /etc/passwd and
# /etc/group directly: useradd would also date its /etc/shadow entry, and the build is
# reproducible (the same sources and base give the same image: lib/patch.sh). /build is the
# function build's working directory (RunR copies the code to /build/code, the output goes to
# /build/out), owned by runr so the build may write there.
RUN echo 'runr:x:10001:' >> /etc/group \
    && echo 'runr:x:10001:10001:RunR function:/home/runr:/usr/sbin/nologin' >> /etc/passwd \
    && mkdir -p /home/runr /build/code /build/out /app/code \
    && chown -R 10001:10001 /home/runr /build
USER 10001:10001

# Maven's dependency plugin in the local repository: a build resolves the function's dependencies
# without fetching Maven's own. The files that record when and from where Maven fetched something
# are removed (they differ in every build); Maven uses the artifacts without them.
RUN mkdir -p /tmp/warm \
    && printf '%s\n' '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>' \
        '<groupId>sh.runr</groupId><artifactId>warm</artifactId><version>1</version></project>' > /tmp/warm/pom.xml \
    && runr-deps /tmp/warm/pom.xml /tmp/warm \
    && rm -rf /tmp/warm \
    && find /home/runr/.m2 \( -name '_remote.repositories' -o -name '*.lastUpdated' -o -name 'resolver-status.properties' \) -delete

WORKDIR /app

ENV RUNR_MODE=http
ENV RUNR_HANDLER=handler
ENV RUNR_FILENAME=Main.java

EXPOSE 8080

ENTRYPOINT ["/opt/runr/bin/runr-start"]
