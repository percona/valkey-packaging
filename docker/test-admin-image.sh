#!/bin/bash
#
# Functional test suite for Percona Valkey Admin Docker images
#
# Usage: ./test-admin-image.sh <image:tag> [image_type]
#   image_type: "hardened" or "rpm" (default: auto-detect from tag)
#
# This is a sibling of test-image.sh rather than another mode inside it:
# that suite is built around "valkey-cli ping" against a server image, and
# valkey-admin shares none of those assertions. What is checked here is that
# the web server answers, that a metrics collector actually starts and serves
# data (the server answering 200 proves nothing about the collectors), that
# the image runs unprivileged, and that the container-only configuration the
# entrypoint injects took effect.
#
# NOTE: text processing runs on the HOST side, as in test-image.sh, so the
#       same assertions work against images with a minimal userland.
#
set -euo pipefail

IMAGE="${1:?Usage: $0 <image:tag> [hardened|rpm]}"
TYPE="${2:-$(echo "$IMAGE" | grep -q hardened && echo hardened || echo rpm)}"
ADMIN_VERSION="${VALKEY_ADMIN_VERSION:-1.2.0}"
RUN_ID="$$"
CNT="valkey-admin-test-${RUN_ID}"
VK_CNT="valkey-admin-test-vk-${RUN_ID}"
NET="valkey-admin-test-net-${RUN_ID}"
ROVOL="valkey-admin-test-ro-${RUN_ID}"
VALKEY_IMAGE="${VALKEY_IMAGE:-valkey/valkey:8}"

PASSED=0
FAILED=0
TOTAL=0

cleanup() {
    docker rm -f "$CNT" "$VK_CNT" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
    docker volume rm "$ROVOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "   PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "   FAIL: $1"; }

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# Compare two values on the host so the image needs no text tools.
check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc (expected '$expected', got '$actual')"
    fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) pass "$desc" ;;
        *)           fail "$desc (no '$needle' in: $(echo "$haystack" | head -c 120))" ;;
    esac
}

# Poll the published port from the host; the image ships no HTTP client in the
# hardened case beyond node itself.
http_status() {
    local port="$1"
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}/" 2>/dev/null || echo 000
}

wait_http() {
    local port="$1" code
    for _ in $(seq 1 60); do
        code="$(http_status "$port")"
        [ "$code" = "200" ] && return 0
        sleep 1
    done
    return 1
}

wait_health() {
    local cnt="$1" status
    for _ in $(seq 1 45); do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cnt" 2>/dev/null || echo none)"
        [ "$status" = "healthy" ] && return 0
        [ "$status" = "none" ] && return 1
        sleep 2
    done
    return 1
}

echo "=============================================="
echo "Testing: $IMAGE (type: $TYPE)"
echo "=============================================="

echo ""
echo "1. Image metadata"

LABELS="$(docker inspect --format '{{json .Config.Labels}}' "$IMAGE")"
check_contains "vendor label is Percona" '"org.opencontainers.image.vendor":"Percona"' "$LABELS"
check_contains "version label is ${ADMIN_VERSION}" "\"org.opencontainers.image.version\":\"${ADMIN_VERSION}\"" "$LABELS"
check_contains "source label points at valkey-admin" 'valkey-admin' "$LABELS"
check_contains "base image is pinned by digest" '"org.opencontainers.image.base.digest":"sha256:' "$LABELS"

check_eq "runs as valkey-admin" "valkey-admin" "$(docker inspect --format '{{.Config.User}}' "$IMAGE")"
check_contains "exposes 8080/tcp" "8080/tcp" "$(docker inspect --format '{{range $p,$_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$IMAGE")"
check_contains "declares the data volume" "/var/lib/valkey-admin" "$(docker inspect --format '{{range $v,$_ := .Config.Volumes}}{{$v}} {{end}}' "$IMAGE")"
check_contains "defines a healthcheck" "fetch(" "$(docker inspect --format '{{json .Config.Healthcheck}}' "$IMAGE")"

echo ""
echo "2. Server starts and serves the UI"

docker network create "$NET" >/dev/null
docker run -d --name "$VK_CNT" --network "$NET" "$VALKEY_IMAGE" >/dev/null
docker run -d --name "$CNT" --network "$NET" \
    -e VALKEY_HOST="$VK_CNT" -e VALKEY_PORT=6379 \
    -p 18099:8080 "$IMAGE" >/dev/null

if wait_http 18099; then
    pass "GET / returns 200"
else
    fail "GET / returns 200 (last status: $(http_status 18099))"
    echo "--- container logs ---"
    docker logs "$CNT" 2>&1 | tail -30
fi

BODY_BYTES="$(curl -s --max-time 5 "http://127.0.0.1:18099/" | wc -c)"
if [ "$BODY_BYTES" -gt 0 ]; then
    pass "GET / body is non-empty (${BODY_BYTES} bytes)"
else
    fail "GET / body is non-empty"
fi

check "container is still running" \
    sh -c "[ \"\$(docker inspect --format '{{.State.Running}}' $CNT)\" = true ]"

echo ""
echo "3. Runs unprivileged"

ID_OUT="$(docker exec "$CNT" id 2>/dev/null || echo "")"
check_contains "effective user is valkey-admin" "(valkey-admin)" "$ID_OUT"
case "$ID_OUT" in
    uid=0*) fail "does not run as root" ;;
    "")     fail "does not run as root (could not read id)" ;;
    *)      pass "does not run as root" ;;
esac

echo ""
echo "4. Container configuration injected by the entrypoint"

# PID 1's environment, not `docker exec`'s: exec gets the image's Config.Env
# and would not show anything the entrypoint exported.
PID1_ENV="$(docker exec "$CNT" sh -c 'tr "\0" "\n" < /proc/1/environ' 2>/dev/null || echo "")"
check_contains "DEPLOYMENT_MODE=Web" "DEPLOYMENT_MODE=Web" "$PID1_ENV"
check_contains "SERVER_BIND_HOST=0.0.0.0" "SERVER_BIND_HOST=0.0.0.0" "$PID1_ENV"
check_contains "DATA_DIR on the volume" "DATA_DIR=/var/lib/valkey-admin" "$PID1_ENV"
check_contains "CONFIG_PATH on the volume" "CONFIG_PATH=/var/lib/valkey-admin/" "$PID1_ENV"

check "collector config seeded onto the data volume" \
    docker exec "$CNT" test -s /var/lib/valkey-admin/metrics-config.yml

echo ""
echo "5. Metrics collector runs and serves data"

# The collector is a child process; the server answering 200 says nothing about
# it. Its port is logged on registration.
COLLECTOR_PORT=""
for _ in $(seq 1 30); do
    COLLECTOR_PORT="$(docker logs "$CNT" 2>&1 | grep -oE 'registered for .* at http://127\.0\.0\.1:[0-9]+' | grep -oE '[0-9]+$' | tail -1 || true)"
    [ -n "$COLLECTOR_PORT" ] && break
    sleep 2
done

if [ -n "$COLLECTOR_PORT" ]; then
    pass "collector registered (port ${COLLECTOR_PORT})"

    MEM_OUT="$(docker exec "$CNT" node -e "
        fetch('http://127.0.0.1:${COLLECTOR_PORT}/memory')
          .then(r => r.text().then(t => console.log(r.status + ' ' + t.length)))
          .catch(e => { console.log('FAIL ' + e.message); process.exit(1); })
    " 2>/dev/null || echo "FAIL")"
    case "$MEM_OUT" in
        "200 "*) pass "collector /memory returns data ($MEM_OUT bytes)" ;;
        *)       fail "collector /memory returns data (got: $MEM_OUT)" ;;
    esac
else
    fail "collector registered"
    echo "--- container logs ---"
    docker logs "$CNT" 2>&1 | tail -30
fi

# Collectors write under DATA_DIR/<host>-<port>/ (valkey-admin < 1.3.0) or,
# since 1.3.0, under a per-owner directory: DATA_DIR/<owner>/<host>-<port>/.
# Accept either layout. The first rows are written right after the collector's
# initial fetch, so a short wait covers a slow start.
NDJSON_GLOBS="/var/lib/valkey-admin/${VK_CNT}-6379/*.ndjson /var/lib/valkey-admin/*/${VK_CNT}-6379/*.ndjson"
NDJSON_FOUND=""
for _ in $(seq 1 15); do
    if docker exec "$CNT" sh -c "for f in ${NDJSON_GLOBS}; do [ -e \"\$f\" ] && exit 0; done; exit 1" >/dev/null 2>&1; then
        NDJSON_FOUND=1
        break
    fi
    sleep 2
done
if [ -n "$NDJSON_FOUND" ]; then
    pass "collector wrote metrics to the data volume"
else
    fail "collector wrote metrics to the data volume"
    echo "--- data volume ---"
    docker exec "$CNT" sh -c 'ls -laR /var/lib/valkey-admin' 2>&1 | tail -30
fi

echo ""
echo "6. Node runtime"

NODE_MAJOR="$(docker exec "$CNT" node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -ge 20 ]; then
    pass "node major version is >= 20 (got ${NODE_MAJOR})"
else
    fail "node major version is >= 20 (got ${NODE_MAJOR})"
fi

echo ""
echo "7. SBOM shipped in the image"

check "SPDX SBOM present" docker exec "$CNT" test -s /usr/local/valkey-admin.spdx.json
check "CycloneDX SBOM present" docker exec "$CNT" test -s /usr/local/valkey-admin.cdx.json

echo ""
echo "8. Healthcheck reaches healthy"

if wait_health "$CNT"; then
    pass "docker healthcheck reports healthy"
else
    fail "docker healthcheck reports healthy (status: $(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CNT"))"
fi

docker rm -f "$CNT" >/dev/null 2>&1

echo ""
echo "9. PORT override is honoured"

docker run -d --name "$CNT" --network "$NET" -e PORT=9090 -p 18098:9090 "$IMAGE" >/dev/null
if wait_http 18098; then
    pass "serves on an overridden PORT"
else
    fail "serves on an overridden PORT (last status: $(http_status 18098))"
    docker logs "$CNT" 2>&1 | tail -20
fi
docker rm -f "$CNT" >/dev/null 2>&1

echo ""
echo "10. Read-only data volume falls back instead of failing"

# Proves the entrypoint's fallback branch is real: with an unwritable data
# volume it must still serve, using the packaged collector config.
# A named volume, not a host path: a bind mount would have the daemon create
# the directory on the host as root and leave it behind.
docker volume create "$ROVOL" >/dev/null
docker run -d --name "$CNT" --network "$NET" \
    -v "${ROVOL}:/var/lib/valkey-admin:ro" \
    -p 18097:8080 "$IMAGE" >/dev/null 2>&1 || true
if wait_http 18097; then
    pass "serves with a read-only data volume"
    check_contains "falls back to the packaged collector config" \
        "CONFIG_PATH=/usr/lib/percona-valkey-admin-server" \
        "$(docker exec "$CNT" sh -c 'tr "\0" "\n" < /proc/1/environ' 2>/dev/null || echo "")"
else
    fail "serves with a read-only data volume (last status: $(http_status 18097))"
    docker logs "$CNT" 2>&1 | tail -20
fi
docker rm -f "$CNT" >/dev/null 2>&1

echo ""
echo "=============================================="
echo "Results for $IMAGE ($TYPE)"
echo "  passed: $PASSED"
echo "  failed: $FAILED"
echo "  total:  $TOTAL"
echo "=============================================="

# A run that asserted nothing is a failure, not a pass: an empty suite would
# otherwise exit 0 and look like success.
if [ "$TOTAL" -eq 0 ]; then
    echo "no assertions ran"
    exit 1
fi

[ "$FAILED" -eq 0 ]
