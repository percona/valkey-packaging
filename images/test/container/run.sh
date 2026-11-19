#!/bin/bash
set -euo pipefail

# Applies the image playbook inside a systemd-enabled Amazon Linux 2023
# container. systemd is required because the roles enable units; without a
# running service manager those tasks would be skipped rather than verified.
#
# Usage: run.sh [variant]
#   RUN_BATS=1        also run the in-image bats suites
#   KEEP=1            leave the container running for inspection

VARIANT="${1:-slim}"
IMAGE="${CONTAINER_IMAGE:-amazonlinux:2023}"
CHANNEL="${VALKEY_REPO_CHANNEL:-release}"
VERSION="${VALKEY_VERSION:-9.2.0}"
RUN_BATS="${RUN_BATS:-0}"
KEEP="${KEEP:-0}"
BATS_VERSION="${BATS_VERSION:-1.11.0}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONTAINER="valkey-image-${VARIANT}-$$"
PREPARED_TAG="valkey-image-base:al2023"

cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "Container left running: $CONTAINER"
        return
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

prepare_image() {
    if docker image inspect "$PREPARED_TAG" >/dev/null 2>&1; then
        echo "$PREPARED_TAG"
        return
    fi

    local tmp="valkey-image-prep-$$"
    # Amazon Linux 2023 has no bats package, so it comes from the upstream
    # tarball at a pinned version. The Packer build installs it the same way.
    if ! docker run --name "$tmp" "$IMAGE" bash -c "
            set -euo pipefail
            dnf -y install systemd ansible-core findutils procps-ng shadow-utils tar gzip >/dev/null
            curl -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v${BATS_VERSION}.tar.gz \
                -o /tmp/bats.tar.gz
            tar -xzf /tmp/bats.tar.gz -C /tmp
            /tmp/bats-core-${BATS_VERSION}/install.sh /usr/local >/dev/null
            rm -rf /tmp/bats.tar.gz /tmp/bats-core-${BATS_VERSION}
        " >&2; then
        docker rm -f "$tmp" >/dev/null 2>&1 || true
        echo "failed to prepare the base image" >&2
        exit 1
    fi
    docker commit "$tmp" "$PREPARED_TAG" >/dev/null
    docker rm -f "$tmp" >/dev/null 2>&1 || true
    echo "$PREPARED_TAG"
}

BASE="$(prepare_image)"

docker run -d \
    --privileged \
    --name "$CONTAINER" \
    --tmpfs /run \
    --tmpfs /run/lock \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$WORKDIR":/images:ro \
    "$BASE" /sbin/init >/dev/null

elapsed=0
while [ "$elapsed" -lt 60 ]; do
    state="$(docker exec "$CONTAINER" systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
        running|degraded) break ;;
    esac
    sleep 1
    elapsed=$(( elapsed + 1 ))
done

if [ "$elapsed" -ge 60 ]; then
    echo "systemd did not become ready (last state: ${state:-unknown})" >&2
    exit 1
fi

docker exec "$CONTAINER" ansible-playbook \
    -i localhost, -c local /images/ansible/valkey-ami.yml \
    -e "valkey_variant=${VARIANT}" \
    -e "valkey_repo_channel=${CHANNEL}" \
    -e "valkey_version=${VERSION}"

if [ "$RUN_BATS" = "1" ]; then
    docker exec \
        -e "VALKEY_VARIANT=${VARIANT}" \
        -e "VALKEY_VERSION=${VERSION}" \
        "$CONTAINER" bash -c 'bats /images/test/bats/*.bats'
fi
