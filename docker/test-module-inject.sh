#!/usr/bin/env bash
# test-module-inject.sh — verify a thin module artifact image injects into a
# stock Percona Valkey server and loads.
#
# The artifact image is copied into a shared volume (the k8s initContainer
# step), then a stock server is started with --loadmodule pointing at the
# injected .so. The server only comes up if the module and its self-contained
# dependencies resolve, so a successful start is itself the load proof.
#
# Usage: test-module-inject.sh <module-image:tag> <module> [server-image:tag]
set -euo pipefail

MOD_IMAGE="${1:?Usage: $0 <module-image:tag> <module> [server-image:tag]}"
MODULE="${2:?Usage: $0 <module-image:tag> <module> [server-image:tag]}"
VALKEY_VERSION="${VALKEY_VERSION:-9.1.4}"
SRV_IMAGE="${3:-perconalab/valkey:${VALKEY_VERSION}}"

# module -> .so filename and the name it registers under in MODULE LIST
case "$MODULE" in
    json)   SO=libjson.so;         NAME=json ;;
    bloom)  SO=libvalkey_bloom.so; NAME=bf ;;
    search) SO=libsearch.so;       NAME=search ;;
    ldap)   SO=libvalkey_ldap.so;  NAME=ldap ;;
    audit)  SO=libvalkeyaudit.so;  NAME=audit ;;
    *) echo "unknown module: $MODULE" >&2; exit 2 ;;
esac

VOL="valkey-mod-$$"
CNT="valkey-modtest-$$"
PASSED=0; FAILED=0; TOTAL=0

cleanup() {
    docker rm -f "$CNT" >/dev/null 2>&1 || true
    docker volume rm "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "   PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "   FAIL: $1"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

wait_ready() {
    for _ in $(seq 1 20); do
        if docker exec "$1" valkey-cli ping 2>/dev/null | grep -q PONG; then return 0; fi
        sleep 0.5
    done
    return 1
}

echo "=== Inject '$MODULE' ($SO) from $MOD_IMAGE into $SRV_IMAGE ==="
docker volume create "$VOL" >/dev/null

# k8s initContainer step: copy the module tree into the shared volume.
check "artifact copies module tree into shared volume" \
    docker run --rm -v "$VOL:/shared" "$MOD_IMAGE" cp -a "/modules/$MODULE" /shared/

# Stock server loads the injected module; a clean start means it resolved.
docker run -d --name "$CNT" -v "$VOL:/shared" "$SRV_IMAGE" \
    --loadmodule "/shared/$MODULE/$SO" >/dev/null
check "server starts with --loadmodule (module + deps resolved)" wait_ready "$CNT"
check "MODULE LIST reports '$NAME'" \
    sh -c "docker exec '$CNT' valkey-cli MODULE LIST | grep -qi '$NAME'"

case "$MODULE" in
    json)
        check "JSON.SET / JSON.GET round-trip" sh -c \
            "docker exec '$CNT' valkey-cli JSON.SET k '\$' '\"v\"' | grep -q OK && \
             docker exec '$CNT' valkey-cli JSON.GET k | grep -q v" ;;
    bloom)
        check "BF.ADD / BF.EXISTS round-trip" sh -c \
            "docker exec '$CNT' valkey-cli BF.ADD k x | grep -q 1 && \
             docker exec '$CNT' valkey-cli BF.EXISTS k x | grep -q 1" ;;
    search)
        check "FT._LIST responds" \
            docker exec "$CNT" valkey-cli FT._LIST ;;
esac

echo ""
echo "Results: $PASSED passed, $FAILED failed (out of $TOTAL)"
[ "$FAILED" -eq 0 ]
