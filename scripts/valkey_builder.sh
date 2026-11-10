#!/usr/bin/env bash
#
# valkey_builder.sh — Build script for Valkey packages (RPM, DEB, source tarballs)
#

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly PRODUCT="valkey"
readonly PACKAGE_NAME="percona-valkey"
readonly DEFAULT_VERSION="9.2.0"
readonly DEFAULT_RELEASE="1"
readonly DEFAULT_BRANCH="9.2.0"
readonly DEFAULT_REPO="https://github.com/valkey-io/valkey.git"

# valkey-json module packaging (separate upstream source + version)
readonly JSON_PACKAGE_NAME="percona-valkey-json"
readonly DEFAULT_JSON_REPO="https://github.com/valkey-io/valkey-json.git"
readonly DEFAULT_JSON_VERSION="1.0.2"
# RapidJSON is vendored into the source tarball so the module builds offline
# (upstream CMake otherwise FetchContent-clones it from GitHub at build time).
readonly RAPIDJSON_REPO="https://github.com/Tencent/rapidjson.git"
readonly RAPIDJSON_COMMIT="ebd87cb468fb4cb060b37e579718c4a4125416c1"

# valkey-audit module packaging (C; separate upstream source + version).
# Upstream has no v1.0.0 tag yet, so the default ref is a pinned main commit;
# audit/debian/patches carries the fixes that ref still needs.
readonly AUDIT_PACKAGE_NAME="percona-valkey-audit"
readonly DEFAULT_AUDIT_REPO="https://github.com/percona/valkey-audit.git"
readonly DEFAULT_AUDIT_VERSION="1.0.0"
readonly DEFAULT_AUDIT_BRANCH="b5ebc556e5af076fe067bf53771dea236db1d2fb"

# valkey-bloom module packaging (Rust; separate upstream source + version)
readonly BLOOM_PACKAGE_NAME="percona-valkey-bloom"
readonly DEFAULT_BLOOM_REPO="https://github.com/valkey-io/valkey-bloom.git"
readonly DEFAULT_BLOOM_VERSION="1.0.1"

# valkey-search module packaging (C++20; deps gRPC/Protobuf/Abseil/ICU built
# from source at package-build time; separate upstream source + version)
readonly SEARCH_PACKAGE_NAME="percona-valkey-search"
readonly DEFAULT_SEARCH_REPO="https://github.com/valkey-io/valkey-search.git"
readonly DEFAULT_SEARCH_VERSION="1.2.0"

# valkey-bundle meta-package: depends on the server + every module, ships no
# payload of its own. No upstream source to compile — the "source" is a small
# tarball (README + LICENSE) assembled from this repo's bundle/ dir.
readonly BUNDLE_PACKAGE_NAME="percona-valkey-bundle"
readonly DEFAULT_BUNDLE_VERSION="9.2.0"

# valkey-admin packaging (Node.js administration server; separate upstream
# source + version). Unlike the module packages above this is not a Valkey
# module but a standalone server, so its package name and its source name
# differ -- see valkey-admin/README.packaging.md.
readonly ADMIN_PACKAGE_NAME="percona-valkey-admin"
# The source tarball basename and its top-level directory. This must stay in
# step with rpm/percona-valkey-admin.spec's "%global srcname" and its
# "%autosetup -n %{srcname}-%{version}", which is what unpacks Source0.
readonly ADMIN_SRC_NAME="valkey-admin"
readonly DEFAULT_ADMIN_REPO="https://github.com/valkey-io/valkey-admin.git"
readonly DEFAULT_ADMIN_VERSION="1.1.1"

# Absolute path to the directory containing this script
BUILDER_SCRIPT_DIR="$(dirname "$(readlink -e "${0}")")"
readonly BUILDER_SCRIPT_DIR

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# apt resilience — a transient mirror/CDN failure (e.g. "Connection reset by
# peer" from deb.debian.org) must never fail a build. harden_apt drops in a
# config with retries, generous timeouts and no HTTP pipelining (flaky Fastly
# nodes reset pipelined connections). apt_get wraps the WHOLE command in an
# outer retry loop: apt's own Acquire::Retries handles per-file blips, and when
# those exhaust, the loop refreshes indexes and retries (a fresh attempt may
# route to a healthy node; already-fetched .debs stay cached in the archive so
# re-runs are cheap). Use apt_get for every apt-get update/install.
# ---------------------------------------------------------------------------
harden_apt() {
    [[ -d /etc/apt ]] || return 0
    mkdir -p /etc/apt/apt.conf.d
    cat > /etc/apt/apt.conf.d/80-retries <<'EOF'
Acquire::Retries "5";
Acquire::Retries::Delay "true";
Acquire::http::Timeout "120";
Acquire::https::Timeout "120";
Acquire::http::Pipeline-Depth "0";
EOF
}

apt_get() {
    harden_apt
    local attempt rc
    for attempt in 1 2 3 4 5; do
        if DEBIAN_FRONTEND=noninteractive command apt-get "$@"; then
            return 0
        fi
        rc=$?
        log_warn "apt-get $* failed (attempt ${attempt}/5, rc=${rc}); refreshing indexes before retry"
        DEBIAN_FRONTEND=noninteractive command apt-get update -y >/dev/null 2>&1 || true
        sleep $(( attempt * 10 ))
    done
    log_error "apt-get $* failed after 5 attempts"
    return 1
}

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        log_error "Script exited with code $rc"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]
    The following options may be given:
        --builddir=DIR                  Absolute path to the dir where all actions will be performed
        --get_sources                   Source will be downloaded from github
        --build_src_rpm                 If it is set - src rpm will be built
        --build_src_deb                 If it is set - source deb package will be built
        --build_rpm                     If it is set - rpm will be built
        --build_deb                     If it is set - deb will be built
        --install_deps                  Install build dependencies (root privileges are required)
        --branch=BRANCH                 Branch for build (default: ${DEFAULT_BRANCH})
        --repo=URL                      Repo for build (default: ${DEFAULT_REPO})
        --version=VER                   Version string (default: ${DEFAULT_VERSION})
        --release=REL                   Release number (default: ${DEFAULT_RELEASE})
        --use_local_packaging_script    Use local packaging scripts (located in ${BUILDER_SCRIPT_DIR}/../{debian,rpm})
        --json_deps                     Install valkey-json build deps (Percona repo, percona-valkey-dev(el), cmake, g++)
        --get_json_sources              Fetch valkey-json + vendor RapidJSON into an offline tarball
        --build_json_src_rpm            Build the percona-valkey-json source RPM
        --build_json_rpm                Build the percona-valkey-json binary RPM
        --build_json_src_deb            Build the percona-valkey-json source DEB
        --build_json_deb                Build the percona-valkey-json binary DEB
        --json_version=VER              valkey-json version (default: ${DEFAULT_JSON_VERSION})
        --json_branch=REF               valkey-json git ref (default: same as --json_version)
        --json_repo=URL                 valkey-json source repo (default: ${DEFAULT_JSON_REPO})
        --audit_deps                    Install valkey-audit build deps (Percona repo, percona-valkey-dev(el), cmake, gcc)
        --get_audit_sources             Fetch valkey-audit into a source tarball
        --build_audit_src_rpm           Build the percona-valkey-audit source RPM
        --build_audit_rpm               Build the percona-valkey-audit binary RPM
        --build_audit_src_deb           Build the percona-valkey-audit source DEB
        --build_audit_deb               Build the percona-valkey-audit binary DEB
        --audit_version=VER             valkey-audit version (default: ${DEFAULT_AUDIT_VERSION})
        --audit_branch=REF              valkey-audit git ref: branch, tag or commit (default: ${DEFAULT_AUDIT_BRANCH})
        --audit_repo=URL                valkey-audit source repo (default: ${DEFAULT_AUDIT_REPO})
        --bloom_deps                    Install valkey-bloom build deps (rustup, clang, build tools)
        --get_bloom_sources             Fetch valkey-bloom + vendor cargo deps into an offline tarball
        --build_bloom_src_rpm           Build the percona-valkey-bloom source RPM
        --build_bloom_rpm               Build the percona-valkey-bloom binary RPM
        --build_bloom_src_deb           Build the percona-valkey-bloom source DEB
        --build_bloom_deb               Build the percona-valkey-bloom binary DEB
        --bloom_version=VER             valkey-bloom version (default: ${DEFAULT_BLOOM_VERSION})
        --bloom_branch=REF              valkey-bloom git ref (default: same as --bloom_version)
        --bloom_repo=URL                valkey-bloom source repo (default: ${DEFAULT_BLOOM_REPO})
        --search_deps                   Install valkey-search build deps (g++>=12 toolchain, cmake, make, ...)
        --get_search_sources            Fetch valkey-search into a source tarball
        --build_search_src_rpm          Build the percona-valkey-search source RPM
        --build_search_rpm              Build the percona-valkey-search binary RPM
        --build_search_src_deb          Build the percona-valkey-search source DEB
        --build_search_deb              Build the percona-valkey-search binary DEB
        --search_version=VER            valkey-search version (default: ${DEFAULT_SEARCH_VERSION})
        --search_branch=REF             valkey-search git ref (default: same as --search_version)
        --bundle_deps                   Install valkey-bundle packaging tools (rpm-build / debhelper)
        --get_bundle_sources            Assemble the percona-valkey-bundle meta-package source tarball
        --build_bundle_src_rpm          Build the percona-valkey-bundle source RPM
        --build_bundle_rpm              Build the percona-valkey-bundle binary RPM (per-arch meta)
        --build_bundle_src_deb          Build the percona-valkey-bundle source DEB
        --build_bundle_deb              Build the percona-valkey-bundle binary DEB (per-arch meta)
        --bundle_version=VER            valkey-bundle version (default: ${DEFAULT_BUNDLE_VERSION})
        --search_repo=URL               valkey-search source repo (default: ${DEFAULT_SEARCH_REPO})
        --admin_deps                    Install valkey-admin build deps (Node.js >= 20 + npm, packaging tools)
        --get_admin_sources             Fetch valkey-admin into a source tarball
        --build_admin_src_rpm           Build the percona-valkey-admin source RPM
        --build_admin_rpm               Build the percona-valkey-admin binary RPM
        --build_admin_src_deb           Build the percona-valkey-admin source DEB
        --build_admin_deb               Build the percona-valkey-admin binary DEB
        --admin_version=VER             valkey-admin version (default: ${DEFAULT_ADMIN_VERSION})
        --admin_branch=REF              valkey-admin git ref (default: v<admin_version>)
        --admin_repo=URL                valkey-admin source repo (default: ${DEFAULT_ADMIN_REPO})
        --help                          Print usage
Example: $0 --builddir=/tmp/BUILD --get_sources --build_src_rpm --build_rpm
         $0 --builddir=/tmp/BUILD --get_json_sources --build_json_src_deb --build_json_deb
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_arguments() {
    for arg in "$@"; do
        case "$arg" in
            --builddir=*)                WORKDIR="${arg#*=}" ;;
            --build_src_rpm=*|--build_src_rpm) SRPM=1 ;;
            --build_src_deb=*|--build_src_deb) SDEB=1 ;;
            --build_rpm=*|--build_rpm)   RPM=1 ;;
            --build_deb=*|--build_deb)   DEB=1 ;;
            --get_sources=*|--get_sources) SOURCE=1 ;;
            --branch=*)                  BRANCH="${arg#*=}" ;;
            --repo=*)                    REPO="${arg#*=}" ;;
            --version=*)                 VERSION="${arg#*=}" ;;
            --release=*)                 RELEASE="${arg#*=}" ;;
            --install_deps=*|--install_deps) INSTALL=1 ;;
            --use_local_packaging_script=*|--use_local_packaging_script) LOCAL_BUILD=1 ;;
            --json_deps=*|--json_deps)   JSON_DEPS=1 ;;
            --get_json_sources=*|--get_json_sources) JSON_SOURCE=1 ;;
            --build_json_src_rpm=*|--build_json_src_rpm) JSON_SRPM=1 ;;
            --build_json_rpm=*|--build_json_rpm)     JSON_RPM=1 ;;
            --build_json_src_deb=*|--build_json_src_deb) JSON_SDEB=1 ;;
            --build_json_deb=*|--build_json_deb)     JSON_DEB=1 ;;
            --json_version=*)            JSON_VERSION="${arg#*=}" ;;
            --json_branch=*)             JSON_BRANCH="${arg#*=}" ;;
            --json_repo=*)               JSON_REPO="${arg#*=}" ;;
            --audit_deps=*|--audit_deps) AUDIT_DEPS=1 ;;
            --get_audit_sources=*|--get_audit_sources) AUDIT_SOURCE=1 ;;
            --build_audit_src_rpm=*|--build_audit_src_rpm) AUDIT_SRPM=1 ;;
            --build_audit_rpm=*|--build_audit_rpm)   AUDIT_RPM=1 ;;
            --build_audit_src_deb=*|--build_audit_src_deb) AUDIT_SDEB=1 ;;
            --build_audit_deb=*|--build_audit_deb)   AUDIT_DEB=1 ;;
            --audit_version=*)           AUDIT_VERSION="${arg#*=}" ;;
            --audit_branch=*)            AUDIT_BRANCH="${arg#*=}" ;;
            --audit_repo=*)              AUDIT_REPO="${arg#*=}" ;;
            --bloom_deps=*|--bloom_deps) BLOOM_DEPS=1 ;;
            --get_bloom_sources=*|--get_bloom_sources) BLOOM_SOURCE=1 ;;
            --build_bloom_src_rpm=*|--build_bloom_src_rpm) BLOOM_SRPM=1 ;;
            --build_bloom_rpm=*|--build_bloom_rpm)   BLOOM_RPM=1 ;;
            --build_bloom_src_deb=*|--build_bloom_src_deb) BLOOM_SDEB=1 ;;
            --build_bloom_deb=*|--build_bloom_deb)   BLOOM_DEB=1 ;;
            --bloom_version=*)           BLOOM_VERSION="${arg#*=}" ;;
            --bloom_branch=*)            BLOOM_BRANCH="${arg#*=}" ;;
            --bloom_repo=*)              BLOOM_REPO="${arg#*=}" ;;
            --search_deps=*|--search_deps) SEARCH_DEPS=1 ;;
            --get_search_sources=*|--get_search_sources) SEARCH_SOURCE=1 ;;
            --build_search_src_rpm=*|--build_search_src_rpm) SEARCH_SRPM=1 ;;
            --build_search_rpm=*|--build_search_rpm) SEARCH_RPM=1 ;;
            --build_search_src_deb=*|--build_search_src_deb) SEARCH_SDEB=1 ;;
            --build_search_deb=*|--build_search_deb) SEARCH_DEB=1 ;;
            --search_version=*)          SEARCH_VERSION="${arg#*=}" ;;
            --search_branch=*)           SEARCH_BRANCH="${arg#*=}" ;;
            --search_repo=*)             SEARCH_REPO="${arg#*=}" ;;
            --bundle_deps=*|--bundle_deps) BUNDLE_DEPS=1 ;;
            --get_bundle_sources=*|--get_bundle_sources) BUNDLE_SOURCE=1 ;;
            --build_bundle_src_rpm=*|--build_bundle_src_rpm) BUNDLE_SRPM=1 ;;
            --build_bundle_rpm=*|--build_bundle_rpm) BUNDLE_RPM=1 ;;
            --build_bundle_src_deb=*|--build_bundle_src_deb) BUNDLE_SDEB=1 ;;
            --build_bundle_deb=*|--build_bundle_deb) BUNDLE_DEB=1 ;;
            --bundle_version=*)          BUNDLE_VERSION="${arg#*=}" ;;
            --admin_deps=*|--admin_deps) ADMIN_DEPS=1 ;;
            --get_admin_sources=*|--get_admin_sources) ADMIN_SOURCE=1 ;;
            --build_admin_src_rpm=*|--build_admin_src_rpm) ADMIN_SRPM=1 ;;
            --build_admin_rpm=*|--build_admin_rpm)   ADMIN_RPM=1 ;;
            --build_admin_src_deb=*|--build_admin_src_deb) ADMIN_SDEB=1 ;;
            --build_admin_deb=*|--build_admin_deb)   ADMIN_DEB=1 ;;
            --admin_version=*)           ADMIN_VERSION="${arg#*=}" ;;
            --admin_branch=*)            ADMIN_BRANCH="${arg#*=}" ;;
            --admin_repo=*)              ADMIN_REPO="${arg#*=}" ;;
            --help)                      usage ;;
            *)                           die "Unknown option: $arg" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# find_and_copy_artifact SEARCH_SUBDIR GLOB_PATTERN
#   Looks for an artifact matching GLOB_PATTERN in $WORKDIR/SEARCH_SUBDIR first,
#   then falls back to $CURDIR/SEARCH_SUBDIR.  Copies the newest match into $WORKDIR.
#   Sets the variable FOUND_FILE to the basename of the found file.
find_and_copy_artifact() {
    local search_subdir="$1"
    local glob_pattern="$2"
    local found

    found="$(find "$WORKDIR/$search_subdir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$found" ]]; then
        FOUND_FILE="$(basename "$found")"
        cp "$found" "$WORKDIR/$FOUND_FILE"
        return 0
    fi

    found="$(find "$CURDIR/$search_subdir" -name "$glob_pattern" 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$found" ]]; then
        FOUND_FILE="$(basename "$found")"
        cp "$found" "$WORKDIR/$FOUND_FILE"
        return 0
    fi

    log_error "No artifact matching '$glob_pattern' found in $search_subdir"
    return 1
}

# copy_artifacts DEST_SUBDIR FILE...
#   Copies the given files into both $WORKDIR/DEST_SUBDIR and $CURDIR/DEST_SUBDIR.
#   Glob expansion happens at the call site, so pass unquoted globs as arguments.
copy_artifacts() {
    local dest_subdir="$1"
    shift

    mkdir -p "$WORKDIR/$dest_subdir"
    mkdir -p "$CURDIR/$dest_subdir"
    cp "$@" "$WORKDIR/$dest_subdir/"
    cp "$@" "$CURDIR/$dest_subdir/"
}

deb_apply_codename() {
    local codename
    codename="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
    [ -z "$codename" ] && codename="$(lsb_release -cs 2>/dev/null || true)"
    # Fail loudly rather than silently shipping a no-codename DEB that the repo
    # upload then routes to a bogus apt distribution.
    [ -n "$codename" ] || die "Could not determine distro codename for DEB version stamping"
    [ -f debian/changelog ] || die "debian/changelog not found for codename stamping"
    # Append .<codename> to the top entry's version and set its distribution to
    # the codename. dpkg-buildpackage stamps that version, so the .deb filename
    # becomes <pkg>_<version>.<codename>_<arch>.deb. Uses only sed (no devscripts).
    sed -i "1s/^\([^ ]*\) (\([^)]*\)) [^;]*;/\1 (\2.${codename}) ${codename};/" debian/changelog
    # Verify the stamp took (catches any future changelog-format drift early).
    head -1 debian/changelog | grep -q "(.*\.${codename}) ${codename};" \
        || die "Failed to stamp codename '${codename}' into the DEB version (changelog format changed?)"
}

# ---------------------------------------------------------------------------
# SBOM generation (Syft)
# ---------------------------------------------------------------------------
SYFT_BIN=""

# Pin Syft so the installer downloads the release directly instead of doing the
# rate-limited GitHub "latest release" API lookup: parallel matrix builds share
# one CI egress IP and exhaust the 60 req/h unauthenticated limit, which made the
# install fail silently. Override with SYFT_VERSION=vX.Y.Z.
SYFT_VERSION="${SYFT_VERSION:-v1.49.0}"

# _syft_install BINDIR — download Syft into BINDIR, pinned to $SYFT_VERSION, with
# retries for transient network. Returns 0 iff BINDIR/syft ends up executable.
# Installer output is left visible (not sent to /dev/null) so a real failure is
# diagnosable here instead of surfacing later as a confusing SBOM abort.
_syft_install() {
    local bindir="$1" i
    mkdir -p "$bindir"
    command -v curl &>/dev/null || command -v wget &>/dev/null || return 1
    for i in 1 2 3; do
        if command -v curl &>/dev/null; then
            curl -sSfL https://get.anchore.io/syft | sh -s -- -b "$bindir" "$SYFT_VERSION" || true
        else
            wget -qO- https://get.anchore.io/syft | sh -s -- -b "$bindir" "$SYFT_VERSION" || true
        fi
        [[ -x "${bindir}/syft" ]] && return 0
        log_warn "Syft install attempt ${i}/3 failed; retrying in $((i * 5))s..."
        sleep $((i * 5))
    done
    return 1
}

# install_syft — make Syft available, preferring an already-installed binary
# and otherwise downloading it into $WORKDIR/.sbom-tools/bin. Non-fatal: on
# failure it logs a warning and leaves SYFT_BIN empty so the package build is
# not aborted just because an SBOM could not be produced.
install_syft() {
    if [[ -n "$SYFT_BIN" && -x "$SYFT_BIN" ]]; then
        return 0
    fi
    if command -v syft &>/dev/null; then
        SYFT_BIN="$(command -v syft)"
        return 0
    fi

    log_info "Installing Syft ${SYFT_VERSION} for SBOM generation..."
    local bindir="${WORKDIR}/.sbom-tools/bin"
    if _syft_install "$bindir"; then
        SYFT_BIN="${bindir}/syft"
    else
        log_warn "Could not install Syft; SBOM will not be generated"
        SYFT_BIN=""
    fi
}

# ensure_syft_system — install Syft into /usr/local/bin so it is on PATH for the
# module spec/rules, which generate the package's SBOM from the *built* tree at
# package-build time. Called from install_deps_* (root, same container as the
# build). Idempotent; pinned + retried via _syft_install.
ensure_syft_system() {
    command -v syft &>/dev/null && return 0
    log_info "Installing Syft ${SYFT_VERSION} (system-wide) for in-package SBOM generation..."
    _syft_install /usr/local/bin || true
    command -v syft &>/dev/null || log_warn "Syft not installed; the package SBOM step will fail loudly at build time"
}

# generate_sbom_files SCAN_DIR OUT_SPDX OUT_CDX
#   Generate SPDX-JSON and CycloneDX-JSON SBOMs for SCAN_DIR, excluding the
#   packaging and VCS directories so the inventory reflects upstream Valkey
#   components (including the vendored deps). Best-effort: if Syft is
#   unavailable or fails, writes minimal placeholder documents so downstream
#   packaging always finds the files and the build does not abort.
generate_sbom_files() {
    local scan_dir="$1"
    local out_spdx="$2"
    local out_cdx="$3"

    install_syft
    if [[ -n "$SYFT_BIN" ]]; then
        log_info "Generating SBOM (SPDX + CycloneDX) from ${scan_dir} ..."
        if "$SYFT_BIN" scan "dir:${scan_dir}" \
            --source-name "$PACKAGE_NAME" --source-version "$VERSION" \
            --exclude './debian' --exclude './rpm' --exclude './.git' \
            -o "spdx-json=${out_spdx}" \
            -o "cyclonedx-json=${out_cdx}"; then
            return 0
        fi
        log_warn "Syft scan failed; writing placeholder SBOMs"
    else
        log_warn "Syft unavailable; writing placeholder SBOMs"
    fi

    printf '{"spdxVersion":"SPDX-2.3","SPDXID":"SPDXRef-DOCUMENT","name":"%s-%s","packages":[]}\n' \
        "$PACKAGE_NAME" "$VERSION" > "$out_spdx"
    printf '{"bomFormat":"CycloneDX","specVersion":"1.5","metadata":{"component":{"name":"%s","version":"%s","type":"application"}},"components":[]}\n' \
        "$PACKAGE_NAME" "$VERSION" > "$out_cdx"
}

# ---------------------------------------------------------------------------
# check_workdir
# ---------------------------------------------------------------------------
check_workdir() {
    if [[ -z "$WORKDIR" ]]; then
        die "--builddir is required"
    fi
    if [[ "$WORKDIR" == "$CURDIR" ]]; then
        die "Current directory cannot be used for building!"
    fi
    if [[ ! -d "$WORKDIR" ]]; then
        die "$WORKDIR is not a directory."
    fi
}

# ---------------------------------------------------------------------------
# get_sources
# ---------------------------------------------------------------------------
get_sources() {
    if [[ "$SOURCE" -eq 0 ]]; then
        log_info "Sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local product_full="${PRODUCT}-${VERSION}"

    cat > valkey.properties <<EOF
PRODUCT=${PRODUCT}
PRODUCT_FULL=${product_full}
VERSION=${VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
EOF

    log_info "Cloning $REPO ..."
    if ! git clone "$REPO" "$product_full"; then
        die "Failed to clone repo from $REPO. Please retry."
    fi

    cd "$product_full" || die "Cannot cd to $product_full"

    if [[ -n "$BRANCH" ]]; then
        git reset --hard
        git clean -xdf
        git checkout "$BRANCH"
    fi

    local revision
    revision="$(git rev-parse --short HEAD)"
    echo "REVISION=${revision}" >> "${WORKDIR}/valkey.properties"

    if [[ "$LOCAL_BUILD" -eq 0 ]]; then
        log_info "Downloading packaging scripts from github"
        git clone https://github.com/EvgeniyPatlan/valkey-packaging.git packaging

        local packaging_branch="${PACKAGING_BRANCH:-$VERSION}"
        if [[ -n "$packaging_branch" ]]; then
            cd packaging || die "Cannot cd to packaging"
            git reset --hard
            git clean -xdf
            if ! git checkout "$packaging_branch"; then
                log_warn "Packaging branch '$packaging_branch' not found; staying on default branch"
            fi
            cd ..
        fi

        mv packaging/debian ./
        mv packaging/rpm ./
    else
        log_info "Using local packaging scripts"
        cp -r "${BUILDER_SCRIPT_DIR}/../debian" ./
        cp -r "${BUILDER_SCRIPT_DIR}/../rpm" ./
    fi

    # Ship the SBOM generator in the tarball; the spec (%install) / debian rules
    # invoke it at package-build time to embed the full SBOM set (SPDX/CycloneDX
    # json+xml, Syft table, license manifest) under /usr/share/percona-valkey/sbom/
    # — the same 6-file set as every module (see gen-module-sbom.sh).
    cp "${BUILDER_SCRIPT_DIR}/gen-module-sbom.sh" "./gen-module-sbom.sh" \
        || die "gen-module-sbom.sh is missing"
    chmod +x "./gen-module-sbom.sh"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    tar --owner=0 --group=0 --exclude=.git -czf "${product_full}.tar.gz" "$product_full"

    echo "UPLOAD=UPLOAD/experimental/BUILDS/${PRODUCT}/${product_full}/${BRANCH}/${revision}/${BUILD_ID:-}" >> valkey.properties

    copy_artifacts "source_tarball" "${product_full}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_json_sources — fetch valkey-json, vendor RapidJSON, emit offline tarball
# ---------------------------------------------------------------------------
get_json_sources() {
    if [[ "$JSON_SOURCE" -eq 0 ]]; then
        log_info "valkey-json sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${JSON_PACKAGE_NAME}-${JSON_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-json ${JSON_BRANCH} from ${JSON_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${JSON_BRANCH}" "${JSON_REPO}" "${name}"; then
        die "Failed to clone valkey-json from ${JSON_REPO} (ref ${JSON_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log_info "Vendoring RapidJSON ${RAPIDJSON_COMMIT} ..."
    git clone "${RAPIDJSON_REPO}" "${srcdir}/deps/rapidjson" \
        || die "Failed to clone RapidJSON"
    ( cd "${srcdir}/deps/rapidjson" && git checkout -q "${RAPIDJSON_COMMIT}" ) \
        || die "Failed to check out RapidJSON ${RAPIDJSON_COMMIT}"

    log_info "Adding in-package README ..."
    cp "${BUILDER_SCRIPT_DIR}/../json/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "json/README.packaging.md is missing"
    # SBOM generator, invoked by the spec/rules at package-build time.
    cp "${BUILDER_SCRIPT_DIR}/gen-module-sbom.sh" "${srcdir}/gen-module-sbom.sh" \
        || die "gen-module-sbom.sh is missing"
    chmod +x "${srcdir}/gen-module-sbom.sh"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    # NOTE: the package SBOM is generated at PACKAGE-BUILD time by the module
    # spec (%install) / debian rules, so it reflects the actually-built tree
    # (incl. build-time deps like gRPC/ICU for search, vendored crates for
    # bloom). It is not produced here from the source tree.

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-json source tarball"

    # Properties file consumed by the Jenkins pipeline to derive the upload path
    # (mirrors the server's valkey.properties).
    cat > "${WORKDIR}/valkey-json.properties" <<EOF
PRODUCT=${JSON_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${JSON_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-json/${name}/${JSON_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_bloom_sources — fetch valkey-bloom, vendor cargo deps, emit offline tarball
# ---------------------------------------------------------------------------
get_bloom_sources() {
    if [[ "$BLOOM_SOURCE" -eq 0 ]]; then
        log_info "valkey-bloom sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BLOOM_PACKAGE_NAME}-${BLOOM_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-bloom ${BLOOM_BRANCH} from ${BLOOM_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${BLOOM_BRANCH}" "${BLOOM_REPO}" "${name}"; then
        die "Failed to clone valkey-bloom from ${BLOOM_REPO} (ref ${BLOOM_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    # Vendor all cargo dependencies into the source tree so the package builds
    # fully offline (the cargo analog of vendoring RapidJSON for json).
    log_info "Vendoring cargo dependencies ..."
    export RUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}" CARGO_HOME="${CARGO_HOME:-/usr/local/cargo}"
    ( cd "${srcdir}" \
        && cargo generate-lockfile \
        && mkdir -p .cargo \
        && cargo vendor vendor > .cargo/config.toml ) \
        || die "cargo vendor failed (run with --bloom_deps so the Rust toolchain is installed)"

    # cargo vendor records informational "*.orig" files (e.g. Cargo.toml.orig) in
    # each crate's .cargo-checksum.json. dpkg-source's 3.0 (quilt) handling can
    # drop those files, after which an offline cargo build fails with
    # "failed to open file vendor/<crate>/Cargo.toml.orig". Drop the files and
    # their checksum entries so the vendored tree stays self-consistent.
    python3 - "${srcdir}/vendor" <<'PY'
import json, glob, os, sys
vroot = sys.argv[1]
for cs in glob.glob(os.path.join(vroot, '*', '.cargo-checksum.json')):
    with open(cs) as fh:
        data = json.load(fh)
    files = data.get('files', {})
    for key in [k for k in files if k.endswith('.orig')]:
        files.pop(key, None)
        path = os.path.join(os.path.dirname(cs), key)
        if os.path.exists(path):
            os.remove(path)
    with open(cs, 'w') as fh:
        json.dump(data, fh)
PY

    log_info "Adding in-package README ..."
    cp "${BUILDER_SCRIPT_DIR}/../bloom/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "bloom/README.packaging.md is missing"
    # SBOM generator, invoked by the spec/rules at package-build time.
    cp "${BUILDER_SCRIPT_DIR}/gen-module-sbom.sh" "${srcdir}/gen-module-sbom.sh" \
        || die "gen-module-sbom.sh is missing"
    chmod +x "${srcdir}/gen-module-sbom.sh"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    # NOTE: the package SBOM is generated at PACKAGE-BUILD time by the module
    # spec (%install) / debian rules, so it reflects the actually-built tree
    # (incl. build-time deps like gRPC/ICU for search, vendored crates for
    # bloom). It is not produced here from the source tree.

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-bloom source tarball"

    # Properties file consumed by the Jenkins pipeline to derive the upload path.
    cat > "${WORKDIR}/valkey-bloom.properties" <<EOF
PRODUCT=${BLOOM_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${BLOOM_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-bloom/${name}/${BLOOM_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_search_sources — fetch valkey-search into a source tarball
#   No dependency vendoring: gRPC/Protobuf/Abseil/highwayhash are FetchContent-
#   built at package-build time, and ICU source is already in the repo tree.
# ---------------------------------------------------------------------------
get_search_sources() {
    if [[ "$SEARCH_SOURCE" -eq 0 ]]; then
        log_info "valkey-search sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${SEARCH_PACKAGE_NAME}-${SEARCH_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-search ${SEARCH_BRANCH} from ${SEARCH_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${SEARCH_BRANCH}" "${SEARCH_REPO}" "${name}"; then
        die "Failed to clone valkey-search from ${SEARCH_REPO} (ref ${SEARCH_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log_info "Adding in-package README ..."
    cp "${BUILDER_SCRIPT_DIR}/../search/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "search/README.packaging.md is missing"
    # SBOM generator, invoked by the spec/rules at package-build time.
    cp "${BUILDER_SCRIPT_DIR}/gen-module-sbom.sh" "${srcdir}/gen-module-sbom.sh" \
        || die "gen-module-sbom.sh is missing"
    chmod +x "${srcdir}/gen-module-sbom.sh"

    # Build-time source tweaks (done here so RPM and DEB build identically):
    #  1) Disable LTO. The release build links the module with -flto and compiles
    #     with -ffat-lto-objects; GCC 12 (the toolchain on Ubuntu jammy and other
    #     older-gcc distros) has an LTO bug — "multiple prevailing defs for
    #     '__ct_comp'" — that fails the link. The module is fine without LTO.
    #     This MUST also cover the vendored snowball stemmer, which otherwise keeps
    #     IPO + -fno-fat-lto-objects (slim, bytecode-only objects). Linking those
    #     into a -fno-lto module drops their machine code, so the module loads with
    #     "undefined symbol: sb_stemmer_length". Skip snowball's IPO block too.
    #  2) Remove the unit-test trees outright. They build test EXECUTABLES (not
    #     needed for packaging) that fail to link on some toolchains: gcc-toolset's
    #     static libstdc++ leaves std:: symbols undefined, and the top-level
    #     testing/ misses test-only link deps. -DBUILD_UNIT_TESTS=OFF (via build.sh
    #     or CMAKE_EXTRA_ARGS) did not reliably take effect, so instead comment out
    #     the add_subdirectory(testing) calls — flag-independent, nothing can re-add
    #     a removed subdir. The module is a shared lib (no --no-undefined) and links
    #     fine on its own. (testing_infra is a plain lib and is left untouched.)
    log_info "Patching valkey-search sources (disable LTO, remove unit tests) ..."
    local vs_cmake="${srcdir}/cmake/Modules/valkey_search.cmake"
    if [[ -f "$vs_cmake" ]]; then
        sed -i 's/-ffat-lto-objects/-fno-lto/g; s/ -flto)/ -fno-lto)/g' "$vs_cmake"
    else
        log_warn "valkey_search.cmake not found — LTO not disabled (upstream layout changed?)"
    fi
    # Snowball stemmer: skip its IPO/LTO block so it emits normal (machine-code)
    # objects that link into the -fno-lto module (else sb_stemmer_* is undefined).
    local snow_cmake="${srcdir}/third_party/snowball/CMakeLists.txt"
    if [[ -f "$snow_cmake" ]]; then
        sed -i 's/^\([[:space:]]*\)if(lto_supported)/\1if(FALSE) # IPO off: module links -fno-lto/' "$snow_cmake"
    fi
    local kill_tests='s/^\([[:space:]]*\)add_subdirectory(testing)/\1# add_subdirectory(testing) # disabled for packaging/'
    [[ -f "${srcdir}/CMakeLists.txt" ]]       && sed -i "$kill_tests" "${srcdir}/CMakeLists.txt"
    [[ -f "${srcdir}/vmsdk/CMakeLists.txt" ]] && sed -i "$kill_tests" "${srcdir}/vmsdk/CMakeLists.txt"
    # Belt-and-suspenders: also flip build.sh's hard-coded -DBUILD_UNIT_TESTS=ON.
    [[ -f "${srcdir}/build.sh" ]] && sed -i 's/-DBUILD_UNIT_TESTS=ON/-DBUILD_UNIT_TESTS=OFF/g' "${srcdir}/build.sh"

    # Fix a fatal module-load crash in valkey-search on Debian/Ubuntu (see below).
    local memov="${srcdir}/vmsdk/src/memory_allocation_overrides.cc"
    if [[ -f "$memov" ]]; then
        # Disable vmsdk's custom global operator new/delete override for this
        # build. That override routes C++ allocations through a ValkeyModule_Alloc
        # tracking allocator, whose bootstrap logic drives an invalid free() during
        # module load on the Debian/g++ + jemalloc toolchain — the server SIGABRTs
        # the instant libsearch.so is loaded (the RPM/gcc-toolset build happens to
        # survive). It is the FIRST thing exercised on load, so it also crashes the
        # bundle image (which auto-loads all modules). Upstream already gates these
        # operators behind '#ifndef SAN_BUILD' — i.e. sanitizer builds run with the
        # default operators — so this is a known-good configuration. The only cost
        # is that search's memory is not itemised in Valkey MEMORY STATS (exactly
        # like the json/bloom modules, which never override the allocator).
        sed -i '/^#ifndef SAN_BUILD$/{N;s|#ifndef SAN_BUILD\n\(void\* operator new(size_t size) noexcept(false) {\)|#if 0  // percona: disable custom operator new/delete (invalid free() crashes module load on Debian)\n\1|}' "$memov"
        grep -q 'percona: disable custom operator' "$memov" \
            || log_warn "operator-override guard not patched (upstream memory_allocation_overrides.cc changed?)"
    else
        log_warn "vmsdk/src/memory_allocation_overrides.cc not found — allocator-override fix not applied (upstream layout changed?)"
    fi

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    # NOTE: the package SBOM is generated at PACKAGE-BUILD time by the module
    # spec (%install) / debian rules, so it reflects the actually-built tree
    # (incl. build-time deps like gRPC/ICU for search, vendored crates for
    # bloom). It is not produced here from the source tree.

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-search source tarball"

    cat > "${WORKDIR}/valkey-search.properties" <<EOF
PRODUCT=${SEARCH_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${SEARCH_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-search/${name}/${SEARCH_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# get_system — detect OS family (rpm vs deb) and platform details
# ---------------------------------------------------------------------------
get_system() {
    ARCH="$(uname -m)"

    if [[ -f /etc/redhat-release ]]; then
        RHEL="$(rpm --eval %rhel)"
        OS_NAME="el${RHEL}"
        OS="rpm"

        # Detect specific RHEL-family distro for EPEL handling
        if [[ -f /etc/oracle-release ]]; then
            PLATFORM_FAMILY="oracle"
        elif [[ -f /etc/fedora-release ]]; then
            PLATFORM_FAMILY="fedora"
        else
            PLATFORM_FAMILY="rhel"
        fi
    elif [[ -f /etc/SuSE-release ]] || [[ -f /etc/SUSE-brand ]] || grep -qi suse /etc/os-release 2>/dev/null; then
        OS="rpm"
        OS_NAME="suse"
        RHEL="0"
        PLATFORM_FAMILY="suse"
    elif [[ -f /etc/system-release ]] && grep -qi "amazon" /etc/system-release 2>/dev/null; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel 2>/dev/null || echo 0)"
        OS_NAME="amzn2023"
        PLATFORM_FAMILY="amazon"
    elif command -v rpm &>/dev/null && ! command -v dpkg &>/dev/null; then
        OS="rpm"
        RHEL="$(rpm --eval %rhel 2>/dev/null || echo 0)"
        OS_NAME="rpm"
        PLATFORM_FAMILY="rhel"
    else
        OS_NAME="$(lsb_release -sc 2>/dev/null || echo unknown)"
        OS="deb"
        PLATFORM_FAMILY="deb"
    fi
}

# ---------------------------------------------------------------------------
# install_deps
# ---------------------------------------------------------------------------
install_deps() {
    if [[ "$INSTALL" -eq 0 ]]; then
        log_info "Dependencies will not be installed"
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        install_deps_rpm
    else
        install_deps_deb
    fi
}

install_deps_rpm() {
    # ── Determine package manager ──
    local pkg_mgr="yum"
    if command -v dnf &>/dev/null; then
        pkg_mgr="dnf"
    fi

    if [[ "$PLATFORM_FAMILY" == "suse" ]]; then
        # ── SUSE / openSUSE ──
        log_info "Installing SUSE build dependencies..."
        zypper refresh
        zypper install -y \
            rpm-build rpmdevtools gcc make wget tar gzip git \
            jemalloc-devel libopenssl-devel pkg-config \
            libzstd-devel-static \
            python3 tcl procps chrpath \
            systemd-devel systemd libsystemd0 \
            sysuser-shadow sysuser-tools

        # Documentation deps (optional on SUSE)
        zypper install -y pandoc python3-PyYAML 2>/dev/null \
            || log_warn "pandoc not available on this SUSE version — docs will be skipped"

    else
        # ── RHEL-family: install EPEL where needed ──
        case "$PLATFORM_FAMILY" in
            oracle)
                # Oracle Linux uses its own EPEL packages
                local epel_pkg="oracle-epel-release-el${RHEL}"
                if ! rpm -q "$epel_pkg" &>/dev/null; then
                    log_info "Installing EPEL for Oracle Linux: $epel_pkg"
                    $pkg_mgr install -y "$epel_pkg" \
                        || log_warn "EPEL installation failed (non-critical)"
                fi
                ;;
            rhel)
                # Rocky, Alma, CentOS, generic RHEL
                if ! rpm -q epel-release &>/dev/null; then
                    log_info "Installing EPEL repository..."
                    $pkg_mgr install -y epel-release \
                        || log_warn "EPEL installation failed (non-critical)"
                fi
                ;;
            fedora|amazon)
                # Fedora and Amazon Linux have jemalloc-devel in base repos
                log_info "Skipping EPEL (not needed for $PLATFORM_FAMILY)"
                ;;
        esac

        # ── Common RHEL-family packages ──
        log_info "Installing RPM build dependencies..."
        $pkg_mgr install -y \
            rpm-build rpmdevtools gcc make wget tar gzip git \
            jemalloc-devel openssl openssl-devel pkgconfig \
            python3 tcl procps-ng chrpath \
            systemd-devel systemd-rpm-macros

        # Static libzstd for BUILD_ZSTD (Valkey 9.2+). EL8/9/10 ship none —
        # not in BaseOS/AppStream, CRB/PowerTools or EPEL — so the spec builds
        # and bundles a pinned zstd there instead (its Source60).
        case "$PLATFORM_FAMILY" in
            fedora|amazon)
                $pkg_mgr install -y libzstd-static \
                    || die "libzstd-static is required for BUILD_ZSTD on $PLATFORM_FAMILY"
                ;;
        esac

        # Documentation deps (optional)
        $pkg_mgr install -y pandoc python3-pyyaml 2>/dev/null \
            || log_warn "pandoc not available — docs will be skipped"

        $pkg_mgr clean all
    fi
    ensure_syft_system
}

install_deps_deb() {
    log_info "Installing DEB build dependencies..."
    apt_get update

    # Core build toolchain
    apt_get -y install \
        build-essential debhelper devscripts dh-exec dpkg-dev \
        fakeroot ca-certificates lsb-release chrpath \
        git wget curl make gcc

    # Valkey build dependencies — try all at once, fall back to individual
    apt_get -y install \
        libjemalloc-dev libssl-dev libsystemd-dev \
        libzstd-dev \
        libhiredis-dev liblua5.1-dev liblzf-dev \
        lua-bitop-dev lua-cjson-dev \
        pkg-config pkgconf procps \
        tcl tcl-dev tcl-tls openssl \
        dh-python python3 python3-yaml \
        pandoc python3-sphinx python3-sphinx-rtd-theme \
    || {
        log_warn "Some packages not available, trying individually..."
        local -a fallback_pkgs=(
            libjemalloc-dev libssl-dev libsystemd-dev
            libzstd-dev
            libhiredis-dev liblua5.1-dev liblzf-dev
            lua-bitop-dev lua-cjson-dev
            pkg-config pkgconf procps
            tcl tcl-dev tcl-tls openssl
            dh-exec dh-python python3 python3-yaml
            pandoc python3-sphinx python3-sphinx-rtd-theme
        )
        for dep in "${fallback_pkgs[@]}"; do
            apt_get -y install "$dep" \
                || log_warn "$dep not available"
        done
    }

    # Use mk-build-deps as a safety net if available
    if command -v mk-build-deps &>/dev/null && [[ -f debian/control ]]; then
        log_info "Running mk-build-deps for any remaining dependencies..."
        mk-build-deps --install --remove \
            --tool="apt-get -o Debug::pkgProblemResolver=yes --no-install-recommends --yes" \
            debian/control || log_warn "mk-build-deps reported issues (non-critical)"
    fi
    ensure_syft_system
}

# ---------------------------------------------------------------------------
# install_deps_json — build deps for the valkey-json module.
#   The module compiles against the system valkeymodule.h shipped by
#   percona-valkey-dev(el), so this sets up the Percona repo (channel from
#   VALKEY_REPO_CHANNEL, default "testing") and installs that package plus the
#   C++ toolchain. Triggered by --json_deps.
# ---------------------------------------------------------------------------
install_deps_json() {
    if [[ "$JSON_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    local channel="${VALKEY_REPO_CHANNEL:-testing}"
    # Percona repo that ships the existing valkey packages (percona-valkey-devel).
    # For 9.1 the percona-release component is "valkey-91" (override if needed).
    local repo_name="${VALKEY_REPO_NAME:-valkey-91}"

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        $pkg_mgr -y install https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable-only "${repo_name}" "${channel}" || percona-release enable "${repo_name}" "${channel}"
        $pkg_mgr -y install \
            gcc-c++ cmake make git tar gzip rpm-build rpmdevtools \
            percona-valkey-devel
    else
        export DEBIAN_FRONTEND=noninteractive
        apt_get update
        apt_get -y install wget ca-certificates gnupg lsb-release
        wget -qO /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        dpkg -i /tmp/percona-release.deb || apt_get install -f -y
        percona-release enable-only "${repo_name}" "${channel}" || percona-release enable "${repo_name}" "${channel}"
        apt_get update
        apt_get -y install \
            debhelper devscripts dh-exec dpkg-dev fakeroot \
            cmake g++ make git \
            percona-valkey-dev
    fi
    ensure_syft_system
}

# ---------------------------------------------------------------------------
# install_deps_bloom — build deps for the valkey-bloom (Rust) module.
#   Installs clang (libclang for the valkey-module crate's bindgen), the
#   packaging tools, and the Rust toolchain via rustup into system locations
#   so cargo is on PATH for rpmbuild/debuild. No valkey header is required.
#   Triggered by --bloom_deps.
# ---------------------------------------------------------------------------
install_deps_bloom() {
    if [[ "$BLOOM_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        # Do NOT install the full 'curl' package: Amazon Linux 2023 ships
        # curl-minimal (which already provides the curl command), and
        # 'dnf install curl' fails with an unresolvable conflict against it.
        # curl/curl-minimal is present on all RPM targets, so rely on it.
        $pkg_mgr -y install \
            gcc gcc-c++ make git tar gzip ca-certificates pkgconfig python3 \
            clang clang-devel rpm-build rpmdevtools \
        || $pkg_mgr -y install \
            gcc gcc-c++ make git tar gzip ca-certificates pkgconfig python3 \
            clang rpm-build rpmdevtools
        # Safety net only if no curl command exists at all (rustup needs it):
        # use --allowerasing so it can replace curl-minimal where applicable.
        command -v curl >/dev/null 2>&1 || $pkg_mgr -y install --allowerasing curl || true
    else
        export DEBIAN_FRONTEND=noninteractive
        apt_get update
        apt_get -y install \
            build-essential debhelper devscripts dh-exec dpkg-dev fakeroot \
            git curl ca-certificates wget pkg-config python3 \
            clang libclang-dev
    fi

    # Rust toolchain via rustup, installed system-wide so the rustup proxies
    # (cargo/rustc) resolve the toolchain via RUSTUP_HOME for any build user.
    export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo
    if [[ ! -x /usr/local/cargo/bin/cargo ]]; then
        curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
    fi
    ln -sf /usr/local/cargo/bin/cargo  /usr/local/bin/cargo
    ln -sf /usr/local/cargo/bin/rustc  /usr/local/bin/rustc
    ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup
    RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo cargo --version \
        || die "cargo not available after rustup install"
    ensure_syft_system
}

# ---------------------------------------------------------------------------
# install_deps_search — build deps for the valkey-search (C++20) module.
#   Needs cmake + make, autotools (ICU), openssl/systemd headers, git (the build
#   FetchContent-clones gRPC/Protobuf/Abseil), and a C++20 compiler (g++ >= 12):
#   gcc-toolset on RHEL, g++-12 on Debian/Ubuntu. The build uses the Unix
#   Makefiles generator, so ninja-build is not required. Triggered by --search_deps.
# ---------------------------------------------------------------------------
install_deps_search() {
    if [[ "$SEARCH_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        # Core build tools — all in base/AppStream on every RPM target. The build
        # uses the Unix Makefiles generator (make), so ninja-build (EPEL-only on
        # RHEL, not reliably available) is NOT needed.
        $pkg_mgr -y install \
            gcc gcc-c++ make git tar gzip autoconf automake libtool \
            openssl-devel systemd-devel pkgconfig rpm-build rpmdevtools cmake
        # C++20 toolchain (g++ >= 12) — provided differently per distro; %build
        # picks it up. Amazon Linux 2023 has no gcc-toolset but ships gcc14
        # (binaries named gcc14-g++/gcc14-gcc); RHEL 8/9 use gcc-toolset; OL10 /
        # Fedora already default to gcc >= 12.
        if [[ "$PLATFORM_FAMILY" == "amazon" ]]; then
            $pkg_mgr -y install gcc14 gcc14-c++ || true
        else
            $pkg_mgr -y install gcc-toolset-13 \
                || $pkg_mgr -y install gcc-toolset-14 \
                || $pkg_mgr -y install gcc-toolset-12 \
                || true
        fi
    else
        export DEBIAN_FRONTEND=noninteractive
        apt_get update
        apt_get -y install \
            build-essential debhelper devscripts dh-exec dpkg-dev fakeroot \
            cmake make git autoconf automake libtool pkg-config \
            libssl-dev libsystemd-dev ca-certificates
        # Prefer g++-12 where the default is older (e.g. Ubuntu jammy); best-effort.
        apt_get -y install g++-12 gcc-12 || true
    fi
    ensure_syft_system
}

# ---------------------------------------------------------------------------
# build_srpm
# ---------------------------------------------------------------------------
build_srpm() {
    if [[ "$SRPM" -eq 0 ]]; then
        log_info "SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "valkey*.tar.gz"
    local tarfile="$FOUND_FILE"

    # Clean up everything except the tarball
    rm -fr rpmbuild
    find "$WORKDIR" -maxdepth 1 -mindepth 1 \
        ! -name "*.tar.gz" ! -name "source_tarball" ! -name "srpm" \
        ! -name "valkey.properties" \
        -exec rm -rf {} + 2>/dev/null || true

    mkdir -vp rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    tar vxzf "${WORKDIR}/${tarfile}" --wildcards '*/rpm' --strip=1

    cp -av rpm/* rpmbuild/SOURCES
    cp -av rpm/${PACKAGE_NAME}.spec rpmbuild/SPECS

    mv -fv "$tarfile" "${WORKDIR}/rpmbuild/SOURCES"

    sed -i 's:.rhel7:%{dist}:' "${WORKDIR}/rpmbuild/SPECS/${PACKAGE_NAME}.spec"
    sed -i "s/^Version:.*$/Version:        ${VERSION}/" "${WORKDIR}/rpmbuild/SPECS/${PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" "${WORKDIR}/rpmbuild/SPECS/${PACKAGE_NAME}.spec"

    # Valkey 9.2+ on EL bundles a pinned zstd, because EL ships no static
    # libzstd. The spec only declares that Source on the distros that need it,
    # so ask the spec rather than guessing, and fetch it before "rpmbuild -bs"
    # -- which refuses to build an SRPM with a missing Source. The binary build
    # rebuilds this SRPM, so the tarball travels inside it.
    local zstd_url
    local spec_expanded
    spec_expanded="$(rpmspec -P "rpmbuild/SPECS/${PACKAGE_NAME}.spec" 2>/dev/null || true)"
    # Collect in END rather than exiting early: an awk that exits first closes
    # the pipe, rpmspec dies of SIGPIPE, and pipefail turns that into 141.
    zstd_url="$(printf '%s\n' "$spec_expanded" \
        | awk '/^Source60:/{u=$2} END{if (u != "") print u}')"
    if [[ -n "$zstd_url" ]]; then
        local zstd_tar="${zstd_url##*/}"
        if [[ ! -f "rpmbuild/SOURCES/${zstd_tar}" ]]; then
            log_info "Fetching bundled zstd: ${zstd_url}"
            wget -q -O "rpmbuild/SOURCES/${zstd_tar}" "$zstd_url" \
                || die "Failed to download bundled zstd from ${zstd_url}"
        fi
    fi

    rpmbuild -bs --define "_topdir ${WORKDIR}/rpmbuild" --define "dist .generic" \
        --define "version ${VERSION}" rpmbuild/SPECS/${PACKAGE_NAME}.spec

    copy_artifacts "srpm" rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_rpm
# ---------------------------------------------------------------------------
build_rpm() {
    if [[ "$RPM" -eq 0 ]]; then
        log_info "RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr rb
    mkdir -vp rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" rb/SRPMS/

    RHEL="$(rpm --eval %rhel)"
    ARCH="$(uname -m | sed -e 's:i686:i386:g')"

    rpmbuild --define "_topdir ${WORKDIR}/rb" --define "dist .${OS_NAME}" \
        --define "version ${VERSION}" --rebuild "rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_json_srpm — source RPM for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_srpm() {
    if [[ "$JSON_SRPM" -eq 0 ]]; then
        log_info "valkey-json SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${JSON_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr json_rpmbuild
    mkdir -vp json_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../json/rpm/${JSON_PACKAGE_NAME}.spec" json_rpmbuild/SPECS/
    # Spec patches are kept in json/debian/patches (single source of truth, shared
    # with the DEB quilt series); copy them next to the tarball for rpmbuild.
    cp -av "${BUILDER_SCRIPT_DIR}/../json/debian/patches/"*.patch json_rpmbuild/SOURCES/
    mv -fv "$tarfile" json_rpmbuild/SOURCES/

    # Allow --json_version to flow through to the package version.
    sed -i "s/^Version:.*$/Version:        ${JSON_VERSION}/" \
        "json_rpmbuild/SPECS/${JSON_PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" \
        "json_rpmbuild/SPECS/${JSON_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/json_rpmbuild" --define "dist .generic" \
        "json_rpmbuild/SPECS/${JSON_PACKAGE_NAME}.spec"

    # SRPMs go to the shared srpm/ dir (same as the server build and what the
    # Jenkins pipeline pushes/pops). build_<module>_rpm finds its own by a
    # module-specific glob, and the server build_rpm runs before any module
    # SRPM exists, so there is no cross-pickup.
    copy_artifacts "srpm" json_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_json_rpm — binary RPM for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_rpm() {
    if [[ "$JSON_RPM" -eq 0 ]]; then
        log_info "valkey-json RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${JSON_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr json_rb
    mkdir -vp json_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" json_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/json_rb" --define "dist .${OS_NAME}" \
        --rebuild "json_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" json_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_source_deb
# ---------------------------------------------------------------------------
build_source_deb() {
    if [[ "$SDEB" -eq 0 ]]; then
        log_info "Source deb package will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    # Clean previous build artifacts but preserve valkey.properties and source_tarball/
    rm -rf "${PRODUCT}-"* "${PACKAGE_NAME}-"* "${PACKAGE_NAME}_"*
    rm -f ./*.dsc ./*.orig.tar.gz ./*.changes ./*.debian.tar.* ./*.diff.*

    find_and_copy_artifact "source_tarball" "valkey*.tar.gz"
    local tarfile="$FOUND_FILE"

    local debian_codename
    debian_codename="$(lsb_release -sc)"
    ARCH="$(uname -m | sed -e 's:i686:i386:g')"

    tar zxf "$tarfile"
    mv "${PRODUCT}-${VERSION}" "${PACKAGE_NAME}-${VERSION}"
    local builddir="${PACKAGE_NAME}-${VERSION}"

    # Repack orig tarball with the correct top-level directory name;
    # dpkg-source expects the orig tarball directory to match the source package name.
    tar czf "${PACKAGE_NAME}_${VERSION}.orig.tar.gz" "$builddir"
    rm -f "$tarfile"

    cd "$builddir" || die "Cannot cd to $builddir"

    # Regenerate the debian changelog
    cd debian || die "Cannot cd to debian"
    rm -rf changelog
    {
        echo "${PACKAGE_NAME} (${VERSION}-${RELEASE}) unstable; urgency=low"
        echo "  * Initial Release."
        echo " -- EvgeniyPatlan <evgeniy.patlan@percona.com> $(date -R)"
    } > changelog
    cd ..

    dch -D unstable --force-distribution -v "${VERSION}-${RELEASE}" \
        "Update to new ${PACKAGE_NAME} version ${VERSION}"
    dpkg-buildpackage -S

    cd ..

    copy_artifacts "source_deb" ./*_source.changes
    copy_artifacts "source_deb" ./*.dsc
    copy_artifacts "source_deb" ./*.orig.tar.gz
    # 3.0 (quilt) produces .debian.tar.*, older formats produce .diff.*
    copy_artifacts "source_deb" ./*.debian.tar.* 2>/dev/null \
        || copy_artifacts "source_deb" ./*diff* 2>/dev/null \
        || true
}

# ---------------------------------------------------------------------------
# build_deb
# ---------------------------------------------------------------------------
build_deb() {
    if [[ "$DEB" -eq 0 ]]; then
        log_info "Deb package will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    for file in 'dsc' 'orig.tar.gz' 'changes'; do
        find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*.${file}"
    done
    # 3.0 (quilt) produces .debian.tar.*, older formats produce .diff.*
    find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*.debian.tar.*" \
        || find_and_copy_artifact "source_deb" "${PACKAGE_NAME}*diff*" \
        || true

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"
    rm -fv ./*.deb
    rm -rf "${PACKAGE_NAME}-${VERSION}"

    local debian_codename
    debian_codename="$(lsb_release -sc)"
    ARCH="$(uname -m)"

    echo "DEBIAN=${debian_codename}" >> valkey.properties
    echo "ARCH=${ARCH}" >> valkey.properties

    local dsc
    dsc="$(basename "$(find . -name '*.dsc' | sort | tail -n1)")"

    dpkg-source -x "$dsc"

    cd "${PACKAGE_NAME}-${VERSION}" || die "Cannot cd to ${PACKAGE_NAME}-${VERSION}"

    dch -m -D "$debian_codename" --force-distribution \
        -v "1:${VERSION}-${RELEASE}.${debian_codename}" 'Update distribution'

    # Clear locale variables to avoid dpkg-buildpackage warnings
    # shellcheck disable=SC2046
    unset $(locale | cut -d= -f1) 2>/dev/null || true

    dpkg-buildpackage -rfakeroot -us -uc -b

    copy_artifacts "deb" "$WORKDIR"/*.*deb
}

# ---------------------------------------------------------------------------
# build_json_source_deb — source DEB for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_source_deb() {
    if [[ "$JSON_SDEB" -eq 0 ]]; then
        log_info "valkey-json source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${JSON_PACKAGE_NAME}"
    local ver="${JSON_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    # dpkg-source expects the orig tarball name to match the source package.
    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    # debian/ (including patches/) comes from this repo's json/ tree.
    cp -r "${BUILDER_SCRIPT_DIR}/../json/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    sed -i "1s/(\([^)]*\))/(${ver}-${RELEASE})/" "${name}-${ver}/debian/changelog"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "json source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_json_deb — binary DEB for percona-valkey-json
# ---------------------------------------------------------------------------
build_json_deb() {
    if [[ "$JSON_DEB" -eq 0 ]]; then
        log_info "valkey-json deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${JSON_PACKAGE_NAME}"
    local ver="${JSON_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "json dsc not found — run --build_json_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && deb_apply_codename && dpkg-buildpackage -b -us -uc ) \
        || die "json binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# install_deps_audit — build deps for the valkey-audit (C) module.
#   Same Percona repo setup as install_deps_json: the module builds against
#   valkeymodule.h from percona-valkey-dev(el). Triggered by --audit_deps.
# ---------------------------------------------------------------------------
install_deps_audit() {
    if [[ "$AUDIT_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    local channel="${VALKEY_REPO_CHANNEL:-testing}"
    local repo_name="${VALKEY_REPO_NAME:-valkey-91}"

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        $pkg_mgr -y install https://repo.percona.com/yum/percona-release-latest.noarch.rpm
        percona-release enable-only "${repo_name}" "${channel}" || percona-release enable "${repo_name}" "${channel}"
        $pkg_mgr -y install \
            gcc gcc-c++ cmake make git tar gzip rpm-build rpmdevtools \
            percona-valkey-devel
    else
        export DEBIAN_FRONTEND=noninteractive
        apt_get update
        apt_get -y install wget ca-certificates gnupg lsb-release
        wget -qO /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.generic_all.deb
        dpkg -i /tmp/percona-release.deb || apt_get install -f -y
        percona-release enable-only "${repo_name}" "${channel}" || percona-release enable "${repo_name}" "${channel}"
        apt_get update
        apt_get -y install \
            debhelper devscripts dpkg-dev fakeroot \
            cmake gcc g++ make git \
            percona-valkey-dev
    fi
    ensure_syft_system
}

# ---------------------------------------------------------------------------
# get_audit_sources — fetch valkey-audit into a source tarball
# ---------------------------------------------------------------------------
get_audit_sources() {
    if [[ "$AUDIT_SOURCE" -eq 0 ]]; then
        log_info "valkey-audit sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${AUDIT_PACKAGE_NAME}-${AUDIT_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    # A full clone + checkout (not --depth 1 --branch) so AUDIT_BRANCH can also
    # be a commit, which is what the default is until upstream tags v1.0.0.
    log_info "Cloning valkey-audit ${AUDIT_BRANCH} from ${AUDIT_REPO} ..."
    rm -rf "${srcdir}"
    git clone "${AUDIT_REPO}" "${name}" \
        || die "Failed to clone valkey-audit from ${AUDIT_REPO}"
    ( cd "${srcdir}" && git checkout -q "${AUDIT_BRANCH}" ) \
        || die "Failed to check out valkey-audit ref ${AUDIT_BRANCH}"

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log_info "Adding in-package README and settings reference ..."
    cp "${BUILDER_SCRIPT_DIR}/../audit/README.packaging.md" "${srcdir}/README.packaging.md" \
        || die "audit/README.packaging.md is missing"
    cp "${BUILDER_SCRIPT_DIR}/../audit/valkey-audit.conf" "${srcdir}/valkey-audit.conf" \
        || die "audit/valkey-audit.conf is missing"
    # SBOM generator, invoked by the spec/rules at package-build time.
    cp "${BUILDER_SCRIPT_DIR}/gen-module-sbom.sh" "${srcdir}/gen-module-sbom.sh" \
        || die "gen-module-sbom.sh is missing"
    chmod +x "${srcdir}/gen-module-sbom.sh"

    # Upstream's own packaging/ dir is not used here; drop it so the tarball
    # (and the SBOM scan) only carries what this repo builds.
    rm -rf "${srcdir}/packaging"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-audit source tarball"

    # Properties file consumed by the Jenkins pipeline to derive the upload path.
    cat > "${WORKDIR}/valkey-audit.properties" <<EOF
PRODUCT=${AUDIT_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${AUDIT_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-audit/${name}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# build_audit_srpm — source RPM for percona-valkey-audit
# ---------------------------------------------------------------------------
build_audit_srpm() {
    if [[ "$AUDIT_SRPM" -eq 0 ]]; then
        log_info "valkey-audit SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${AUDIT_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr audit_rpmbuild
    mkdir -vp audit_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../audit/rpm/${AUDIT_PACKAGE_NAME}.spec" audit_rpmbuild/SPECS/
    # Spec patches are kept in audit/debian/patches (single source of truth,
    # shared with the DEB quilt series); copy them next to the tarball.
    cp -av "${BUILDER_SCRIPT_DIR}/../audit/debian/patches/"*.patch audit_rpmbuild/SOURCES/
    mv -fv "$tarfile" audit_rpmbuild/SOURCES/

    sed -i "s/^Version:.*$/Version:        ${AUDIT_VERSION}/" \
        "audit_rpmbuild/SPECS/${AUDIT_PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" \
        "audit_rpmbuild/SPECS/${AUDIT_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/audit_rpmbuild" --define "dist .generic" \
        "audit_rpmbuild/SPECS/${AUDIT_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" audit_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_audit_rpm — binary RPM for percona-valkey-audit
# ---------------------------------------------------------------------------
build_audit_rpm() {
    if [[ "$AUDIT_RPM" -eq 0 ]]; then
        log_info "valkey-audit RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${AUDIT_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr audit_rb
    mkdir -vp audit_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" audit_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/audit_rb" --define "dist .${OS_NAME}" \
        --rebuild "audit_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" audit_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_audit_source_deb — source DEB for percona-valkey-audit
# ---------------------------------------------------------------------------
build_audit_source_deb() {
    if [[ "$AUDIT_SDEB" -eq 0 ]]; then
        log_info "valkey-audit source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${AUDIT_PACKAGE_NAME}"
    local ver="${AUDIT_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    # dpkg-source expects the orig tarball name to match the source package.
    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    # debian/ (including patches/) comes from this repo's audit/ tree.
    cp -r "${BUILDER_SCRIPT_DIR}/../audit/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    sed -i "1s/(\([^)]*\))/(${ver}-${RELEASE})/" "${name}-${ver}/debian/changelog"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "audit source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_audit_deb — binary DEB for percona-valkey-audit
# ---------------------------------------------------------------------------
build_audit_deb() {
    if [[ "$AUDIT_DEB" -eq 0 ]]; then
        log_info "valkey-audit deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${AUDIT_PACKAGE_NAME}"
    local ver="${AUDIT_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "audit dsc not found — run --build_audit_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && deb_apply_codename && dpkg-buildpackage -b -us -uc ) \
        || die "audit binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# build_bloom_srpm — source RPM for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_srpm() {
    if [[ "$BLOOM_SRPM" -eq 0 ]]; then
        log_info "valkey-bloom SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${BLOOM_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr bloom_rpmbuild
    mkdir -vp bloom_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../bloom/rpm/${BLOOM_PACKAGE_NAME}.spec" bloom_rpmbuild/SPECS/
    mv -fv "$tarfile" bloom_rpmbuild/SOURCES/

    sed -i "s/^Version:.*$/Version:        ${BLOOM_VERSION}/" \
        "bloom_rpmbuild/SPECS/${BLOOM_PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" \
        "bloom_rpmbuild/SPECS/${BLOOM_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/bloom_rpmbuild" --define "dist .generic" \
        "bloom_rpmbuild/SPECS/${BLOOM_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" bloom_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_bloom_rpm — binary RPM for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_rpm() {
    if [[ "$BLOOM_RPM" -eq 0 ]]; then
        log_info "valkey-bloom RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${BLOOM_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr bloom_rb
    mkdir -vp bloom_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" bloom_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/bloom_rb" --define "dist .${OS_NAME}" \
        --rebuild "bloom_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" bloom_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_bloom_source_deb — source DEB for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_source_deb() {
    if [[ "$BLOOM_SDEB" -eq 0 ]]; then
        log_info "valkey-bloom source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BLOOM_PACKAGE_NAME}"
    local ver="${BLOOM_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    cp -r "${BUILDER_SCRIPT_DIR}/../bloom/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    sed -i "1s/(\([^)]*\))/(${ver}-${RELEASE})/" "${name}-${ver}/debian/changelog"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "bloom source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_bloom_deb — binary DEB for percona-valkey-bloom
# ---------------------------------------------------------------------------
build_bloom_deb() {
    if [[ "$BLOOM_DEB" -eq 0 ]]; then
        log_info "valkey-bloom deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BLOOM_PACKAGE_NAME}"
    local ver="${BLOOM_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "bloom dsc not found — run --build_bloom_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && deb_apply_codename && dpkg-buildpackage -b -us -uc ) \
        || die "bloom binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# build_search_srpm — source RPM for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_srpm() {
    if [[ "$SEARCH_SRPM" -eq 0 ]]; then
        log_info "valkey-search SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${SEARCH_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr search_rpmbuild
    mkdir -vp search_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../search/rpm/${SEARCH_PACKAGE_NAME}.spec" search_rpmbuild/SPECS/
    mv -fv "$tarfile" search_rpmbuild/SOURCES/

    sed -i "s/^Version:.*$/Version:        ${SEARCH_VERSION}/" \
        "search_rpmbuild/SPECS/${SEARCH_PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" \
        "search_rpmbuild/SPECS/${SEARCH_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/search_rpmbuild" --define "dist .generic" \
        "search_rpmbuild/SPECS/${SEARCH_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" search_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_search_rpm — binary RPM for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_rpm() {
    if [[ "$SEARCH_RPM" -eq 0 ]]; then
        log_info "valkey-search RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${SEARCH_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr search_rb
    mkdir -vp search_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" search_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/search_rb" --define "dist .${OS_NAME}" \
        --rebuild "search_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" search_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_search_source_deb — source DEB for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_source_deb() {
    if [[ "$SEARCH_SDEB" -eq 0 ]]; then
        log_info "valkey-search source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${SEARCH_PACKAGE_NAME}"
    local ver="${SEARCH_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    cp -r "${BUILDER_SCRIPT_DIR}/../search/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    sed -i "1s/(\([^)]*\))/(${ver}-${RELEASE})/" "${name}-${ver}/debian/changelog"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "search source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_search_deb — binary DEB for percona-valkey-search
# ---------------------------------------------------------------------------
build_search_deb() {
    if [[ "$SEARCH_DEB" -eq 0 ]]; then
        log_info "valkey-search deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${SEARCH_PACKAGE_NAME}"
    local ver="${SEARCH_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "search dsc not found — run --build_search_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && deb_apply_codename && dpkg-buildpackage -b -us -uc ) \
        || die "search binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# install_deps_bundle — packaging tools for the meta-package. There is nothing
#   to compile; only rpmbuild (RPM) or debhelper/dpkg-dev (DEB) are needed.
# ---------------------------------------------------------------------------
install_deps_bundle() {
    if [[ "$BUNDLE_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"
        $pkg_mgr -y install rpm-build rpmdevtools
    else
        export DEBIAN_FRONTEND=noninteractive
        apt_get update
        apt_get -y install debhelper devscripts dpkg-dev dh-exec fakeroot
    fi
}

# ---------------------------------------------------------------------------
# get_bundle_sources — assemble the percona-valkey-bundle meta-package source.
#   There is no upstream code to clone/compile; the tarball just carries the
#   README + LICENSE so rpmbuild/dpkg have something to package the metadata on.
# ---------------------------------------------------------------------------
get_bundle_sources() {
    if [[ "$BUNDLE_SOURCE" -eq 0 ]]; then
        log_info "valkey-bundle sources will not be assembled"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BUNDLE_PACKAGE_NAME}-${BUNDLE_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Assembling ${name} (meta-package; no upstream source) ..."
    rm -rf "${srcdir}"
    mkdir -p "${srcdir}"
    cp "${BUILDER_SCRIPT_DIR}/../bundle/README.md" "${srcdir}/README.md" \
        || die "bundle/README.md is missing"
    cp "${BUILDER_SCRIPT_DIR}/../bundle/LICENSE" "${srcdir}/LICENSE" \
        || die "bundle/LICENSE is missing"

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-bundle source tarball"

    cat > "${WORKDIR}/valkey-bundle.properties" <<EOF
PRODUCT=${BUNDLE_PACKAGE_NAME}
PRODUCT_FULL=${name}
VERSION=${BUNDLE_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-bundle/${name}/${BUNDLE_VERSION}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# build_bundle_srpm — source RPM for the percona-valkey-bundle meta-package
# ---------------------------------------------------------------------------
build_bundle_srpm() {
    if [[ "$BUNDLE_SRPM" -eq 0 ]]; then
        log_info "valkey-bundle SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${BUNDLE_PACKAGE_NAME}*.tar.gz"
    local tarfile="$FOUND_FILE"

    rm -fr bundle_rpmbuild
    mkdir -vp bundle_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${BUILDER_SCRIPT_DIR}/../bundle/rpm/${BUNDLE_PACKAGE_NAME}.spec" bundle_rpmbuild/SPECS/
    mv -fv "$tarfile" bundle_rpmbuild/SOURCES/

    # Allow --bundle_version to flow through to the package version.
    sed -i "s/^Version:.*$/Version:        ${BUNDLE_VERSION}/" \
        "bundle_rpmbuild/SPECS/${BUNDLE_PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" \
        "bundle_rpmbuild/SPECS/${BUNDLE_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/bundle_rpmbuild" --define "dist .generic" \
        "bundle_rpmbuild/SPECS/${BUNDLE_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" bundle_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_bundle_rpm — binary (per-arch) RPM for the percona-valkey-bundle meta-pkg
# ---------------------------------------------------------------------------
build_bundle_rpm() {
    if [[ "$BUNDLE_RPM" -eq 0 ]]; then
        log_info "valkey-bundle RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${BUNDLE_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr bundle_rb
    mkdir -vp bundle_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" bundle_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/bundle_rb" --define "dist .${OS_NAME}" \
        --rebuild "bundle_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" bundle_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# build_bundle_source_deb — source DEB for the percona-valkey-bundle meta-pkg
# ---------------------------------------------------------------------------
build_bundle_source_deb() {
    if [[ "$BUNDLE_SDEB" -eq 0 ]]; then
        log_info "valkey-bundle source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BUNDLE_PACKAGE_NAME}"
    local ver="${BUNDLE_VERSION}"

    rm -rf "${name}-${ver}" "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    find_and_copy_artifact "source_tarball" "${name}*.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"

    cp -r "${BUILDER_SCRIPT_DIR}/../bundle/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    sed -i "1s/(\([^)]*\))/(${ver}-${RELEASE})/" "${name}-${ver}/debian/changelog"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "bundle source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_bundle_deb — binary (per-arch) DEB for the percona-valkey-bundle meta-pkg
# ---------------------------------------------------------------------------
build_bundle_deb() {
    if [[ "$BUNDLE_DEB" -eq 0 ]]; then
        log_info "valkey-bundle deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${BUNDLE_PACKAGE_NAME}"
    local ver="${BUNDLE_VERSION}"

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "bundle dsc not found — run --build_bundle_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    ( cd "${name}-${ver}" && deb_apply_codename && dpkg-buildpackage -b -us -uc ) \
        || die "bundle binary deb build failed"

    copy_artifacts "deb" "${name}_${ver}-"*_*.deb
}

# ---------------------------------------------------------------------------
# install_deps_admin — build deps for the valkey-admin administration server.
#   Needs Node.js >= 20 with npm (the package build runs the upstream npm
#   workspace build), the usual rpm/deb packaging tooling, and Syft for the
#   embedded SBOM. Triggered by --admin_deps.
#
#   "Node.js >= 20" is not one package name across these targets, which is
#   also why rpm/percona-valkey-admin.spec's BuildRequires is the boolean
#   "(nodejs >= 1:20 or nodejs22 >= 1:22)" rather than a plain name:
#     - EL8/EL9 ship nodejs as a DNF module whose default stream is older
#       than 20, so the nodejs:22 stream must be reset and enabled first.
#     - EL10 ships a new-enough nodejs directly, with no module stream.
#     - Amazon Linux 2023's new-enough build is the separately-named
#       nodejs22 / nodejs22-npm pair; its plain "nodejs" is too old.
#     - Debian/Ubuntu archives are too old on most targets here, so the
#       NodeSource repository is used.
#   These are the same per-distro paths valkey-admin/docker/Dockerfile.*
#   bakes into the standalone build harness, kept deliberately in step.
# ---------------------------------------------------------------------------
install_deps_admin() {
    if [[ "$ADMIN_DEPS" -eq 0 ]]; then
        return 0
    fi

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Cannot install dependencies — please run as root"
    fi

    if [[ "$OS" == "rpm" ]]; then
        local pkg_mgr="yum"
        command -v dnf &>/dev/null && pkg_mgr="dnf"

        # --allowerasing: rockylinux:9 and amazonlinux:2023 ship curl-minimal,
        # which conflicts with the full curl some of this tooling pulls in.
        # Older yum has no such flag, hence the plain retry.
        $pkg_mgr -y install --allowerasing \
            rpm-build rpmdevtools createrepo_c \
            git tar gzip findutils which python3 curl \
        || $pkg_mgr -y install \
            rpm-build rpmdevtools createrepo_c \
            git tar gzip findutils which python3

        # The spec uses %sysusers_requires_compat / %sysusers_create_compat.
        # On EL9+/Amazon those macros come from systemd-rpm-macros; on EL8
        # there is no such subpackage at all (they ship inside systemd), and
        # naming it there aborts the whole transaction.
        $pkg_mgr -y install systemd-rpm-macros || $pkg_mgr -y install systemd

        if [[ "$PLATFORM_FAMILY" == "amazon" ]]; then
            $pkg_mgr -y install nodejs22 nodejs22-npm \
                || die "Could not install nodejs22 on Amazon Linux"
        elif [[ "$RHEL" =~ ^[0-9]+$ ]] && [[ "$RHEL" -ge 10 ]]; then
            $pkg_mgr -y install nodejs npm \
                || die "Could not install nodejs on el${RHEL}"
        else
            $pkg_mgr -y module reset  nodejs    || true
            $pkg_mgr -y module enable nodejs:22 || true
            $pkg_mgr -y install nodejs npm \
                || die "Could not install nodejs from the nodejs:22 module stream"
        fi
    else
        export DEBIAN_FRONTEND=noninteractive
        apt_get update
        apt_get -y install \
            build-essential debhelper devscripts dh-make fakeroot lintian \
            dpkg-dev git curl ca-certificates wget python3

        # Prefer the distro's own nodejs when it is already new enough. The
        # newer targets in this matrix (Debian trixie, recent Ubuntu) ship
        # Node >= 20 themselves, and NodeSource does not necessarily publish a
        # suite for a just-released distro -- reaching for it unconditionally
        # would fail the build on exactly the newest platforms while a
        # perfectly good nodejs sat in the archive.
        local archive_node_major
        archive_node_major="$(apt-cache policy nodejs 2>/dev/null \
            | awk '/Candidate:/ {print $2}' | sed -E 's/^[0-9]+://; s/[^0-9].*//')"
        if [[ "$archive_node_major" =~ ^[0-9]+$ ]] && [[ "$archive_node_major" -ge 20 ]]; then
            log_info "Using the distro's own nodejs ${archive_node_major}.x"
            # Distro nodejs packages npm separately; the NodeSource one bundles it.
            apt_get -y install nodejs npm || die "Could not install the distro nodejs/npm"
        else
            log_info "Distro nodejs is ${archive_node_major:-absent}, below 20 -- using NodeSource"
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
                || die "NodeSource repository setup failed"
            apt_get -y install nodejs || die "Could not install nodejs from NodeSource"
        fi
    fi

    # Fail here, with the version named, rather than deep inside npm: an
    # too-old Node surfaces there as an opaque syntax or engine error.
    command -v node >/dev/null 2>&1 || die "node not available after dependency install"
    local node_major
    node_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')"
    [[ "$node_major" =~ ^[0-9]+$ ]] && [[ "$node_major" -ge 20 ]] \
        || die "node $(node --version 2>/dev/null) is too old for valkey-admin (needs >= 20)"
    log_info "node $(node --version) / npm $(npm --version 2>/dev/null || echo '?')"

    ensure_syft_system
}

# ---------------------------------------------------------------------------
# get_admin_sources — fetch valkey-admin into a source tarball
#   No dependency vendoring, unlike bloom (cargo vendor) and json (RapidJSON):
#   the npm dependency tree is installed by `npm ci` at PACKAGE-BUILD time
#   (the spec's %build and debian/rules' override_dh_auto_build, both via
#   common/build-server-payload.sh), so the RPM and DEB build stages need
#   outbound network to the npm registry. That is deliberate — a vendored
#   node_modules would add roughly a gigabyte to a tarball that every one of
#   this job's matrix stages downloads from the artifact store.
# ---------------------------------------------------------------------------
get_admin_sources() {
    if [[ "$ADMIN_SOURCE" -eq 0 ]]; then
        log_info "valkey-admin sources will not be downloaded"
        return 0
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    # Named for the UPSTREAM source, not the package: the spec unpacks it
    # with "%autosetup -n %{srcname}-%{version}" where srcname is
    # valkey-admin, and Source0's basename has to match. percona-valkey-admin
    # is the package name and appears only on the built artifacts.
    local name="${ADMIN_SRC_NAME}-${ADMIN_VERSION}"
    local srcdir="${WORKDIR}/${name}"

    log_info "Cloning valkey-admin ${ADMIN_BRANCH} from ${ADMIN_REPO} ..."
    rm -rf "${srcdir}"
    if ! git clone --depth 1 --branch "${ADMIN_BRANCH}" "${ADMIN_REPO}" "${name}"; then
        die "Failed to clone valkey-admin from ${ADMIN_REPO} (ref ${ADMIN_BRANCH})"
    fi

    local revision
    revision="$(cd "${srcdir}" && git rev-parse --short HEAD 2>/dev/null || echo unknown)"

    log_info "Stripping VCS metadata ..."
    find "${srcdir}" -name .git -type d -prune -exec rm -rf {} + 2>/dev/null || true

    log_info "Creating ${name}.tar.gz ..."
    tar --owner=0 --group=0 -czf "${name}.tar.gz" "${name}" \
        || die "Failed to create valkey-admin source tarball"

    # Properties file consumed by the Jenkins pipeline to derive the upload path.
    cat > "${WORKDIR}/valkey-admin.properties" <<EOF
PRODUCT=${ADMIN_PACKAGE_NAME}
PRODUCT_FULL=${ADMIN_PACKAGE_NAME}-${ADMIN_VERSION}
VERSION=${ADMIN_VERSION}
BUILD_NUMBER=${BUILD_NUMBER:-}
BUILD_ID=${BUILD_ID:-}
REVISION=${revision}
UPLOAD=UPLOAD/experimental/BUILDS/valkey-admin/${ADMIN_PACKAGE_NAME}-${ADMIN_VERSION}/${ADMIN_BRANCH}/${revision}/${BUILD_ID:-}
EOF

    copy_artifacts "source_tarball" "${name}.tar.gz"

    cd "$CURDIR" || die "Cannot cd to $CURDIR"
}

# ---------------------------------------------------------------------------
# build_admin_srpm — source RPM for percona-valkey-admin
#   The spec carries EIGHT Sources, not one: Source0 is the upstream tarball
#   and Source1-7 are this packaging's own aux files (sysusers and tmpfiles
#   fragments, systemd unit, env file, the in-package README, the payload
#   build helper and the repo-root SBOM generator). None of them exist in the
#   upstream tree, so they are staged into SOURCES here. They must all be in
#   place before rpmbuild PARSES the spec, not merely before it builds:
#   "%sysusers_create_compat %{SOURCE1}" expands at parse time via a
#   shell-exec macro, and a missing Source1 yields a silently EMPTY %pre —
#   no service user, and %attr falling back to root — rather than an error.
#   The resulting SRPM embeds all eight, so build_admin_rpm's --rebuild needs
#   nothing further.
# ---------------------------------------------------------------------------
build_admin_srpm() {
    if [[ "$ADMIN_SRPM" -eq 0 ]]; then
        log_info "valkey-admin SRC RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build src rpm on a Debian-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    find_and_copy_artifact "source_tarball" "${ADMIN_SRC_NAME}-${ADMIN_VERSION}.tar.gz"
    local tarfile="$FOUND_FILE"

    local admin_dir="${BUILDER_SCRIPT_DIR}/../valkey-admin"

    rm -fr admin_rpmbuild
    mkdir -vp admin_rpmbuild/{SOURCES,SPECS,BUILD,SRPMS,RPMS}

    cp -av "${admin_dir}/rpm/${ADMIN_PACKAGE_NAME}.spec" admin_rpmbuild/SPECS/
    mv -fv "$tarfile" admin_rpmbuild/SOURCES/

    # Source1-4: installed by %install. Source5: shipped as %doc.
    cp -av "${admin_dir}/rpm/valkey-admin.sysusers" admin_rpmbuild/SOURCES/
    cp -av "${admin_dir}/rpm/valkey-admin.service"  admin_rpmbuild/SOURCES/
    cp -av "${admin_dir}/rpm/valkey-admin.tmpfiles" admin_rpmbuild/SOURCES/
    cp -av "${admin_dir}/rpm/valkey-admin.env"      admin_rpmbuild/SOURCES/
    cp -av "${admin_dir}/README.packaging.md"       admin_rpmbuild/SOURCES/
    # Source6: executed in %build to assemble the server payload.
    cp -av "${admin_dir}/common/build-server-payload.sh" admin_rpmbuild/SOURCES/
    # Source7: executed in %install — the repo-root SBOM generator shared
    # with the sibling module packages.
    cp -av "${BUILDER_SCRIPT_DIR}/gen-module-sbom.sh" admin_rpmbuild/SOURCES/

    sed -i "s/^Version:.*$/Version:        ${ADMIN_VERSION}/" \
        "admin_rpmbuild/SPECS/${ADMIN_PACKAGE_NAME}.spec"
    sed -i "s/^Release:.*$/Release:        ${RELEASE}%{?dist}/" \
        "admin_rpmbuild/SPECS/${ADMIN_PACKAGE_NAME}.spec"

    rpmbuild -bs --define "_topdir ${WORKDIR}/admin_rpmbuild" --define "dist .generic" \
        "admin_rpmbuild/SPECS/${ADMIN_PACKAGE_NAME}.spec"

    copy_artifacts "srpm" admin_rpmbuild/SRPMS/*.src.rpm
}

# ---------------------------------------------------------------------------
# build_admin_rpm — binary RPM for percona-valkey-admin
# ---------------------------------------------------------------------------
build_admin_rpm() {
    if [[ "$ADMIN_RPM" -eq 0 ]]; then
        log_info "valkey-admin RPM will not be created"
        return 0
    fi

    if [[ "$OS" == "deb" ]]; then
        die "Cannot build rpm on a Debian-based system"
    fi

    find_and_copy_artifact "srpm" "${ADMIN_PACKAGE_NAME}*.src.rpm"
    local src_rpm="$FOUND_FILE"

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    rm -fr admin_rb
    mkdir -vp admin_rb/{SOURCES,SPECS,BUILD,SRPMS,RPMS,BUILDROOT}
    cp "$src_rpm" admin_rb/SRPMS/

    rpmbuild --define "_topdir ${WORKDIR}/admin_rb" --define "dist .${OS_NAME}" \
        --rebuild "admin_rb/SRPMS/${src_rpm}"

    copy_artifacts "rpm" admin_rb/RPMS/*/*.rpm
}

# ---------------------------------------------------------------------------
# admin_provide_rules_mounts — satisfy the /packaging and /repo-scripts paths
#   that valkey-admin/debian/rules reaches into by absolute path.
#
#   Those two paths are a caller-provided contract, documented in that rules
#   file: the aux files it installs (systemd unit, env file), the payload
#   build helper and the SBOM generator are not in the upstream source tree,
#   so none of them can be found relative to $(CURDIR). The standalone Docker
#   harness (valkey-admin/build-deb.sh) supplies them as read-only bind
#   mounts. This builder already runs inside the build container with the
#   whole valkey-packaging checkout present, so it satisfies the same
#   contract with symlinks — leaving debian/rules byte-identical to what the
#   standalone harness builds and what the packaging test suite exercises,
#   rather than forking it for a second caller.
# ---------------------------------------------------------------------------
admin_provide_rules_mounts() {
    local admin_dir repo_scripts
    admin_dir="$(cd "${BUILDER_SCRIPT_DIR}/../valkey-admin" 2>/dev/null && pwd)" \
        || die "valkey-admin packaging directory not found next to scripts/"
    repo_scripts="${BUILDER_SCRIPT_DIR}"

    [ -f "${admin_dir}/common/build-server-payload.sh" ] \
        || die "${admin_dir}/common/build-server-payload.sh is missing"
    [ -f "${admin_dir}/rpm/valkey-admin.service" ] \
        || die "${admin_dir}/rpm/valkey-admin.service is missing"
    [ -f "${repo_scripts}/gen-module-sbom.sh" ] \
        || die "${repo_scripts}/gen-module-sbom.sh is missing"

    [[ "$(id -u)" -eq 0 ]] \
        || die "Creating /packaging and /repo-scripts for debian/rules requires root"

    # Only ever replace a symlink — one this function left behind in an
    # earlier stage sharing the workspace, pointing at a stale checkout. If
    # either path is a real directory it is a bind mount from the standalone
    # harness, so leave it and its contents completely alone.
    if [ -L /packaging ];    then rm -f /packaging;    fi
    if [ -L /repo-scripts ]; then rm -f /repo-scripts; fi
    if [ ! -e /packaging ];    then ln -sfn "${admin_dir}"    /packaging;    fi
    if [ ! -e /repo-scripts ]; then ln -sfn "${repo_scripts}" /repo-scripts; fi

    log_info "debian/rules inputs: /packaging -> ${admin_dir}, /repo-scripts -> ${repo_scripts}"
}

# ---------------------------------------------------------------------------
# build_admin_source_deb — source DEB for percona-valkey-admin
# ---------------------------------------------------------------------------
build_admin_source_deb() {
    if [[ "$ADMIN_SDEB" -eq 0 ]]; then
        log_info "valkey-admin source deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build source deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${ADMIN_PACKAGE_NAME}"
    local ver="${ADMIN_VERSION}"

    rm -rf "${name}-${ver}" "${ADMIN_SRC_NAME}-${ver}" \
           "${name}_${ver}".orig.tar.gz "${name}_${ver}-"*

    # The tarball is named for the upstream source (valkey-admin-<ver>.tar.gz)
    # while the DEB source package is percona-valkey-admin, so the orig
    # tarball is a rename and the unpacked tree is moved to the source
    # package's directory name. dpkg-source does not require the tarball's
    # own top-level directory to match either of them.
    find_and_copy_artifact "source_tarball" "${ADMIN_SRC_NAME}-${ver}.tar.gz"
    local tarfile="$FOUND_FILE"

    cp "$tarfile" "${name}_${ver}.orig.tar.gz"
    tar xf "$tarfile"
    mv "${ADMIN_SRC_NAME}-${ver}" "${name}-${ver}"

    cp -r "${BUILDER_SCRIPT_DIR}/../valkey-admin/debian" "${name}-${ver}/debian"
    chmod +x "${name}-${ver}/debian/rules"

    sed -i "1s/(\([^)]*\))/(${ver}-${RELEASE})/" "${name}-${ver}/debian/changelog"

    ( cd "${name}-${ver}" && dpkg-buildpackage -S -us -uc ) \
        || die "valkey-admin source deb build failed"

    copy_artifacts "source_deb" "${name}_${ver}-"*.dsc
    copy_artifacts "source_deb" "${name}_${ver}.orig.tar.gz"
    copy_artifacts "source_deb" "${name}_${ver}-"*.debian.tar.* 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# build_admin_deb — binary DEB for percona-valkey-admin
# ---------------------------------------------------------------------------
build_admin_deb() {
    if [[ "$ADMIN_DEB" -eq 0 ]]; then
        log_info "valkey-admin deb will not be created"
        return 0
    fi

    if [[ "$OS" == "rpm" ]]; then
        die "Cannot build deb on an RPM-based system"
    fi

    cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

    local name="${ADMIN_PACKAGE_NAME}"
    local ver="${ADMIN_VERSION}"

    # Clear any .deb from a previous run in this workspace BEFORE building, so
    # the post-build non-empty check below cannot be satisfied by a leftover
    # and copy_artifacts cannot ship one. Jenkins stages start clean, but a
    # local or re-run invocation does not.
    rm -f "${name}"*_"${ver}-"*_*.deb

    for ext in 'dsc' 'orig.tar.gz'; do
        find_and_copy_artifact "source_deb" "${name}_${ver}*.${ext}"
    done
    find_and_copy_artifact "source_deb" "${name}_${ver}*.debian.tar.*" || true

    rm -rf "${name}-${ver}"
    local dsc
    dsc="$(basename "$(find . -maxdepth 1 -name "${name}_${ver}*.dsc" | sort | tail -n1)")"
    [ -n "$dsc" ] || die "valkey-admin dsc not found — run --build_admin_src_deb first"
    dpkg-source -x "$dsc" "${name}-${ver}"

    admin_provide_rules_mounts

    ( cd "${name}-${ver}" && deb_apply_codename && dpkg-buildpackage -b -us -uc ) \
        || die "valkey-admin binary deb build failed"

    # NOTE the wildcard between the source name and the version, which the
    # sibling products' equivalent line does not have. Theirs match
    # "<name>_<ver>-..." because their source and binary package names are the
    # same string (percona-valkey-bloom builds percona-valkey-bloom). This
    # source is percona-valkey-admin and it builds percona-valkey-admin-SERVER,
    # so the un-wildcarded glob matches nothing, reaches cp as a literal, and
    # aborts the stage after a perfectly good package was already built. The
    # explicit count below turns that into a diagnosis instead of a bare
    # "cp: cannot stat 'percona-valkey-admin_1.1.1-*_*.deb'".
    local produced
    produced=$(find . -maxdepth 1 -name "${name}*_${ver}-*_*.deb" | wc -l)
    [ "$produced" -gt 0 ] \
        || die "dpkg-buildpackage produced no .deb matching ${name}*_${ver}-*_*.deb"

    copy_artifacts "deb" "${name}"*_"${ver}-"*_*.deb
}

# ===========================================================================
# Main
# ===========================================================================
CURDIR="$(pwd)"
WORKDIR=""
SRPM=0
SDEB=0
RPM=0
DEB=0
SOURCE=0
OS_NAME=""
ARCH=""
OS=""
PLATFORM_FAMILY=""
RHEL="0"
INSTALL=0
BRANCH="$DEFAULT_BRANCH"
REPO="$DEFAULT_REPO"
VERSION="$DEFAULT_VERSION"
RELEASE="$DEFAULT_RELEASE"
LOCAL_BUILD=0
JSON_DEPS=0
JSON_SOURCE=0
JSON_SRPM=0
JSON_RPM=0
JSON_SDEB=0
JSON_DEB=0
JSON_REPO="$DEFAULT_JSON_REPO"
JSON_VERSION="$DEFAULT_JSON_VERSION"
JSON_BRANCH=""
AUDIT_DEPS=0
AUDIT_SOURCE=0
AUDIT_SRPM=0
AUDIT_RPM=0
AUDIT_SDEB=0
AUDIT_DEB=0
AUDIT_REPO="$DEFAULT_AUDIT_REPO"
AUDIT_VERSION="$DEFAULT_AUDIT_VERSION"
AUDIT_BRANCH="$DEFAULT_AUDIT_BRANCH"
BLOOM_DEPS=0
BLOOM_SOURCE=0
BLOOM_SRPM=0
BLOOM_RPM=0
BLOOM_SDEB=0
BLOOM_DEB=0
BLOOM_REPO="$DEFAULT_BLOOM_REPO"
BLOOM_VERSION="$DEFAULT_BLOOM_VERSION"
BLOOM_BRANCH=""
SEARCH_DEPS=0
SEARCH_SOURCE=0
SEARCH_SRPM=0
SEARCH_RPM=0
SEARCH_SDEB=0
SEARCH_DEB=0
SEARCH_REPO="$DEFAULT_SEARCH_REPO"
SEARCH_VERSION="$DEFAULT_SEARCH_VERSION"
SEARCH_BRANCH=""
BUNDLE_DEPS=0
BUNDLE_SOURCE=0
BUNDLE_SRPM=0
BUNDLE_RPM=0
BUNDLE_SDEB=0
BUNDLE_DEB=0
BUNDLE_VERSION="$DEFAULT_BUNDLE_VERSION"
ADMIN_DEPS=0
ADMIN_SOURCE=0
ADMIN_SRPM=0
ADMIN_RPM=0
ADMIN_SDEB=0
ADMIN_DEB=0
ADMIN_REPO="$DEFAULT_ADMIN_REPO"
ADMIN_VERSION="$DEFAULT_ADMIN_VERSION"
ADMIN_BRANCH=""

parse_arguments "$@"

# Default each module's git ref to its version (a tag) unless overridden.
JSON_BRANCH="${JSON_BRANCH:-$JSON_VERSION}"
BLOOM_BRANCH="${BLOOM_BRANCH:-$BLOOM_VERSION}"
SEARCH_BRANCH="${SEARCH_BRANCH:-$SEARCH_VERSION}"
# valkey-admin tags its releases with a leading "v" (v1.1.1), unlike the
# module repos above whose tags are the bare version — mirroring the
# "refs/tags/v%{version}" in rpm/percona-valkey-admin.spec's Source0 URL.
ADMIN_BRANCH="${ADMIN_BRANCH:-v$ADMIN_VERSION}"

# PRODUCT_FULL is set after parsing so --version can override; exported for child processes
export PRODUCT_FULL="${PRODUCT}-${VERSION}-${RELEASE}"

if [[ $# -eq 0 ]]; then
    usage
fi

check_workdir
get_system
install_deps
install_deps_json
install_deps_audit
install_deps_bloom
install_deps_search
install_deps_bundle
install_deps_admin
get_sources
get_json_sources
get_audit_sources
get_bloom_sources
get_search_sources
get_bundle_sources
get_admin_sources
build_srpm
build_source_deb
build_rpm
build_deb
build_json_srpm
build_json_rpm
build_json_source_deb
build_json_deb
build_audit_srpm
build_audit_rpm
build_audit_source_deb
build_audit_deb
build_bloom_srpm
build_bloom_rpm
build_bloom_source_deb
build_bloom_deb
build_search_srpm
build_search_rpm
build_search_source_deb
build_search_deb
build_bundle_srpm
build_bundle_rpm
build_bundle_source_deb
build_bundle_deb
build_admin_srpm
build_admin_rpm
build_admin_source_deb
build_admin_deb
