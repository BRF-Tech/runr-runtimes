# Smoke tests of the images, run on the local build of every image before it is pushed (ci.sh …
# --push) and after every local build unless --no-smoke. The ML runtimes have their own
# (ml_runtime_smoke in build-ml.sh): a tensor handler over http and schedule, on the GPU where
# the host gives Docker one.
#
#   runtime_smoke IMAGE RUNTIME VERSION   language runtimes (python, nodejs, go, php): a handler in
#                                         /app/code answers a request like a function (http trigger,
#                                         the image's own server; the request comes from a curl
#                                         container in the same network namespace, so no port is
#                                         published and the image needs no client), then runs once
#                                         with RUNR_MODE=schedule; the language version starts with
#                                         the tag's major.minor
#   wrapper_smoke IMAGE VERSION           `runr-wrapper version` prints the tag's version
#   wasm_smoke IMAGE LANG DIR             the build image runs and carries the Spin CLI its
#                                         Dockerfile pins (SPIN_VERSION); wasm-exec also
#                                         runr-image-upload and runr-wasm-exec
#   hf_serve_smoke IMAGE VERSION VARIANT  `version` prints the tag's version; the server's modules
#                                         import with torch and transformers (cuda: a CUDA build of
#                                         torch and diffusers; on the GPU where `docker run --gpus
#                                         all` gives one, ML_SMOKE_GPU as for the ML runtimes)

# The client of runtime_smoke: curl from the reqs mirror
SMOKE_CURL_IMAGE="${SMOKE_CURL_IMAGE:-ghcr.io/brf-tech/runr/reqs/curl:latest}"
# How long runtime_smoke waits for the server (the go image compiles the handler first)
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"

# smoke_handler RUNTIME DIR — writes the smoke handler of a language runtime into DIR and prints its
# file name: the sum of the request's a and b (40 and 2 when the event has none, as in a schedule
# run), the language version and the trigger, as JSON
smoke_handler() {
  local runtime="$1" dir="$2"
  case "$runtime" in
    python)
      cat > "${dir}/main.py" <<'PY'
import platform


def handler(event, context):
    a, b = event.get("a", 40), event.get("b", 2)
    return {"statusCode": 200, "headers": {"Content-Type": "application/json"}, "body": {
        "runtime": "python", "version": platform.python_version(), "sum": a + b,
        "trigger": event.get("trigger", "http"),
    }}
PY
      echo main.py ;;
    nodejs)
      cat > "${dir}/main.js" <<'JS'
exports.handler = async (event, context) => {
  const a = event.a ?? 40;
  const b = event.b ?? 2;
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: { runtime: 'nodejs', version: process.versions.node, sum: a + b, trigger: event.trigger || 'http' },
  };
};
JS
      echo main.js ;;
    php)
      cat > "${dir}/main.php" <<'PHP'
<?php

function handler($event, $context): array
{
    $a = $event['a'] ?? 40;
    $b = $event['b'] ?? 2;

    return ['statusCode' => 200, 'headers' => ['Content-Type' => 'application/json'], 'body' => [
        'runtime' => 'php', 'version' => PHP_VERSION, 'sum' => $a + $b, 'trigger' => $event['trigger'] ?? 'http',
    ]];
}
PHP
      echo main.php ;;
    go)
      cat > "${dir}/main.go" <<'GO'
package main

import (
	"runtime"
	"strings"
)

func Handler(event interface{}, context interface{}) (interface{}, error) {
	a, b, trigger := 40.0, 2.0, "http"
	if m, ok := event.(map[string]interface{}); ok {
		if v, ok := m["a"].(float64); ok {
			a = v
		}
		if v, ok := m["b"].(float64); ok {
			b = v
		}
		if v, ok := m["trigger"].(string); ok {
			trigger = v
		}
	}
	return map[string]interface{}{
		"statusCode": 200,
		"headers":    map[string]interface{}{"Content-Type": "application/json"},
		"body": map[string]interface{}{
			"runtime": "go", "version": strings.TrimPrefix(runtime.Version(), "go"), "sum": a + b, "trigger": trigger,
		},
	}, nil
}
GO
      echo main.go ;;
    *)
      return 1 ;;
  esac
}

# smoke_result NAME OUTPUT WANT... — OUTPUT (blanks removed) contains every WANT
smoke_result() {
  local name="$1" flat want missing=""
  flat="$(printf '%s' "$2" | tr -d ' \r\n')"
  shift 2
  for want in "$@"; do
    [[ "$flat" == *"$want"* ]] || missing="${missing:+${missing}, }${want}"
  done
  if [ -n "$missing" ]; then
    echo -e "  ${RED}${name}: missing ${missing}${NC}"
    return 1
  fi
}

runtime_smoke() {
  local image="$1" runtime="$2" version="$3"
  local tmp name file rc=0 http="" schedule="" retries
  tmp="$(mktemp -d)"
  name="runr-smoke-${runtime}-$$"
  file="$(smoke_handler "$runtime" "$tmp")" || { rmdir -- "$tmp"; echo -e "  ${RED}no smoke handler for ${runtime}${NC}"; return 1; }
  retries=$((SMOKE_TIMEOUT / 2))

  # http trigger: the image's server with the handler in /app/code; the request from a curl
  # container in the server's network namespace, retried while the server does not listen yet
  docker pull -q "$SMOKE_CURL_IMAGE" >/dev/null 2>&1 || true
  if docker create --name "$name" "$image" >/dev/null \
    && tar -C "$tmp" -cf - "$file" | docker cp - "${name}:/app/code" \
    && docker start "$name" >/dev/null; then
    # curl's errors (connection refused while the server starts) only when it fails
    http=$(docker run --rm --network "container:${name}" "$SMOKE_CURL_IMAGE" \
      -sS --retry "$retries" --retry-delay 2 --retry-connrefused --max-time 60 \
      -H 'Content-Type: application/json' -d '{"a": 40, "b": 2}' -w ' %{http_code}' \
      http://127.0.0.1:8080/smoke 2>"${tmp}/curl.err") || { rc=1; tail -n 5 "${tmp}/curl.err" | sed 's/^/  | /'; }
  else
    rc=1
  fi
  [ "$rc" = 0 ] || docker logs --tail 40 "$name" 2>&1 | sed 's/^/  | /' || true

  # schedule trigger (schedule: native): the runner calls the handler once and prints the result
  if [ "$rc" = 0 ]; then
    if docker create --name "${name}-schedule" -e RUNR_MODE=schedule "$image" >/dev/null \
      && tar -C "$tmp" -cf - "$file" | docker cp - "${name}-schedule:/app/code"; then
      schedule=$(docker start -a "${name}-schedule" 2>&1) || rc=1
    else
      rc=1
    fi
    [ "$rc" = 0 ] || printf '%s\n' "${schedule:-}" | tail -n 40 | sed 's/^/  | /'
  fi

  docker rm -f "$name" "${name}-schedule" >/dev/null 2>&1 || true
  rm -f -- "${tmp:?}/${file}" "${tmp:?}/curl.err"
  rmdir -- "$tmp"

  schedule="$(printf '%s\n' "${schedule:-}" | tail -n 1)"
  echo "  http:     ${http:-}"
  echo "  schedule: ${schedule}"
  smoke_result http "${http:-}" "\"runtime\":\"${runtime}\"" "\"version\":\"${version}." '"sum":42' '"trigger":"http"' '}200' || rc=1
  smoke_result schedule "$schedule" '"statusCode":200' "\"version\":\"${version}." '"sum":42' '"trigger":"schedule"' || rc=1
  if [ "$rc" != 0 ]; then
    echo -e "  ${RED}✗ smoke test of ${image} failed${NC}"
    return 1
  fi
  echo -e "  ${GREEN}✓ smoke test${NC}"
}

wrapper_smoke() {
  local image="$1" version="$2" out
  out=$(docker run --rm "$image" version 2>&1) || true
  echo "  runr-wrapper version: ${out}"
  if [ "$out" != "$version" ]; then
    echo -e "  ${RED}✗ smoke test of ${image} failed: the binary is not version ${version}${NC}"
    return 1
  fi
  echo -e "  ${GREEN}✓ smoke test${NC}"
}

wasm_smoke() {
  local image="$1" lang="$2" dir="$3" spin out rc=0
  spin=$(awk -F= '/^ARG SPIN_VERSION=/ { print $2; exit }' "${dir}/Dockerfile")
  out=$(docker run --rm --entrypoint spin "$image" --version 2>&1) || rc=1
  echo "  spin --version: ${out}"
  if [ -z "$spin" ] || [[ "$out" != "spin ${spin}"* ]]; then
    echo -e "  ${RED}not the Spin CLI of the Dockerfile (SPIN_VERSION=${spin:-?})${NC}"
    rc=1
  fi
  if [ "$lang" = exec ]; then
    out=$(docker run --rm --entrypoint runr-image-upload "$image" version 2>&1) || rc=1
    echo "  runr-image-upload version: ${out}"
    docker run --rm --entrypoint sh "$image" -c 'command -v runr-wasm-exec' >/dev/null 2>&1 \
      || { echo -e "  ${RED}runr-wasm-exec not found${NC}"; rc=1; }
  fi
  if [ "$rc" != 0 ]; then
    echo -e "  ${RED}✗ smoke test of ${image} failed${NC}"
    return 1
  fi
  echo -e "  ${GREEN}✓ smoke test${NC}"
}

hf_serve_smoke() {
  local image="$1" version="$2" variant="$3" out rc=0 gpu_skipped="" gpu_flags=()
  out=$(docker run --rm "$image" version 2>&1) || rc=1
  echo "  version:  ${out}"
  if [ "$out" != "$version" ]; then
    echo -e "  ${RED}not version ${version} (runr_hf_serve/__init__.py)${NC}"
    rc=1
  fi

  if [ "$variant" = cuda ]; then
    case "${ML_SMOKE_GPU:-auto}" in
      0) gpu_skipped="ML_SMOKE_GPU=0" ;;
      *)
        if ml_docker_gpu "$image"; then
          gpu_flags=(--gpus all)
        elif [ "${ML_SMOKE_GPU:-auto}" = 1 ]; then
          echo -e "  ${RED}✗ ML_SMOKE_GPU=1, but docker run --gpus all gives ${image} no GPU on this host${NC}"
          return 1
        else
          gpu_skipped="docker run --gpus all gives no GPU on this host"
        fi ;;
    esac
  fi

  # the server's modules with the framework, as `serve` imports them
  out=$(docker run --rm ${gpu_flags[@]+"${gpu_flags[@]}"} --entrypoint python "$image" -c '
import json, torch, transformers, runr_hf_serve.server
try:
    import diffusers
    diffusers_version = diffusers.__version__
except ImportError:
    diffusers_version = None
print(json.dumps({"torch": torch.__version__, "cuda": torch.version.cuda, "gpu": torch.cuda.is_available(),
                  "transformers": transformers.__version__, "diffusers": diffusers_version}))
' 2>&1 | tail -n 1) || rc=1
  echo "  imports:  ${out}"
  if [ "$variant" = cuda ]; then
    smoke_result imports "$out" '"cuda":"12.' '"diffusers":"' || rc=1
  else
    smoke_result imports "$out" '"cuda":null' '"transformers":"' || rc=1
  fi
  if [ "${#gpu_flags[@]}" -gt 0 ]; then
    if smoke_result GPU "$out" '"gpu":true'; then
      echo "  GPU:      torch sees the host's GPU"
    else
      rc=1
    fi
  elif [ -n "$gpu_skipped" ]; then
    echo -e "  ${YELLOW}GPU:      skipped (${gpu_skipped}): only the CUDA build is checked${NC}"
  fi
  if [ "$rc" != 0 ]; then
    echo -e "  ${RED}✗ smoke test of ${image} failed${NC}"
    return 1
  fi
  echo -e "  ${GREEN}✓ smoke test${NC}"
}
