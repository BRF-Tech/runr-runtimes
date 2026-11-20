ARG VERSION=8.4
FROM ghcr.io/brf-tech/runr/reqs/php:${VERSION}-cli-alpine

# The oldest release of each PHP branch the image may carry: the releases of 2026-11-19 that fix
# CVE-2026-129289, CVE-2026-115560, CVE-2026-126714 and CVE-2026-129496 among others
# (https://www.php.net/ChangeLog-8.php), after the ones of 2026-10-21 that fixed CVE-2026-109618
# and CVE-2026-109619. The build fails on an older release of its branch, and on a branch older
# than every entry; a branch newer than every entry came out after the fix.
ARG PHP_FIXED_RELEASES="8.2.36 8.3.37 8.4.28 8.5.13"
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
