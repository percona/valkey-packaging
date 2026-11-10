#!/bin/bash
#
# Functional test suite for Percona Valkey Docker images
#
# Usage: ./test-image.sh <image:tag> [image_type]
#   image_type: "hardened" or "rpm" (default: auto-detect from tag)
#
# NOTE: All grep/text processing runs on the HOST side because
#       hardened (DHI distroless) images lack grep, cat, touch, etc.
#
# SBOMs: the image-level SBOM is a BuildKit attestation attached to the pushed
#        image (--sbom=true), not a file inside the image. Images ship no SBOM
#        files (package-shipped ones are removed at build time), so nothing
#        SBOM-related is checked here.
#
set -euo pipefail

IMAGE="${1:?Usage: $0 <image:tag> [hardened|rpm|bundle-rpm|bundle-hardened]}"
TYPE="${2:-$(echo "$IMAGE" | grep -q hardened && echo hardened || echo rpm)}"
VALKEY_VERSION="${VALKEY_VERSION:-9.1.2}"
CNT="valkey-test-$$"

case "$TYPE" in
    *bundle*)   IS_BUNDLE=1 ;;
    *)          IS_BUNDLE=0 ;;
esac
case "$TYPE" in
    *hardened*) IS_HARDENED=1 ;;
    *)          IS_HARDENED=0 ;;
esac

PASSED=0
FAILED=0
TOTAL=0

cleanup() {
    docker rm -f "$CNT" 2>/dev/null || true
}
trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    TOTAL=$((TOTAL + 1))
    echo "   PASS: $1"
}

fail() {
    FAILED=$((FAILED + 1))
    TOTAL=$((TOTAL + 1))
    echo "   FAIL: $1"
}

check() {
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

# Wait for valkey to be ready (up to 10 seconds)
wait_ready() {
    local cnt="$1"
    for i in $(seq 1 20); do
        if docker exec "$cnt" valkey-cli ping 2>/dev/null | grep -q PONG; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Wait for valkey with password to be ready
wait_ready_auth() {
    local cnt="$1"
    local pass="$2"
    for i in $(seq 1 20); do
        if docker exec "$cnt" valkey-cli --no-auth-warning -a "$pass" ping 2>/dev/null | grep -q PONG; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Run valkey-cli in container, match output with grep on HOST
# Usage: cli_grep <container> <pattern> <cli-args...>
cli_grep() {
    docker exec "$1" valkey-cli "${@:3}" | grep -q "$2"
}

# Run valkey-cli with auth, match output with grep on HOST
# Usage: cli_grep_auth <container> <password> <pattern> <cli-args...>
cli_grep_auth() {
    docker exec "$1" valkey-cli --no-auth-warning -a "$2" "${@:4}" | grep -q "$3"
}

echo "============================================="
echo "Testing: $IMAGE ($TYPE)"
echo "Expected version: $VALKEY_VERSION"
echo "============================================="
echo ""

# -----------------------------------------------
echo "--- Static checks ---"
# -----------------------------------------------

echo "1. valkey-server binary:"
docker run --rm "$IMAGE" valkey-server --version
check "version string contains $VALKEY_VERSION" \
    sh -c "docker run --rm '$IMAGE' valkey-server --version 2>&1 | grep -q '$VALKEY_VERSION'"

echo "2. valkey-cli binary:"
docker run --rm "$IMAGE" valkey-cli --version

echo "3. valkey-benchmark binary:"
check "valkey-benchmark present" \
    docker run --rm "$IMAGE" valkey-benchmark --version

echo "3b. valkey-sentinel binary:"
# Sentinel ships in its own DEB package (percona-valkey-sentinel); the RPM bundles
# it in the main package. Assert it is present so the DEB/RPM image asymmetry —
# where the hardened image shipped no sentinel — cannot regress.
check "valkey-sentinel present" \
    docker run --rm "$IMAGE" valkey-sentinel --version

echo "4. Non-root user:"
docker run --rm "$IMAGE" id
check "UID is not 0" \
    docker run --rm "$IMAGE" sh -c '[ "$(id -u)" != "0" ]'

echo "5. Config directory:"
check "/etc/valkey exists" \
    docker run --rm --entrypoint="" "$IMAGE" test -d /etc/valkey

echo "6. Data directory:"
check "/data exists and is writable" \
    docker run --rm "$IMAGE" sh -c 'test -d /data && : > /data/.writetest'

echo "7. Exposed port:"
check "port 6379 is declared" \
    sh -c "docker inspect '$IMAGE' | grep -q '6379/tcp'"

echo "8. OCI labels:"
check "vendor label is Percona" \
    sh -c "docker inspect '$IMAGE' | grep -q '\"org.opencontainers.image.vendor\": \"Percona\"'"
check "version label is $VALKEY_VERSION" \
    sh -c "docker inspect '$IMAGE' | grep -q '\"org.opencontainers.image.version\": \"$VALKEY_VERSION\"'"

if [ "$IS_HARDENED" = "1" ]; then
    echo "10. Base image label:"
    check "base image label references DHI" \
        sh -c "docker inspect '$IMAGE' | grep -q 'dhi.io'"
fi

echo ""

# -----------------------------------------------
echo "--- Functional tests: basic operations ---"
# -----------------------------------------------

cleanup
docker run -d --name "$CNT" "$IMAGE" > /dev/null
echo "Starting container..."
check "server starts and responds to PING" wait_ready "$CNT"

if [ "$IS_BUNDLE" = "1" ]; then
    echo "10b. Bundle modules auto-loaded (MODULE LIST):"
    # The bundle entrypoint auto-loads every module in the module dir. Each must
    # show up in MODULE LIST under its registered name.
    for mod in json bf search ldap audit; do
        check "module '$mod' is loaded" \
            sh -c "docker exec '$CNT' valkey-cli MODULE LIST | grep -q '$mod'"
    done
    echo "10c. Module commands respond:"
    check "JSON.SET / JSON.GET round-trip" \
        docker exec "$CNT" sh -c "valkey-cli JSON.SET bt '\$' '{\"a\":1}' >/dev/null && [ \"\$(valkey-cli JSON.GET bt '\$.a')\" = '[1]' ]"
    check "BF.ADD / BF.EXISTS round-trip" \
        docker exec "$CNT" sh -c '[ "$(valkey-cli BF.ADD bfk x)" = "1" ] && [ "$(valkey-cli BF.EXISTS bfk x)" = "1" ]'
    # search: create a vector index, confirm it shows up, then drop it.
    check "FT.CREATE creates an index" \
        docker exec "$CNT" valkey-cli FT.CREATE bt_idx ON HASH PREFIX 1 doc: \
            SCHEMA v VECTOR HNSW 6 TYPE FLOAT32 DIM 3 DISTANCE_METRIC L2
    # NOTE: grep runs on the HOST (hardened/distroless images have no grep) — only
    # valkey-cli runs inside the container via docker exec, its output piped out.
    check "FT._LIST shows the new index" \
        sh -c "docker exec '$CNT' valkey-cli FT._LIST | grep -q bt_idx"
    check "FT.INFO returns index details" \
        sh -c "docker exec '$CNT' valkey-cli FT.INFO bt_idx | grep -q bt_idx"
    check "FT.DROPINDEX removes the index" \
        sh -c "docker exec '$CNT' valkey-cli FT.DROPINDEX bt_idx >/dev/null && ! docker exec '$CNT' valkey-cli FT._LIST | grep -q bt_idx"

fi

echo "11. SET/GET string:"
check "SET returns OK" \
    docker exec "$CNT" valkey-cli SET mykey myvalue
check "GET returns correct value" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli GET mykey)" = "myvalue" ]'

echo "12. MSET/MGET (multi-key):"
check "MSET multiple keys" \
    docker exec "$CNT" valkey-cli MSET k1 v1 k2 v2 k3 v3
check "MGET returns all values" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli MGET k1 k2 k3 | wc -l)" = "3" ]'

echo "13. INCR/DECR (atomic counters):"
check "SET counter" \
    docker exec "$CNT" valkey-cli SET counter 10
check "INCR increments" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli INCR counter)" = "11" ]'
check "DECRBY decrements" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli DECRBY counter 5)" = "6" ]'

echo "14. APPEND and STRLEN:"
check "APPEND extends string" \
    docker exec "$CNT" sh -c 'valkey-cli SET greeting hello > /dev/null && valkey-cli APPEND greeting " world" > /dev/null && [ "$(valkey-cli GET greeting)" = "hello world" ]'
check "STRLEN returns length" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli STRLEN greeting)" = "11" ]'

echo "15. LIST operations:"
check "RPUSH creates list" \
    docker exec "$CNT" sh -c 'valkey-cli RPUSH mylist a b c > /dev/null && [ "$(valkey-cli LLEN mylist)" = "3" ]'
check "LPUSH prepends" \
    docker exec "$CNT" sh -c 'valkey-cli LPUSH mylist z > /dev/null && [ "$(valkey-cli LINDEX mylist 0)" = "z" ]'
check "LRANGE returns range" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli LRANGE mylist 0 -1 | wc -l)" = "4" ]'
check "RPOP removes from tail" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli RPOP mylist)" = "c" ]'

echo "16. HASH operations:"
check "HSET/HGET single field" \
    docker exec "$CNT" sh -c 'valkey-cli HSET myhash field1 val1 > /dev/null && [ "$(valkey-cli HGET myhash field1)" = "val1" ]'
check "HMSET multiple fields" \
    docker exec "$CNT" sh -c 'valkey-cli HSET myhash field2 val2 field3 val3 > /dev/null && [ "$(valkey-cli HLEN myhash)" = "3" ]'
check "HDEL removes field" \
    docker exec "$CNT" sh -c 'valkey-cli HDEL myhash field3 > /dev/null && [ "$(valkey-cli HEXISTS myhash field3)" = "0" ]'
check "HGETALL returns all" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli HGETALL myhash | wc -l)" = "4" ]'

echo "17. SET (unordered collection):"
check "SADD/SCARD" \
    docker exec "$CNT" sh -c 'valkey-cli SADD myset x y z > /dev/null && [ "$(valkey-cli SCARD myset)" = "3" ]'
check "SISMEMBER checks membership" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli SISMEMBER myset x)" = "1" ]'
check "SREM removes member" \
    docker exec "$CNT" sh -c 'valkey-cli SREM myset z > /dev/null && [ "$(valkey-cli SCARD myset)" = "2" ]'

echo "18. SORTED SET:"
check "ZADD/ZSCORE" \
    docker exec "$CNT" sh -c 'valkey-cli ZADD myzset 1.5 member1 2.5 member2 3.5 member3 > /dev/null && [ "$(valkey-cli ZSCORE myzset member1)" = "1.5" ]'
check "ZRANK returns position" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli ZRANK myzset member1)" = "0" ]'
check "ZRANGEBYSCORE filters by score" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli ZRANGEBYSCORE myzset 2 4 | wc -l)" = "2" ]'
check "ZCARD returns count" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli ZCARD myzset)" = "3" ]'

echo "19. Key expiry (TTL):"
check "SET with EX" \
    docker exec "$CNT" sh -c 'valkey-cli SET tmpkey tmpval EX 300 > /dev/null && [ "$(valkey-cli TTL tmpkey)" -gt 0 ]'
check "PTTL returns milliseconds" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli PTTL tmpkey)" -gt 0 ]'
check "PERSIST removes expiry" \
    docker exec "$CNT" sh -c 'valkey-cli PERSIST tmpkey > /dev/null && [ "$(valkey-cli TTL tmpkey)" = "-1" ]'

echo "20. Key management:"
check "EXISTS returns 1 for existing key" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli EXISTS mykey)" = "1" ]'
check "TYPE returns string" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli TYPE mykey)" = "string" ]'
check "TYPE returns list" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli TYPE mylist)" = "list" ]'
check "RENAME renames key" \
    docker exec "$CNT" sh -c 'valkey-cli RENAME mykey mykey_renamed > /dev/null && [ "$(valkey-cli GET mykey_renamed)" = "myvalue" ]'
check "DEL removes key" \
    docker exec "$CNT" sh -c 'valkey-cli DEL mykey_renamed > /dev/null && [ "$(valkey-cli EXISTS mykey_renamed)" = "0" ]'
check "KEYS pattern matching" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli KEYS "my*" | wc -l)" -gt 0 ]'

echo "21. INFO server:"
check "reports correct version" \
    cli_grep "$CNT" "valkey_version:$VALKEY_VERSION" INFO server
check "reports tcp_port:6379" \
    cli_grep "$CNT" "tcp_port:6379" INFO server
check "reports uptime" \
    cli_grep "$CNT" "uptime_in_seconds" INFO server

echo "22. DBSIZE and SELECT:"
check "DBSIZE reports keys" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli DBSIZE)" -gt 0 ]'
check "SELECT switches database" \
    docker exec "$CNT" sh -c 'valkey-cli SELECT 1 > /dev/null && valkey-cli -n 1 SET db1key db1val > /dev/null && [ "$(valkey-cli -n 1 GET db1key)" = "db1val" ]'

echo "23. CONFIG GET/SET:"
check "CONFIG GET maxmemory-policy" \
    docker exec "$CNT" valkey-cli CONFIG GET maxmemory-policy
check "CONFIG SET and verify" \
    sh -c "docker exec '$CNT' valkey-cli CONFIG SET hz 20 >/dev/null && docker exec '$CNT' valkey-cli CONFIG GET hz | grep -q 20"

echo "24. FLUSHDB:"
check "FLUSHDB clears current database" \
    docker exec "$CNT" sh -c 'valkey-cli FLUSHDB > /dev/null && [ "$(valkey-cli DBSIZE)" = "0" ]'

cleanup
echo ""

# -----------------------------------------------
echo "--- Functional tests: transactions ---"
# -----------------------------------------------

docker run -d --name "$CNT" "$IMAGE" > /dev/null
check "server starts" wait_ready "$CNT"

echo "25. MULTI/EXEC transaction:"
check "MULTI/EXEC executes atomically" \
    sh -c "
        docker exec '$CNT' valkey-cli SET txkey 100 >/dev/null
        printf 'MULTI\nINCR txkey\nINCR txkey\nEXEC\n' | docker exec -i '$CNT' valkey-cli >/dev/null
        [ \"\$(docker exec '$CNT' valkey-cli GET txkey)\" = '102' ]
    "

echo "26. WATCH/DISCARD:"
check "DISCARD aborts transaction" \
    sh -c "
        docker exec '$CNT' valkey-cli SET discardkey original >/dev/null
        printf 'MULTI\nSET discardkey changed\nDISCARD\n' | docker exec -i '$CNT' valkey-cli >/dev/null
        [ \"\$(docker exec '$CNT' valkey-cli GET discardkey)\" = 'original' ]
    "

cleanup
echo ""

# -----------------------------------------------
echo "--- Functional tests: entrypoint ---"
# -----------------------------------------------

echo "27. Entrypoint passes flags to server:"
docker run -d --name "$CNT" "$IMAGE" --loglevel verbose > /dev/null
check "server starts with custom flag" wait_ready "$CNT"
check "loglevel is verbose" \
    cli_grep "$CNT" "verbose" CONFIG GET loglevel
cleanup

echo "28. Entrypoint handles maxmemory flag:"
docker run -d --name "$CNT" "$IMAGE" --maxmemory 128mb > /dev/null
check "server starts with maxmemory" wait_ready "$CNT"
check "maxmemory is 128mb" \
    cli_grep "$CNT" "134217728" CONFIG GET maxmemory
cleanup

echo "29. Entrypoint handles multiple flags:"
docker run -d --name "$CNT" "$IMAGE" --loglevel verbose --maxmemory 64mb --tcp-backlog 256 > /dev/null
check "server starts with multiple flags" wait_ready "$CNT"
check "loglevel is verbose" \
    cli_grep "$CNT" "verbose" CONFIG GET loglevel
check "maxmemory is 64mb" \
    cli_grep "$CNT" "67108864" CONFIG GET maxmemory
check "tcp-backlog is 256" \
    cli_grep "$CNT" "256" CONFIG GET tcp-backlog
cleanup

echo "30. VALKEY_PASSWORD env var:"
docker run -d --name "$CNT" -e VALKEY_PASSWORD=testpass123 "$IMAGE" > /dev/null
check "server starts with password" wait_ready_auth "$CNT" testpass123
check "unauthenticated PING is rejected" \
    sh -c "docker exec '$CNT' valkey-cli PING 2>&1 | grep -q NOAUTH"
check "authenticated PING succeeds" \
    cli_grep_auth "$CNT" testpass123 "PONG" PING
check "authenticated SET/GET works" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli --no-auth-warning -a testpass123 GET authkey 2>/dev/null)" = "" ] && valkey-cli --no-auth-warning -a testpass123 SET authkey authval > /dev/null && [ "$(valkey-cli --no-auth-warning -a testpass123 GET authkey)" = "authval" ]'
cleanup

echo "31. VALKEY_MAXMEMORY env var:"
docker run -d --name "$CNT" -e VALKEY_MAXMEMORY=256mb "$IMAGE" > /dev/null
check "server starts with VALKEY_MAXMEMORY" wait_ready "$CNT"
check "maxmemory is 256mb" \
    cli_grep "$CNT" "268435456" CONFIG GET maxmemory
cleanup

echo "32. VALKEY_BIND env var:"
docker run -d --name "$CNT" -e VALKEY_BIND="127.0.0.1" "$IMAGE" > /dev/null
check "server starts with VALKEY_BIND" wait_ready "$CNT"
check "bind is 127.0.0.1" \
    cli_grep "$CNT" "127.0.0.1" CONFIG GET bind
cleanup

echo "33. Combined env vars:"
docker run -d --name "$CNT" -e VALKEY_PASSWORD=combo123 -e VALKEY_MAXMEMORY=512mb "$IMAGE" > /dev/null
check "server starts with combined env vars" wait_ready_auth "$CNT" combo123
check "password works" \
    cli_grep_auth "$CNT" combo123 "PONG" PING
check "maxmemory is 512mb" \
    cli_grep_auth "$CNT" combo123 "536870912" CONFIG GET maxmemory
cleanup

echo ""

# -----------------------------------------------
echo "--- Functional tests: persistence ---"
# -----------------------------------------------

echo "34. Data survives restart:"
docker run -d --name "$CNT" "$IMAGE" > /dev/null
check "server starts" wait_ready "$CNT"
docker exec "$CNT" valkey-cli SET persist_test survive > /dev/null
check "SAVE writes RDB" \
    sh -c "docker exec '$CNT' valkey-cli SAVE | grep -q OK"
sleep 1
docker stop "$CNT" > /dev/null
docker start "$CNT" > /dev/null
check "server restarts" wait_ready "$CNT"
check "data persists after restart" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli GET persist_test)" = "survive" ]'
cleanup

echo "35. BGSAVE and LASTSAVE:"
docker run -d --name "$CNT" "$IMAGE" > /dev/null
check "server starts" wait_ready "$CNT"
check "BGSAVE triggers save" \
    docker exec "$CNT" valkey-cli BGSAVE
sleep 1
check "LASTSAVE returns timestamp" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli LASTSAVE)" -gt 0 ]'
cleanup

echo ""

# -----------------------------------------------
echo "--- Functional tests: pub/sub & scripting ---"
# -----------------------------------------------

docker run -d --name "$CNT" "$IMAGE" > /dev/null
check "server starts" wait_ready "$CNT"

echo "36. Pub/Sub:"
check "PUBSUB CHANNELS works" \
    docker exec "$CNT" valkey-cli PUBSUB CHANNELS '*'
check "PUBSUB NUMSUB works" \
    docker exec "$CNT" valkey-cli PUBSUB NUMSUB

echo "37. Lua scripting:"
check "EVAL returns value" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli EVAL "return 42" 0)" = "42" ]'
check "EVAL string concat" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli EVAL "return \"hello\"" 0)" = "hello" ]'
check "EVAL with keys" \
    docker exec "$CNT" sh -c 'valkey-cli SET luakey luaval > /dev/null && [ "$(valkey-cli EVAL "return redis.call(\"GET\", KEYS[1])" 1 luakey)" = "luaval" ]'
check "EVAL table return" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli EVAL "return {1,2,3}" 0 | wc -l)" = "3" ]'

echo "38. SCAN cursor iteration:"
docker exec "$CNT" valkey-cli MSET scankey1 a scankey2 b scankey3 c > /dev/null
check "SCAN finds keys" \
    cli_grep "$CNT" "scankey" SCAN 0 MATCH "scankey*" COUNT 10

cleanup
echo ""

# -----------------------------------------------
echo "--- Functional tests: memory & diagnostics ---"
# -----------------------------------------------

docker run -d --name "$CNT" "$IMAGE" > /dev/null
check "server starts" wait_ready "$CNT"

echo "39. MEMORY USAGE:"
docker exec "$CNT" valkey-cli SET memtest "hello world" > /dev/null
check "MEMORY USAGE returns bytes" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli MEMORY USAGE memtest)" -gt 0 ]'

echo "40. CLIENT LIST:"
check "CLIENT LIST shows connections" \
    cli_grep "$CNT" "addr=" CLIENT LIST

echo "41. SLOWLOG:"
check "SLOWLOG GET returns entries" \
    docker exec "$CNT" valkey-cli SLOWLOG GET

echo "42. OBJECT ENCODING:"
docker exec "$CNT" valkey-cli SET enctest 12345 > /dev/null
check "OBJECT ENCODING works" \
    cli_grep "$CNT" "int" OBJECT ENCODING enctest

echo "43. RANDOMKEY:"
check "RANDOMKEY returns a key" \
    docker exec "$CNT" sh -c '[ -n "$(valkey-cli RANDOMKEY)" ]'

echo "44. WAIT command (replication check):"
check "WAIT returns 0 replicas (standalone)" \
    docker exec "$CNT" sh -c '[ "$(valkey-cli WAIT 0 0)" = "0" ]'

cleanup
echo ""

# -----------------------------------------------
echo "============================================="
echo "Results: $PASSED passed, $FAILED failed (out of $TOTAL)"
echo "============================================="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
