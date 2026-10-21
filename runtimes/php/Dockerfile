ARG VERSION=8.4
FROM ghcr.io/brf-tech/runr/reqs/php:${VERSION}-cli-alpine

# The oldest release of each PHP branch the image may carry: the releases that fix CVE-2026-109618
# and CVE-2026-109619 (https://www.php.net/archive/2026.php#2026-10-21-5). The build fails on an
# older release of its branch, and on a branch older than every entry; a branch newer than every
# entry came out after the fix.
ARG PHP_FIXED_RELEASES="8.2.35 8.3.36 8.4.27 8.5.12"
RUN php -r '$branch = PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION; $newest = null; \
        foreach (array_filter(preg_split("/\s+/", trim($argv[1] ?? ""))) as $fixed) { \
            $of = implode(".", array_slice(explode(".", $fixed), 0, 2)); \
            if ($of === $branch) { exit(version_compare(PHP_VERSION, $fixed, ">=") ? 0 : 1); } \
            $newest = $newest === null || version_compare($of, $newest, ">") ? $of : $newest; \
        } \
        exit($newest !== null && version_compare($branch, $newest, ">") ? 0 : 1);' \
        "$PHP_FIXED_RELEASES" \
    || { echo "PHP $(php -r 'echo PHP_VERSION;') is older than the fixed release of its branch (PHP_FIXED_RELEASES=${PHP_FIXED_RELEASES})" >&2; exit 1; }

WORKDIR /app

COPY server.php runner.php entrypoint.sh ./
RUN chmod +x entrypoint.sh

RUN mkdir -p /app/code

ENV RUNR_MODE=http
ENV RUNR_HANDLER=handler
ENV RUNR_FILENAME=main.php

EXPOSE 8080

ENTRYPOINT ["./entrypoint.sh"]
