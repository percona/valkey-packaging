#!/bin/bash
set -euo pipefail

# Launches a published AMI, verifies first-boot behaviour against the running
# instance, and terminates it. Exits non-zero if any check fails.
#
# Usage: smoke.sh <ami-id> <region> <variant> [instance-type]
#
# Required environment:
#   SMOKE_SUBNET_ID           subnet to launch into
#   SMOKE_SECURITY_GROUP_ID   security group allowing SSH from this host
#   SMOKE_KEY_NAME            EC2 key pair name
#   SMOKE_KEY_FILE            matching private key file

usage() {
    echo "usage: smoke.sh <ami-id> <region> <variant> [instance-type]" >&2
    exit 2
}

[ "$#" -ge 3 ] || usage

AMI_ID="$1"
REGION="$2"
VARIANT="$3"
INSTANCE_TYPE="${4:-t3.medium}"

case "$VARIANT" in
    slim|bundle) ;;
    *) echo "variant must be slim or bundle, got '${VARIANT}'" >&2; exit 2 ;;
esac

for tool in aws ssh timeout; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "required tool '${tool}' is not installed" >&2
        exit 2
    }
done

: "${SMOKE_SUBNET_ID:?SMOKE_SUBNET_ID must be set}"
: "${SMOKE_SECURITY_GROUP_ID:?SMOKE_SECURITY_GROUP_ID must be set}"
: "${SMOKE_KEY_NAME:?SMOKE_KEY_NAME must be set}"
: "${SMOKE_KEY_FILE:?SMOKE_KEY_FILE must be set}"

INSTANCE_ID=""
PUBLIC_IP=""
FAILURES=0

cleanup() {
    if [ -n "$INSTANCE_ID" ]; then
        echo "Terminating ${INSTANCE_ID}"
        aws ec2 terminate-instances --region "$REGION" \
            --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

check() {
    local description="$1"
    shift
    if "$@"; then
        printf 'ok       %s\n' "$description"
    else
        printf 'FAIL     %s\n' "$description"
        FAILURES=$(( FAILURES + 1 ))
    fi
}

remote() {
    ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -o ConnectTimeout=10 \
        -i "$SMOKE_KEY_FILE" "ec2-user@${PUBLIC_IP}" "$@"
}

wait_for_ssh() {
    local elapsed=0
    while [ "$elapsed" -lt 300 ]; do
        if remote true >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    return 1
}

###############################################################################
# Launch
###############################################################################

echo "Launching ${AMI_ID} (${VARIANT}, ${INSTANCE_TYPE}) in ${REGION}"

INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --subnet-id "$SMOKE_SUBNET_ID" \
    --security-group-ids "$SMOKE_SECURITY_GROUP_ID" \
    --key-name "$SMOKE_KEY_NAME" \
    --associate-public-ip-address \
    --tag-specifications \
        "ResourceType=instance,Tags=[{Key=Name,Value=valkey-smoke-${VARIANT}},{Key=iit-billing-tag,Value=valkey-ami}]" \
    --query 'Instances[0].InstanceId' --output text)"

echo "Instance ${INSTANCE_ID}, waiting for status ok"
aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP="$(aws ec2 describe-instances --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "Public address ${PUBLIC_IP}, waiting for ssh"
if ! wait_for_ssh; then
    echo "ssh never became available" >&2
    exit 1
fi

###############################################################################
# Console output
###############################################################################

console_has_banner() {
    local elapsed=0 console
    while [ "$elapsed" -lt 180 ]; do
        console="$(aws ec2 get-console-output --region "$REGION" \
            --instance-id "$INSTANCE_ID" --output text 2>/dev/null || true)"
        if grep -q 'Percona Valkey' <<<"$console"; then
            return 0
        fi
        sleep 15
        elapsed=$(( elapsed + 15 ))
    done
    return 1
}

check "console output contains the credential banner" console_has_banner

###############################################################################
# Credentials and service state
###############################################################################

PASSWORD="$(remote "sudo grep '^requirepass ' /etc/valkey/valkey-generated.conf | cut -d' ' -f2")"

check "a password was generated" test -n "$PASSWORD"

motd_shows_password() {
    remote "sudo grep -q '${PASSWORD}' /etc/motd.d/30-valkey"
}

check "the motd shows the generated password" motd_shows_password

SERVICE_STATE="$(remote "systemctl is-active valkey@default.service" || true)"
check "the valkey instance is active" test "$SERVICE_STATE" = "active"

MARKER_PRESENT="$(remote "test -e /etc/valkey/.firstboot-done && echo yes || echo no")"
check "the first-boot marker was created" test "$MARKER_PRESENT" = "yes"

###############################################################################
# Functional checks
###############################################################################

PING="$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning PING" || true)"
check "the server answers PING" test "$PING" = "PONG"

NOAUTH="$(remote "valkey-cli PING 2>&1 | head -1" || true)"
authentication_required() {
    grep -q 'NOAUTH' <<<"$NOAUTH"
}
check "unauthenticated access is refused" authentication_required

ROUNDTRIP="$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning SET smoke ok >/dev/null && valkey-cli -a '${PASSWORD}' --no-auth-warning GET smoke" || true)"
check "a set and get round trip succeeds" test "$ROUNDTRIP" = "ok"

###############################################################################
# Memory sizing
###############################################################################

MAXMEMORY="$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning CONFIG GET maxmemory | tail -1")"
MEMTOTAL_KB="$(remote "awk '/^MemTotal:/ { print \$2 }' /proc/meminfo")"
EXPECTED=$(( MEMTOTAL_KB * 1024 * 70 / 100 ))
TOLERANCE=$(( EXPECTED / 100 ))

within_tolerance() {
    [ "$1" -gt $(( EXPECTED - TOLERANCE )) ] && [ "$1" -lt $(( EXPECTED + TOLERANCE )) ]
}

check "maxmemory is approximately 70 percent of instance memory" \
    within_tolerance "$MAXMEMORY"

POLICY="$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning CONFIG GET maxmemory-policy | tail -1")"
check "the eviction policy is noeviction" test "$POLICY" = "noeviction"

###############################################################################
# Modules
###############################################################################

MODULES="$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning MODULE LIST" || true)"

module_loaded() {
    grep -qE "(^|[[:space:]])$1([[:space:]]|\$)" <<<"$MODULES"
}

no_packaged_modules() {
    # Valkey always reports a built-in lua module, so this asserts the absence
    # of the five packaged ones rather than an empty list.
    ! grep -qE '(^|[[:space:]])(json|bf|search|ldap|audit)([[:space:]]|$)' <<<"$MODULES"
}

if [ "$VARIANT" = "bundle" ]; then
    for module in json bf search ldap audit; do
        check "module ${module} is loaded" module_loaded "$module"
    done
else
    check "no packaged modules are loaded" no_packaged_modules
fi

###############################################################################
# Network exposure
###############################################################################

# Confirms the bind directive itself, independently of the security group.
LISTENERS="$(remote "ss -ltnH '( sport = :6379 )' | awk '{ print \$4 }'" || true)"

bound_to_loopback_only() {
    [ -n "$LISTENERS" ] || return 1
    ! grep -vqE '^(127\.0\.0\.1|\[::1\]):6379$' <<<"$LISTENERS"
}

check "valkey listens on loopback addresses only" bound_to_loopback_only

# Confirms the effective posture. This can also pass because the security group
# blocks the port, which is itself an acceptable outcome for the image.
port_closed() {
    ! timeout 5 bash -c "exec 3<>/dev/tcp/${PUBLIC_IP}/6379" 2>/dev/null
}

check "port 6379 is not reachable from outside the instance" port_closed

###############################################################################
# Build tooling
###############################################################################

# Removed after the bake-time suites run, so its absence can only be asserted
# against a launched instance.
no_build_tooling() {
    remote "test ! -e /opt/bats && ! rpm -q ansible-core >/dev/null 2>&1"
}

check "build tooling is absent from the published image" no_build_tooling

###############################################################################
# Reboot idempotence
###############################################################################

BOOT_ID_BEFORE="$(remote "cat /proc/sys/kernel/random/boot_id")"

echo "Rebooting to confirm the generated password survives"
remote "sudo systemctl reboot" >/dev/null 2>&1 || true

rebooted() {
    local elapsed=0 current
    while [ "$elapsed" -lt 300 ]; do
        current="$(remote "cat /proc/sys/kernel/random/boot_id" 2>/dev/null || true)"
        if [ -n "$current" ] && [ "$current" != "$BOOT_ID_BEFORE" ]; then
            return 0
        fi
        sleep 5
        elapsed=$(( elapsed + 5 ))
    done
    return 1
}

if check "the instance came back after reboot" rebooted; then
    PASSWORD_AFTER="$(remote "sudo grep '^requirepass ' /etc/valkey/valkey-generated.conf | cut -d' ' -f2")"
    check "the password is unchanged after reboot" test "$PASSWORD" = "$PASSWORD_AFTER"

    STATE_AFTER="$(remote "systemctl is-active valkey@default.service" || true)"
    check "the service is running after reboot" test "$STATE_AFTER" = "active"

    PING_AFTER="$(remote "valkey-cli -a '${PASSWORD}' --no-auth-warning PING" || true)"
    check "the server answers PING after reboot" test "$PING_AFTER" = "PONG"
fi

###############################################################################

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "${FAILURES} check(s) failed"
    exit 1
fi
echo "all checks passed"
