#!/usr/bin/env bash
# test_packages.sh — Automated test suite for Percona Valkey packages
#
# Usage: bash scripts/test_packages.sh [--pkg-dir=DIR | --repo] [--version=X.Y.Z]
#
# Auto-detects OS (Debian vs RHEL), installs packages from a local directory
# or from the Percona repository, runs validation tests, removes packages,
# and verifies clean removal.

set -euo pipefail

###############################################################################
# Constants & globals
###############################################################################
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
PKG_DIR=""
INSTALL_MODE=""  # "pkg-dir" or "repo"
REPO_CHANNEL="testing"
OS_FAMILY=""  # "deb" or "rpm"
EXPECTED_VERSION=""
START_TIME=""
FAILED_TESTS=()
SKIPPED_TESTS=()
INSTALLED_PKGS=()

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    RESET=''
fi

###############################################################################
# Utility functions
###############################################################################
pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf "  ${GREEN}PASS${RESET} %s\n" "$1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAILED_TESTS+=("$1")
    printf "  ${RED}FAIL${RESET} %s\n" "$1"
}

skip() {
    SKIP_COUNT=$((SKIP_COUNT + 1))
    SKIPPED_TESTS+=("$1")
    printf "  ${YELLOW}SKIP${RESET} %s\n" "$1"
}

section_header() {
    printf "\n${CYAN}${BOLD}=== %s ===${RESET}\n" "$1"
}

###############################################################################
# Assertion helpers
###############################################################################
assert_file_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -f "$path" ]]; then
        pass "$label exists"
    else
        fail "$label exists (not found: $path)"
    fi
}

assert_file_not_exists() {
    local path="$1" label="${2:-$1}"
    if [[ ! -e "$path" ]]; then
        pass "$label removed"
    else
        fail "$label removed (still exists: $path)"
    fi
}

assert_dir_exists() {
    local path="$1" label="${2:-$1}"
    if [[ -d "$path" ]]; then
        pass "$label exists"
    else
        fail "$label exists (not found: $path)"
    fi
}

assert_dir_not_exists() {
    local path="$1" label="${2:-$1}"
    if [[ ! -d "$path" ]]; then
        pass "$label removed"
    else
        fail "$label removed (still exists: $path)"
    fi
}

assert_executable() {
    local path="$1" label="${2:-$1}"
    if [[ -x "$path" ]]; then
        pass "$label is executable"
    else
        fail "$label is executable (not executable or missing: $path)"
    fi
}

assert_symlink() {
    local path="$1" label="${2:-$1}"
    if [[ -L "$path" ]]; then
        pass "$label is a symlink"
    elif [[ -f "$path" ]]; then
        # Some packaging may install actual files instead of symlinks
        pass "$label exists (regular file, not symlink)"
    else
        fail "$label is a symlink (not found: $path)"
    fi
}

assert_owner() {
    local path="$1" expected_owner="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label owner is $expected_owner (path not found: $path)"
        return
    fi
    local actual_owner
    actual_owner="$(stat -c '%U:%G' "$path")"
    if [[ "$actual_owner" == "$expected_owner" ]]; then
        pass "$label owner is $expected_owner"
    else
        fail "$label owner is $expected_owner (got: $actual_owner)"
    fi
}

assert_perms() {
    local path="$1" expected_mode="$2" label="${3:-$1}"
    if [[ ! -e "$path" ]]; then
        fail "$label mode is $expected_mode (path not found: $path)"
        return
    fi
    local actual_mode
    actual_mode="$(stat -c '%a' "$path")"
    if [[ "$actual_mode" == "$expected_mode" ]]; then
        pass "$label mode is $expected_mode"
    else
        fail "$label mode is $expected_mode (got: $actual_mode)"
    fi
}

assert_command_succeeds() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label (command failed: $*)"
    fi
}

assert_command_output_contains() {
    local label="$1" expected="$2"
    shift 2
    local output
    output="$("$@" 2>&1)" || true
    if [[ "$output" == *"$expected"* ]]; then
        pass "$label"
    else
        fail "$label (expected output containing '$expected', got: '$output')"
    fi
}

assert_systemd_property() {
    local service="$1" property="$2" expected="$3" label="${4:-}"
    [[ -z "$label" ]] && label="$service $property=$expected"
    local actual
    actual="$(systemctl show "$service" --property="$property" --value 2>/dev/null)" || true
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label (got: $actual)"
    fi
}

###############################################################################
# Systemd helpers
###############################################################################
has_systemd() {
    # Check if systemd is PID 1
    [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]
}

wait_for_service() {
    local service_name="$1" timeout="${2:-15}"
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

###############################################################################
# OS detection
###############################################################################
detect_os() {
    if [[ -f /etc/debian_version ]]; then
        OS_FAMILY="deb"
    elif [[ -f /etc/redhat-release ]] || [[ -f /etc/centos-release ]] || [[ -f /etc/rocky-release ]] || [[ -f /etc/almalinux-release ]]; then
        OS_FAMILY="rpm"
    elif command -v rpm &>/dev/null && command -v yum &>/dev/null; then
        OS_FAMILY="rpm"
    elif command -v dpkg &>/dev/null && command -v apt-get &>/dev/null; then
        OS_FAMILY="deb"
    else
        echo "ERROR: Cannot detect OS family (neither Debian nor RHEL based)" >&2
        exit 1
    fi
    echo "Detected OS family: $OS_FAMILY"
}

###############################################################################
# Package install/remove
###############################################################################
install_packages_deb() {
    section_header "Installing .deb packages"
    # Fix any broken deps first
    apt-get update -qq
    apt-get install -f -y -qq

    local debs=()
    for f in "$PKG_DIR"/percona-valkey*.deb; do
        [[ -f "$f" ]] || continue
        # The admin server is installed separately: it is the one package that
        # needs a Node >= 20 runtime, which most targets cannot resolve
        # without help (see the comment above ensure_node_runtime_deb).
        [[ "$f" == *percona-valkey-admin-server* ]] && continue
        debs+=("$f")
    done

    # An admin-only directory is not an empty one: the admin artifact was
    # deliberately left out of the list above.
    if [[ ${#debs[@]} -eq 0 ]] && [[ -z "$(admin_artifacts_in_pkg_dir deb)" ]]; then
        echo "ERROR: No percona-valkey*.deb files found in $PKG_DIR" >&2
        exit 1
    fi

    if [[ ${#debs[@]} -gt 0 ]]; then
        echo "Installing ${#debs[@]} package(s)..."
        apt-get install -y "${debs[@]}" 2>&1 || {
            echo "Install failed, attempting with --fix-broken..."
            apt-get install -y --fix-broken "${debs[@]}" 2>&1
        }
    fi
    install_admin_from_pkg_dir "deb"
    # Capture installed package names and versions
    while IFS= read -r line; do
        INSTALLED_PKGS+=("$line")
    done < <(dpkg -l 'percona-valkey*' 2>/dev/null | awk '/^ii/ {printf "%s %s %s\n", $2, $3, $4}')
    echo "Installation complete."
}

install_packages_rpm() {
    section_header "Installing .rpm packages"

    local rpms=()
    for f in "$PKG_DIR"/percona-valkey*.rpm; do
        [[ -f "$f" ]] || continue
        # Skip source RPMs and debuginfo
        [[ "$f" == *.src.rpm ]] && continue
        [[ "$f" == *debuginfo* ]] && continue
        [[ "$f" == *debugsource* ]] && continue
        # Installed separately: see the comment above the Node runtime
        # helpers below.
        [[ "$f" == *percona-valkey-admin-server* ]] && continue
        rpms+=("$f")
    done

    # An admin-only directory is not an empty one: the admin artifact was
    # deliberately left out of the list above.
    if [[ ${#rpms[@]} -eq 0 ]] && [[ -z "$(admin_artifacts_in_pkg_dir rpm)" ]]; then
        echo "ERROR: No percona-valkey*.rpm files found in $PKG_DIR" >&2
        exit 1
    fi

    if [[ ${#rpms[@]} -gt 0 ]]; then
        echo "Installing ${#rpms[@]} package(s)..."
        yum localinstall -y "${rpms[@]}" 2>&1
    fi
    install_admin_from_pkg_dir "rpm"
    # Capture installed package names and versions
    while IFS= read -r line; do
        [[ -n "$line" ]] && INSTALLED_PKGS+=("$line")
    done < <(rpm -qa 'percona-valkey*' --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' 2>/dev/null)
    echo "Installation complete."
}

###############################################################################
# Repo-based install (percona-release)
###############################################################################
install_percona_release_deb() {
    echo "Installing percona-release (deb)..."
    local tmp_deb
    tmp_deb="$(mktemp /tmp/percona-release-XXXXXX.deb)"
    wget -q -O "$tmp_deb" https://repo.percona.com/apt/percona-release_latest.generic_all.deb
    dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    apt-get update -qq
}

install_percona_release_rpm() {
    echo "Installing percona-release (rpm)..."
    yum install -y https://repo.percona.com/yum/percona-release-latest.noarch.rpm
}

###############################################################################
# Node runtime for percona-valkey-admin-server
###############################################################################
# The admin server is the only package in the set that needs a language
# runtime: "nodejs (>= 20)" on DEB, "(nodejs >= 1:20 or nodejs22 >= 1:22)" on
# RPM. Almost no target satisfies that floor from its own archive -- bookworm
# ships Node 18, jammy 12, noble 18, and on EL8/EL9 modular filtering hides
# every modular nodejs until a stream is enabled, so the dependency cannot
# resolve even though a new enough package exists in the repository. Amazon
# Linux 2023 satisfies it through nodejs22, and trixie and EL10 through their
# base nodejs.
#
# So the admin package is installed in a transaction of its own, after the
# runtime has been arranged the way the product's own install documentation
# tells an operator to arrange it (valkey-admin/README.packaging.md): enable a
# module stream on EL, add NodeSource on the older DEB archives. Keeping it
# out of the main transaction means a target that cannot get a runtime still
# tests everything else instead of failing the whole install.
#
# When the admin package ends up not installed, test_admin_server skips with
# the reason recorded here -- an unobtainable Node runtime is a property of
# the test host, not a defect in the package.
ADMIN_SKIP_REASON=""
ADMIN_WAS_INSTALLED=0

node_major() {
    local v
    v="$(node --version 2>/dev/null || true)"
    [[ -n "$v" ]] || v="$(nodejs --version 2>/dev/null || true)"
    [[ -n "$v" ]] || return 1
    v="${v#v}"
    printf '%s' "${v%%.*}"
}

node_runtime_is_current() {
    local major
    major="$(node_major)" || return 1
    [[ -n "$major" ]] || return 1
    [[ "$major" =~ ^[0-9]+$ ]] || return 1
    (( major >= 20 ))
}

ensure_node_runtime_deb() {
    node_runtime_is_current && return 0
    local candidate
    candidate="$(apt-cache policy nodejs 2>/dev/null | awk '/Candidate:/ {print $2}')"
    echo "nodejs in this archive: ${candidate:-not available} (the admin server needs >= 20)"
    echo "Adding the NodeSource 22.x archive..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1 || return 1
    apt-get install -y -qq nodejs >/dev/null 2>&1 || return 1
    node_runtime_is_current
}

ensure_node_runtime_rpm() {
    node_runtime_is_current && return 0
    # Enabling a stream only unhides the modular packages; the admin package's
    # own dependency then pulls the runtime in. Amazon Linux 2023 and EL10
    # carry no nodejs module at all, where this fails harmlessly and the
    # dependency resolves from the base repositories.
    if dnf -y module enable nodejs:22 >/dev/null 2>&1 \
        || dnf -y module enable nodejs:20 >/dev/null 2>&1; then
        echo "Enabled a nodejs module stream >= 20"
    else
        echo "No nodejs module stream to enable; relying on the base repositories"
    fi
}

install_admin_from_repo() {
    section_header "Installing percona-valkey-admin-server"
    if [[ "$OS_FAMILY" == "deb" ]]; then
        if ! ensure_node_runtime_deb; then
            ADMIN_SKIP_REASON="no Node >= 20 runtime could be installed on this host"
            echo "SKIPPING admin server: $ADMIN_SKIP_REASON"
            return 0
        fi
        if apt-get install -y percona-valkey-admin-server; then
            echo "percona-valkey-admin-server installed."
            return 0
        fi
        ADMIN_SKIP_REASON="percona-valkey-admin-server is not in the $REPO_CHANNEL channel of this repository"
    else
        ensure_node_runtime_rpm
        if yum install -y percona-valkey-admin-server; then
            echo "percona-valkey-admin-server installed."
            return 0
        fi
        ADMIN_SKIP_REASON="percona-valkey-admin-server could not be installed from the $REPO_CHANNEL channel (missing package, or no Node >= 20 runtime)"
    fi
    echo "SKIPPING admin server: $ADMIN_SKIP_REASON"
    return 0
}

admin_artifacts_in_pkg_dir() {
    local ext="$1" f
    for f in "$PKG_DIR"/percona-valkey-admin-server*."$ext"; do
        [[ -f "$f" ]] || continue
        printf '%s\n' "$f"
    done
}

install_admin_from_pkg_dir() {
    local ext="$1"
    local artifacts=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && artifacts+=("$f")
    done < <(admin_artifacts_in_pkg_dir "$ext")

    if [[ ${#artifacts[@]} -eq 0 ]]; then
        ADMIN_SKIP_REASON="no percona-valkey-admin-server*.$ext in $PKG_DIR"
        return 0
    fi

    section_header "Installing percona-valkey-admin-server"
    if [[ "$ext" == "deb" ]]; then
        if ! ensure_node_runtime_deb; then
            ADMIN_SKIP_REASON="no Node >= 20 runtime could be installed on this host"
            echo "SKIPPING admin server: $ADMIN_SKIP_REASON"
            return 0
        fi
        if apt-get install -y "${artifacts[@]}"; then
            echo "percona-valkey-admin-server installed."
            return 0
        fi
    else
        ensure_node_runtime_rpm
        if yum localinstall -y "${artifacts[@]}"; then
            echo "percona-valkey-admin-server installed."
            return 0
        fi
    fi
    ADMIN_SKIP_REASON="percona-valkey-admin-server did not install from $PKG_DIR (no Node >= 20 provider for its dependency)"
    echo "SKIPPING admin server: $ADMIN_SKIP_REASON"
    return 0
}

install_from_repo_deb() {
    section_header "Installing from Percona repo (deb, channel=$REPO_CHANNEL)"
    apt-get update -qq
    apt-get install -y -qq wget gnupg2 lsb-release curl
    install_percona_release_deb
    percona-release enable valkey-91 "$REPO_CHANNEL"
    apt-get update -qq
    apt-get install -y percona-valkey-server percona-valkey-sentinel \
        percona-valkey-tools percona-valkey-compat-redis percona-valkey-compat-redis-dev \
        percona-valkey-dev
    install_admin_from_repo
    # Capture installed package names and versions
    while IFS= read -r line; do
        INSTALLED_PKGS+=("$line")
    done < <(dpkg -l 'percona-valkey*' 2>/dev/null | awk '/^ii/ {printf "%s %s %s\n", $2, $3, $4}')
    echo "Installation complete."
}

install_from_repo_rpm() {
    section_header "Installing from Percona repo (rpm, channel=$REPO_CHANNEL)"
    install_percona_release_rpm
    percona-release enable valkey-91 "$REPO_CHANNEL"
    yum install -y percona-valkey percona-valkey-compat-redis \
        percona-valkey-compat-redis-devel percona-valkey-devel
    install_admin_from_repo
    # Capture installed package names and versions
    while IFS= read -r line; do
        [[ -n "$line" ]] && INSTALLED_PKGS+=("$line")
    done < <(rpm -qa 'percona-valkey*' --qf '%{NAME} %{EPOCH}:%{VERSION}-%{RELEASE} %{ARCH}\n' 2>/dev/null)
    echo "Installation complete."
}

remove_packages_deb() {
    section_header "Removing .deb packages"
    # Get list of installed percona-valkey packages
    local pkgs
    pkgs="$(dpkg -l 'percona-valkey*' 2>/dev/null | awk '/^ii/ {print $2}' || true)"
    if [[ -n "$pkgs" ]]; then
        echo "Purging: $pkgs"
        # shellcheck disable=SC2086
        apt-get purge -y $pkgs 2>&1
        apt-get autoremove -y 2>&1
    else
        echo "No percona-valkey packages found to remove."
    fi
    echo "Removal complete."
}

remove_packages_rpm() {
    section_header "Removing .rpm packages"
    local pkgs
    pkgs="$(rpm -qa 'percona-valkey*' 2>/dev/null || true)"
    if [[ -n "$pkgs" ]]; then
        echo "Removing: $pkgs"
        # shellcheck disable=SC2086
        yum remove -y $pkgs 2>&1
    else
        echo "No percona-valkey packages found to remove."
    fi
    echo "Removal complete."
}

###############################################################################
# Tests
###############################################################################
test_binaries() {
    section_header "Test: Binaries"
    local bins=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel)
    for bin in "${bins[@]}"; do
        assert_executable "/usr/bin/$bin" "$bin"
    done
    assert_command_succeeds "valkey-server --version" valkey-server --version
    assert_command_succeeds "valkey-cli --version" valkey-cli --version

    # Version checks
    if [[ -n "$EXPECTED_VERSION" ]]; then
        local ver_bins=(valkey-server valkey-cli)
        for bin in "${ver_bins[@]}"; do
            local ver_output
            ver_output="$("$bin" --version 2>&1)" || true
            if [[ "$ver_output" == *"$EXPECTED_VERSION"* ]]; then
                pass "$bin version contains $EXPECTED_VERSION"
            else
                fail "$bin version contains $EXPECTED_VERSION (got: $ver_output)"
            fi
        done
    fi
}

test_user_group() {
    section_header "Test: User & Group"
    if id valkey &>/dev/null; then
        pass "valkey user exists"
    else
        fail "valkey user exists"
    fi

    if getent group valkey &>/dev/null; then
        pass "valkey group exists"
    else
        fail "valkey group exists"
    fi

    local home_dir
    home_dir="$(getent passwd valkey | cut -d: -f6)" || true
    if [[ "$home_dir" == "/var/lib/valkey" ]]; then
        pass "valkey home dir is /var/lib/valkey"
    else
        fail "valkey home dir is /var/lib/valkey (got: $home_dir)"
    fi
}

test_directories() {
    section_header "Test: Directories & Permissions"

    assert_dir_exists /var/lib/valkey
    assert_owner /var/lib/valkey "valkey:valkey"
    assert_perms /var/lib/valkey 750

    assert_dir_exists /var/log/valkey
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_owner /var/log/valkey "valkey:adm"
        assert_perms /var/log/valkey 2750
    else
        assert_owner /var/log/valkey "valkey:valkey"
        assert_perms /var/log/valkey 750
    fi

    assert_dir_exists /etc/valkey
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_owner /etc/valkey "valkey:valkey"
        assert_perms /etc/valkey 2770
    else
        assert_owner /etc/valkey "root:root"
        assert_perms /etc/valkey 755
    fi
}

test_config_files() {
    section_header "Test: Config Files"

    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_exists /etc/valkey/valkey.conf "valkey.conf"
        assert_owner /etc/valkey/valkey.conf "valkey:valkey" "valkey.conf"
        assert_perms /etc/valkey/valkey.conf 640 "valkey.conf"

        assert_file_exists /etc/valkey/sentinel.conf "sentinel.conf"
        assert_owner /etc/valkey/sentinel.conf "valkey:valkey" "sentinel.conf"
        assert_perms /etc/valkey/sentinel.conf 640 "sentinel.conf"
    else
        assert_file_exists /etc/valkey/default.conf "default.conf"
        assert_owner /etc/valkey/default.conf "root:valkey" "default.conf"
        assert_perms /etc/valkey/default.conf 640 "default.conf"

        assert_file_exists /etc/valkey/sentinel-default.conf "sentinel-default.conf"
        assert_owner /etc/valkey/sentinel-default.conf "root:valkey" "sentinel-default.conf"
        assert_perms /etc/valkey/sentinel-default.conf 660 "sentinel-default.conf"
    fi
}

test_systemd_unit_files() {
    section_header "Test: Systemd Unit Files"

    if ! has_systemd; then
        skip "systemd not available — skipping unit file tests"
        return
    fi

    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_exists /lib/systemd/system/valkey-server.service "valkey-server.service"
        assert_file_exists /lib/systemd/system/valkey-server@.service "valkey-server@.service (templated)"
        assert_file_exists /lib/systemd/system/valkey-sentinel.service "valkey-sentinel.service"
        assert_file_exists /lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service (templated)"
    else
        assert_file_exists /usr/lib/systemd/system/valkey@.service "valkey@.service"
        assert_file_exists /usr/lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service"
        assert_file_exists /usr/lib/systemd/system/valkey.target "valkey.target"
        assert_file_exists /usr/lib/systemd/system/valkey-sentinel.target "valkey-sentinel.target"
        assert_file_exists /usr/lib/tmpfiles.d/valkey.conf "tmpfiles.d/valkey.conf"
        if [[ -f /usr/lib/sysctl.d/00-valkey.conf ]]; then
            pass "sysctl.d/00-valkey.conf exists"
        elif [[ -f /etc/sysctl.d/00-valkey.conf ]]; then
            pass "sysctl.d/00-valkey.conf exists (in /etc)"
        else
            fail "sysctl.d/00-valkey.conf exists (not found in /usr/lib or /etc)"
        fi
    fi
}

test_systemd_service_hardening() {
    section_header "Test: Systemd Service Hardening"

    if ! has_systemd; then
        skip "systemd not available — skipping service hardening tests"
        return
    fi

    local server_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
    else
        server_service="valkey@default"
    fi

    # Detect systemd version for feature-gating
    local sd_ver
    sd_ver=$(systemctl --version 2>/dev/null | head -1 | awk '{print $2}')
    sd_ver=${sd_ver:-0}

    # Common properties (both deb and rpm)
    local common_props=(
        "Type:notify"
        "User:valkey"
        "Group:valkey"
        "PrivateTmp:yes"
        "ProtectHome:yes"
        "PrivateDevices:yes"
        "ProtectKernelTunables:yes"
        "ProtectKernelModules:yes"
        "ProtectControlGroups:yes"
        "NoNewPrivileges:yes"
        "RestrictNamespaces:yes"
        "RestrictSUIDSGID:yes"
        "RestrictRealtime:yes"
    )

    # ProtectHostname requires systemd >= 242
    if [[ "$sd_ver" -ge 242 ]]; then
        common_props+=("ProtectHostname:yes")
    else
        skip "ProtectHostname (systemd $sd_ver < 242)"
    fi

    # ProtectKernelLogs requires systemd >= 244
    if [[ "$sd_ver" -ge 244 ]]; then
        common_props+=("ProtectKernelLogs:yes")
    else
        skip "ProtectKernelLogs (systemd $sd_ver < 244)"
    fi

    # ProtectClock requires systemd >= 247
    if [[ "$sd_ver" -ge 247 ]]; then
        common_props+=("ProtectClock:yes")
    else
        skip "ProtectClock (systemd $sd_ver < 247)"
    fi

    for entry in "${common_props[@]}"; do
        local prop="${entry%%:*}" expected="${entry#*:}"
        assert_systemd_property "$server_service" "$prop" "$expected"
    done

    # Deb-specific properties
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_systemd_property "$server_service" "ProtectSystem" "strict"
        assert_systemd_property "$server_service" "LimitNOFILE" "65535"
        assert_systemd_property "$server_service" "LimitNOFILESoft" "65535"
        assert_systemd_property "$server_service" "MemoryDenyWriteExecute" "yes"
        assert_systemd_property "$server_service" "PrivateUsers" "yes"
        assert_systemd_property "$server_service" "LockPersonality" "yes"
        assert_systemd_property "$server_service" "Restart" "always"
    fi

    # RPM-specific properties
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_systemd_property "$server_service" "ProtectSystem" "full"
        assert_systemd_property "$server_service" "LimitNOFILE" "10240"
        assert_systemd_property "$server_service" "LimitNOFILESoft" "10240"
        assert_systemd_property "$server_service" "Restart" "on-failure"
    fi
}

test_systemd_enable_disable() {
    section_header "Test: Systemd Enable/Disable"

    if ! has_systemd; then
        skip "systemd not available — skipping enable/disable tests"
        return
    fi

    local server_service sentinel_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
        sentinel_service="valkey-sentinel"
    else
        server_service="valkey@default"
        sentinel_service="valkey-sentinel@default"
    fi

    for svc in "$server_service" "$sentinel_service"; do
        # Enable
        if systemctl enable "$svc" >/dev/null 2>&1; then
            pass "systemctl enable $svc"
        else
            fail "systemctl enable $svc"
        fi

        local state
        state="$(systemctl is-enabled "$svc" 2>/dev/null)" || true
        if [[ "$state" == "enabled" ]]; then
            pass "$svc is enabled"
        else
            fail "$svc is enabled (got: $state)"
        fi

        # Disable
        if systemctl disable "$svc" >/dev/null 2>&1; then
            pass "systemctl disable $svc"
        else
            fail "systemctl disable $svc"
        fi

        state="$(systemctl is-enabled "$svc" 2>/dev/null)" || true
        if [[ "$state" == "disabled" ]]; then
            pass "$svc is disabled"
        else
            fail "$svc is disabled (got: $state)"
        fi
    done
}

test_systemd_start_stop_restart() {
    section_header "Test: Systemd Start/Stop/Restart"

    if ! has_systemd; then
        skip "systemd not available — skipping start/stop/restart tests"
        return
    fi

    local server_service sentinel_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
        sentinel_service="valkey-sentinel"
    else
        server_service="valkey@default"
        sentinel_service="valkey-sentinel@default"
    fi

    for svc in "$server_service" "$sentinel_service"; do
        # Start
        if systemctl start "$svc" 2>&1; then
            pass "start $svc"
        else
            fail "start $svc"
            journalctl -u "$svc" --no-pager -n 20 2>&1 || true
            continue
        fi

        if wait_for_service "$svc" 15; then
            pass "$svc is active after start"
        else
            fail "$svc is active after start (timed out)"
            systemctl stop "$svc" 2>/dev/null || true
            continue
        fi

        # Get PID before restart
        local pid_before
        pid_before="$(systemctl show "$svc" --property=MainPID --value 2>/dev/null)" || true

        # Restart
        if systemctl restart "$svc" 2>&1; then
            pass "restart $svc"
        else
            fail "restart $svc"
            journalctl -u "$svc" --no-pager -n 20 2>&1 || true
            systemctl stop "$svc" 2>/dev/null || true
            continue
        fi

        if wait_for_service "$svc" 15; then
            pass "$svc is active after restart"
        else
            fail "$svc is active after restart (timed out)"
            systemctl stop "$svc" 2>/dev/null || true
            continue
        fi

        # Verify PID changed
        local pid_after
        pid_after="$(systemctl show "$svc" --property=MainPID --value 2>/dev/null)" || true
        if [[ -n "$pid_after" ]] && [[ "$pid_after" != "0" ]] && [[ "$pid_after" != "$pid_before" ]]; then
            pass "$svc PID changed after restart ($pid_before -> $pid_after)"
        else
            fail "$svc PID changed after restart (before=$pid_before after=$pid_after)"
        fi

        # Stop
        if systemctl stop "$svc" 2>&1; then
            pass "stop $svc"
        else
            fail "stop $svc"
        fi
        sleep 1

        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            pass "$svc is inactive after stop"
        else
            fail "$svc is inactive after stop (still active)"
        fi

        # Stop again — should be idempotent
        if systemctl stop "$svc" 2>&1; then
            pass "stop $svc (idempotent)"
        else
            fail "stop $svc (idempotent)"
        fi
    done
}

test_systemd_runtime_environment() {
    section_header "Test: Systemd Runtime Environment"

    if ! has_systemd; then
        skip "systemd not available — skipping runtime environment tests"
        return
    fi

    local server_service pid_file
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
        pid_file="/run/valkey/valkey-server.pid"
    else
        server_service="valkey@default"
        pid_file="/run/valkey/default.pid"
    fi

    echo "Starting $server_service..."
    if ! systemctl start "$server_service" 2>&1; then
        fail "start $server_service for runtime checks"
        journalctl -u "$server_service" --no-pager -n 20 2>&1 || true
        return
    fi

    if ! wait_for_service "$server_service" 15; then
        fail "$server_service active for runtime checks (timed out)"
        journalctl -u "$server_service" --no-pager -n 20 2>&1 || true
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi

    # Runtime directory
    assert_dir_exists /run/valkey "/run/valkey"

    # PID file
    if [[ -f "$pid_file" ]]; then
        pass "PID file exists: $pid_file"
    else
        fail "PID file exists: $pid_file"
    fi

    # Journal entries
    local journal_output
    journal_output="$(journalctl -u "$server_service" --no-pager -n 5 2>&1)" || true
    if [[ -n "$journal_output" ]]; then
        pass "journal has entries for $server_service"
    else
        fail "journal has entries for $server_service (empty output)"
    fi

    # Listening port
    if command -v ss &>/dev/null; then
        local ss_output
        ss_output="$(ss -tlnp 2>/dev/null)" || true
        if [[ "$ss_output" == *":6379 "* ]] || [[ "$ss_output" == *":6379"* ]]; then
            pass "listening on port 6379"
        else
            fail "listening on port 6379 (not found in ss output)"
        fi
    else
        skip "ss not available — skipping port check"
    fi

    echo "Stopping $server_service..."
    systemctl stop "$server_service" 2>/dev/null || true
    sleep 1
}

test_systemd_restart_on_failure() {
    section_header "Test: Systemd Restart on Failure"

    if ! has_systemd; then
        skip "systemd not available — skipping restart-on-failure tests"
        return
    fi

    local server_service
    if [[ "$OS_FAMILY" == "deb" ]]; then
        server_service="valkey-server"
    else
        server_service="valkey@default"
    fi

    echo "Starting $server_service..."
    if ! systemctl start "$server_service" 2>&1; then
        fail "start $server_service for restart test"
        journalctl -u "$server_service" --no-pager -n 20 2>&1 || true
        return
    fi

    if ! wait_for_service "$server_service" 15; then
        fail "$server_service active for restart test (timed out)"
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi

    # Get original PID and restart counter
    local old_pid restarts_before
    old_pid="$(systemctl show "$server_service" --property=MainPID --value 2>/dev/null)" || true
    if [[ -z "$old_pid" ]] || [[ "$old_pid" == "0" ]]; then
        fail "get MainPID for restart test (got: $old_pid)"
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi
    restarts_before="$(systemctl show "$server_service" --property=NRestarts --value 2>/dev/null)"
    restarts_before="${restarts_before:-0}"
    echo "Original PID: $old_pid (NRestarts=$restarts_before)"

    # Kill the main process to trigger the on-failure restart. Use SIGKILL: it
    # cannot be caught, so the process reliably dies. An external SIGSEGV is
    # unreliable here — valkey installs its own crash-signal handler, which can
    # catch an externally delivered signal and keep running, so no restart occurs.
    echo "Killing PID $old_pid (SIGKILL)..."
    kill -KILL "$old_pid" 2>/dev/null || true

    # Wait for service to restart
    sleep 2
    if wait_for_service "$server_service" 15; then
        pass "$server_service restarted after main process was killed"
    else
        fail "$server_service restarted after main process was killed (did not become active)"
        systemctl stop "$server_service" 2>/dev/null || true
        return
    fi

    # Verify systemd actually restarted it. NRestarts is the authoritative signal
    # (it increments on each on-failure restart); a changed MainPID is a secondary
    # check, since PID reuse can otherwise make a real restart look unchanged.
    local new_pid restarts_after
    new_pid="$(systemctl show "$server_service" --property=MainPID --value 2>/dev/null)" || true
    restarts_after="$(systemctl show "$server_service" --property=NRestarts --value 2>/dev/null)"
    restarts_after="${restarts_after:-0}"
    if [[ "$restarts_after" -gt "$restarts_before" ]] \
        || { [[ -n "$new_pid" ]] && [[ "$new_pid" != "0" ]] && [[ "$new_pid" != "$old_pid" ]]; }; then
        pass "$server_service restarted by systemd (NRestarts ${restarts_before}->${restarts_after}, PID ${old_pid}->${new_pid})"
    else
        fail "$server_service restarted by systemd (NRestarts ${restarts_before}->${restarts_after}, PID ${old_pid}->${new_pid})"
    fi

    echo "Stopping $server_service..."
    systemctl stop "$server_service" 2>/dev/null || true
    sleep 1
}

test_systemd_targets() {
    section_header "Test: Systemd Targets (RPM)"

    if [[ "$OS_FAMILY" != "rpm" ]]; then
        skip "not RPM — skipping target tests"
        return
    fi

    if ! has_systemd; then
        skip "systemd not available — skipping target tests"
        return
    fi

    local target_output
    target_output="$(systemctl list-unit-files valkey.target 2>/dev/null)" || true
    if [[ "$target_output" == *"valkey.target"* ]]; then
        pass "valkey.target is loaded"
    else
        fail "valkey.target is loaded (not found in unit files)"
    fi

    target_output="$(systemctl list-unit-files valkey-sentinel.target 2>/dev/null)" || true
    if [[ "$target_output" == *"valkey-sentinel.target"* ]]; then
        pass "valkey-sentinel.target is loaded"
    else
        fail "valkey-sentinel.target is loaded (not found in unit files)"
    fi
}

test_systemd_tmpfiles_sysctl() {
    section_header "Test: Systemd Tmpfiles & Sysctl (RPM)"

    if [[ "$OS_FAMILY" != "rpm" ]]; then
        skip "not RPM — skipping tmpfiles/sysctl tests"
        return
    fi

    # Tmpfiles config
    assert_file_exists /usr/lib/tmpfiles.d/valkey.conf "tmpfiles.d/valkey.conf"

    # Sysctl config
    if [[ -f /usr/lib/sysctl.d/00-valkey.conf ]]; then
        pass "sysctl.d/00-valkey.conf exists"
    elif [[ -f /etc/sysctl.d/00-valkey.conf ]]; then
        pass "sysctl.d/00-valkey.conf exists (in /etc)"
    else
        fail "sysctl.d/00-valkey.conf exists (not found)"
    fi

    # Check sysctl values — these cannot be set inside containers (shared with host)
    local somaxconn
    somaxconn="$(sysctl -n net.core.somaxconn 2>/dev/null)" || true
    if [[ -n "$somaxconn" ]] && [[ "$somaxconn" -ge 512 ]]; then
        pass "net.core.somaxconn >= 512 (value: $somaxconn)"
    elif [[ -n "$somaxconn" ]]; then
        skip "net.core.somaxconn not applied (got: $somaxconn, likely container)"
    else
        skip "cannot read net.core.somaxconn"
    fi

    local overcommit
    overcommit="$(sysctl -n vm.overcommit_memory 2>/dev/null)" || true
    if [[ "$overcommit" == "1" ]]; then
        pass "vm.overcommit_memory = 1"
    elif [[ -n "$overcommit" ]]; then
        skip "vm.overcommit_memory not applied (got: $overcommit, likely container)"
    else
        skip "cannot read vm.overcommit_memory"
    fi
}

test_valkey_server_service() {
    section_header "Test: Valkey Server Service"

    if ! has_systemd; then
        skip "systemd not available (not PID 1) — skipping service tests"
        return
    fi

    local service_name
    if [[ "$OS_FAMILY" == "deb" ]]; then
        service_name="valkey-server"
    else
        service_name="valkey@default"
    fi

    echo "Starting $service_name..."
    if ! systemctl start "$service_name" 2>&1; then
        fail "start $service_name"
        echo "--- journalctl output ---"
        journalctl -u "$service_name" --no-pager -n 30 2>&1 || true
        echo "---"
        return
    fi

    if wait_for_service "$service_name" 15; then
        pass "service $service_name is active"
    else
        fail "service $service_name is active (timed out after 15s)"
        journalctl -u "$service_name" --no-pager -n 20 2>&1 || true
        return
    fi

    # PING/PONG test
    local ping_result
    ping_result="$(valkey-cli PING 2>&1)" || true
    if [[ "$ping_result" == "PONG" ]]; then
        pass "valkey-cli PING → PONG"
    else
        fail "valkey-cli PING → PONG (got: $ping_result)"
    fi

    # SET/GET functional test
    valkey-cli SET __test_key__ "hello_valkey" >/dev/null 2>&1 || true
    local get_result
    get_result="$(valkey-cli GET __test_key__ 2>&1)" || true
    if [[ "$get_result" == "hello_valkey" ]]; then
        pass "valkey-cli SET/GET functional"
    else
        fail "valkey-cli SET/GET functional (got: $get_result)"
    fi
    valkey-cli DEL __test_key__ >/dev/null 2>&1 || true

    # Process runs as valkey user
    local proc_user
    proc_user="$(ps -o user= -C valkey-server 2>/dev/null | head -1 | tr -d ' ')" || true
    if [[ "$proc_user" == "valkey" ]]; then
        pass "valkey-server runs as valkey user"
    else
        fail "valkey-server runs as valkey user (got: '$proc_user')"
    fi

    # Stop service
    echo "Stopping $service_name..."
    systemctl stop "$service_name" 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pass "service $service_name stopped"
    else
        fail "service $service_name stopped (still active)"
    fi
}

test_valkey_sentinel_service() {
    section_header "Test: Valkey Sentinel Service"

    if ! has_systemd; then
        skip "systemd not available (not PID 1) — skipping sentinel service tests"
        return
    fi

    local service_name
    if [[ "$OS_FAMILY" == "deb" ]]; then
        service_name="valkey-sentinel"
    else
        service_name="valkey-sentinel@default"
    fi

    echo "Starting $service_name..."
    if ! systemctl start "$service_name" 2>&1; then
        fail "start $service_name"
        journalctl -u "$service_name" --no-pager -n 30 2>&1 || true
        return
    fi

    if wait_for_service "$service_name" 15; then
        pass "service $service_name is active"
    else
        fail "service $service_name is active (timed out after 15s)"
        journalctl -u "$service_name" --no-pager -n 20 2>&1 || true
        return
    fi

    # PING sentinel on port 26379
    local ping_result
    ping_result="$(valkey-cli -p 26379 PING 2>&1)" || true
    if [[ "$ping_result" == "PONG" ]]; then
        pass "valkey-cli -p 26379 PING → PONG"
    else
        fail "valkey-cli -p 26379 PING → PONG (got: $ping_result)"
    fi

    # Stop sentinel
    echo "Stopping $service_name..."
    systemctl stop "$service_name" 2>&1 || true
    sleep 1

    if ! systemctl is-active --quiet "$service_name" 2>/dev/null; then
        pass "service $service_name stopped"
    else
        fail "service $service_name stopped (still active)"
    fi
}

test_compat_redis() {
    section_header "Test: Redis Compatibility"

    local redis_bins=(redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel)
    for bin in "${redis_bins[@]}"; do
        assert_symlink "/usr/bin/$bin" "$bin"
    done

    assert_command_succeeds "redis-cli --version" redis-cli --version

    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_file_exists /usr/libexec/migrate_redis_to_valkey.bash "migrate_redis_to_valkey.bash"
    fi
}

test_dev_headers() {
    section_header "Test: Dev Headers"

    assert_file_exists /usr/include/valkeymodule.h "valkeymodule.h"
    assert_file_exists /usr/include/redismodule.h "redismodule.h"

    if [[ "$OS_FAMILY" == "rpm" ]]; then
        assert_file_exists /usr/lib/rpm/macros.d/macros.valkey "macros.valkey"
    fi
}

test_sbom() {
    section_header "Test: SBOM"

    local sbom_dir=/usr/share/percona-valkey/sbom
    assert_file_exists "$sbom_dir/percona-valkey.spdx.json" "SPDX SBOM"
    assert_file_exists "$sbom_dir/percona-valkey.cdx.json" "CycloneDX SBOM"

    if [[ -f "$sbom_dir/percona-valkey.spdx.json" ]] && grep -q '"spdxVersion"' "$sbom_dir/percona-valkey.spdx.json"; then
        pass "SPDX SBOM is a valid SBOM document"
    else
        fail "SPDX SBOM is a valid SBOM document"
    fi
    if [[ -f "$sbom_dir/percona-valkey.cdx.json" ]] && grep -q '"bomFormat"' "$sbom_dir/percona-valkey.cdx.json"; then
        pass "CycloneDX SBOM is a valid SBOM document"
    else
        fail "CycloneDX SBOM is a valid SBOM document"
    fi
}

test_logrotate() {
    section_header "Test: Logrotate"

    local found=0
    for f in /etc/logrotate.d/*valkey*; do
        if [[ -f "$f" ]]; then
            found=1
            pass "logrotate config exists: $f"
        fi
    done
    if [[ $found -eq 0 ]]; then
        fail "logrotate config exists in /etc/logrotate.d/"
    fi
}

test_clean_removal() {
    section_header "Test: Clean Removal"

    # Binaries should be gone
    local bins=(valkey-server valkey-cli valkey-benchmark valkey-check-aof valkey-check-rdb valkey-sentinel)
    for bin in "${bins[@]}"; do
        assert_file_not_exists "/usr/bin/$bin" "$bin"
    done

    # Redis compat symlinks should be gone
    local redis_bins=(redis-server redis-cli redis-benchmark redis-check-aof redis-check-rdb redis-sentinel)
    for bin in "${redis_bins[@]}"; do
        assert_file_not_exists "/usr/bin/$bin" "$bin"
    done

    # Headers should be gone
    assert_file_not_exists /usr/include/valkeymodule.h "valkeymodule.h"
    assert_file_not_exists /usr/include/redismodule.h "redismodule.h"

    # Systemd units should be gone
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_file_not_exists /lib/systemd/system/valkey-server.service "valkey-server.service"
        assert_file_not_exists /lib/systemd/system/valkey-sentinel.service "valkey-sentinel.service"
    else
        assert_file_not_exists /usr/lib/systemd/system/valkey@.service "valkey@.service"
        assert_file_not_exists /usr/lib/systemd/system/valkey-sentinel@.service "valkey-sentinel@.service"
    fi

    # Admin server, when this run installed it. The DEB purge branch in
    # debian/percona-valkey-admin-server.postrm is also responsible for the
    # operator data directory and the service user.
    if [[ "$ADMIN_WAS_INSTALLED" -eq 1 ]]; then
        assert_dir_not_exists /usr/lib/percona-valkey-admin-server "admin payload directory"
        if [[ "$OS_FAMILY" == "deb" ]]; then
            assert_file_not_exists /lib/systemd/system/valkey-admin.service "valkey-admin.service"
            assert_dir_not_exists /etc/valkey-admin "/etc/valkey-admin"
            assert_dir_not_exists /var/lib/valkey-admin "/var/lib/valkey-admin"
            if id valkey-admin >/dev/null 2>&1; then
                fail "purge removed the valkey-admin service user"
            else
                pass "purge removed the valkey-admin service user"
            fi
        else
            assert_file_not_exists /usr/lib/systemd/system/valkey-admin.service "valkey-admin.service"
        fi
    fi

    # Deb purge should remove data/config/log dirs
    if [[ "$OS_FAMILY" == "deb" ]]; then
        assert_dir_not_exists /var/lib/valkey "/var/lib/valkey"
        assert_dir_not_exists /var/log/valkey "/var/log/valkey"
        assert_dir_not_exists /etc/valkey "/etc/valkey"
    fi
}

###############################################################################
# JSON module (percona-valkey-json)
###############################################################################
test_json_module() {
    section_header "Test: JSON module (percona-valkey-json)"

    local module_dir module_path
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        module_dir="$(rpm --eval %{_libdir})/valkey/modules"
    else
        module_dir="/usr/lib/valkey/modules"
    fi
    module_path="${module_dir}/libjson.so"

    # Auto-skip when the JSON package is not part of this test run.
    if [[ ! -f "$module_path" ]]; then
        skip "percona-valkey-json not installed — skipping JSON module tests"
        return
    fi

    assert_file_exists "$module_path" "libjson.so installed in module dir"

    # Launch a throwaway server with the module loaded, independent of systemd
    # so this also works in minimal containers.
    local port=16399
    local datadir
    datadir="$(mktemp -d)"
    valkey-server --port "$port" --daemonize yes --loadmodule "$module_path" \
        --dir "$datadir" --logfile "$datadir/server.log" --save '' --appendonly no \
        >/dev/null 2>&1 || true

    local up=0 i
    for i in $(seq 1 15); do
        if [[ "$(valkey-cli -p "$port" PING 2>/dev/null)" == "PONG" ]]; then up=1; break; fi
        sleep 1
    done

    if [[ "$up" -ne 1 ]]; then
        fail "throwaway valkey-server with libjson.so started"
        tail -5 "$datadir/server.log" 2>/dev/null || true
        rm -rf "$datadir"
        return
    fi
    pass "valkey-server loaded libjson.so"

    assert_command_output_contains "MODULE LIST shows json" "json" \
        valkey-cli -p "$port" MODULE LIST

    # Functional JSON.* round-trip
    assert_command_output_contains "JSON.SET stores a document" "OK" \
        valkey-cli -p "$port" JSON.SET jsontest '$' '{"a":1,"b":[1,2,3]}'
    assert_command_output_contains "JSON.GET reads a path" "1" \
        valkey-cli -p "$port" JSON.GET jsontest '$.a'
    assert_command_output_contains "JSON.ARRLEN counts an array" "3" \
        valkey-cli -p "$port" JSON.ARRLEN jsontest '$.b'

    valkey-cli -p "$port" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    rm -rf "$datadir"
}

###############################################################################
# Audit module (percona-valkey-audit)
###############################################################################
test_audit_module() {
    section_header "Test: Audit module (percona-valkey-audit)"

    local module_dir module_path
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        module_dir="$(rpm --eval %{_libdir})/valkey/modules"
    else
        module_dir="/usr/lib/valkey/modules"
    fi
    module_path="${module_dir}/libvalkeyaudit.so"

    # Auto-skip when the audit package is not part of this test run.
    if [[ ! -f "$module_path" ]]; then
        skip "percona-valkey-audit not installed — skipping audit module tests"
        return
    fi

    assert_file_exists "$module_path" "libvalkeyaudit.so installed in module dir"
    assert_file_exists /etc/valkey/valkey.conf.d/valkey-audit.conf "valkey-audit.conf settings reference"

    # Launch a throwaway server with the module loaded, independent of systemd
    # so this also works in minimal containers.
    local port=16396
    local datadir
    datadir="$(mktemp -d)"
    valkey-server --port "$port" --daemonize yes --loadmodule "$module_path" \
        --dir "$datadir" --logfile "$datadir/server.log" --save '' --appendonly no \
        >/dev/null 2>&1 || true

    local up=0 i
    for i in $(seq 1 15); do
        if [[ "$(valkey-cli -p "$port" PING 2>/dev/null)" == "PONG" ]]; then up=1; break; fi
        sleep 1
    done

    if [[ "$up" -ne 1 ]]; then
        fail "throwaway valkey-server with libvalkeyaudit.so started"
        tail -5 "$datadir/server.log" 2>/dev/null || true
        rm -rf "$datadir"
        return
    fi
    pass "valkey-server loaded libvalkeyaudit.so"

    assert_command_output_contains "MODULE LIST shows audit" "audit" \
        valkey-cli -p "$port" MODULE LIST
    # The module logs "valkey-audit version: X" on load; the packages carry a
    # patch that marks 1.0.0 as GA, so it must not say -rcN.
    local verline
    verline="$(grep -o 'valkey-audit version: [^ ]*' "$datadir/server.log" 2>/dev/null | head -1)"
    if [[ -n "$verline" && "$verline" != *-rc* ]]; then
        pass "module reports a GA version (${verline#*: })"
    else
        fail "module reports a GA version (got: ${verline:-nothing logged})"
    fi

    # Functional check: a rejected command must land in the audit log. The
    # default command_result_mode (failures) logs those; switching it to "all"
    # only takes effect at module load, so successful commands are not probed.
    local audit_log="$datadir/audit.log"
    assert_command_output_contains "audit log redirected to the test dir" "OK" \
        valkey-cli -p "$port" CONFIG SET audit.protocol "file $audit_log"
    valkey-cli -p "$port" PKGTESTPROBE >/dev/null 2>&1 || true

    local logged=0
    for i in $(seq 1 10); do
        if grep -q PKGTESTPROBE "$audit_log" 2>/dev/null; then logged=1; break; fi
        sleep 1
    done
    if [[ "$logged" -eq 1 ]]; then
        pass "rejected command was written to the audit log"
    else
        fail "rejected command was written to the audit log"
        tail -5 "$audit_log" 2>/dev/null || true
    fi

    valkey-cli -p "$port" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    rm -rf "$datadir"
}

###############################################################################
# Bloom module (percona-valkey-bloom)
###############################################################################
test_bloom_module() {
    section_header "Test: Bloom module (percona-valkey-bloom)"

    local module_dir module_path
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        module_dir="$(rpm --eval %{_libdir})/valkey/modules"
    else
        module_dir="/usr/lib/valkey/modules"
    fi
    module_path="${module_dir}/libvalkey_bloom.so"

    # Auto-skip when the Bloom package is not part of this test run.
    if [[ ! -f "$module_path" ]]; then
        skip "percona-valkey-bloom not installed — skipping Bloom module tests"
        return
    fi

    assert_file_exists "$module_path" "libvalkey_bloom.so installed in module dir"

    local port=16398
    local datadir
    datadir="$(mktemp -d)"
    valkey-server --port "$port" --daemonize yes --loadmodule "$module_path" \
        --dir "$datadir" --logfile "$datadir/server.log" --save '' --appendonly no \
        >/dev/null 2>&1 || true

    local up=0 i
    for i in $(seq 1 15); do
        if [[ "$(valkey-cli -p "$port" PING 2>/dev/null)" == "PONG" ]]; then up=1; break; fi
        sleep 1
    done

    if [[ "$up" -ne 1 ]]; then
        fail "throwaway valkey-server with libvalkey_bloom.so started"
        tail -5 "$datadir/server.log" 2>/dev/null || true
        rm -rf "$datadir"
        return
    fi
    pass "valkey-server loaded libvalkey_bloom.so"

    assert_command_output_contains "MODULE LIST shows bf" "bf" \
        valkey-cli -p "$port" MODULE LIST

    # Functional BF.* round-trip
    assert_command_output_contains "BF.ADD adds an item" "1" \
        valkey-cli -p "$port" BF.ADD bloomtest item1
    assert_command_output_contains "BF.EXISTS finds the item" "1" \
        valkey-cli -p "$port" BF.EXISTS bloomtest item1

    valkey-cli -p "$port" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    rm -rf "$datadir"
}

###############################################################################
# Search module (percona-valkey-search)
###############################################################################
test_search_module() {
    section_header "Test: Search module (percona-valkey-search)"

    local module_dir module_path
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        module_dir="$(rpm --eval %{_libdir})/valkey/modules"
    else
        module_dir="/usr/lib/valkey/modules"
    fi
    module_path="${module_dir}/libsearch.so"

    # Auto-skip when the Search package is not part of this test run.
    if [[ ! -f "$module_path" ]]; then
        skip "percona-valkey-search not installed — skipping Search module tests"
        return
    fi

    assert_file_exists "$module_path" "libsearch.so installed in module dir"

    local port=16397
    local datadir
    datadir="$(mktemp -d)"
    valkey-server --port "$port" --daemonize yes --loadmodule "$module_path" \
        --dir "$datadir" --logfile "$datadir/server.log" --save '' --appendonly no \
        >/dev/null 2>&1 || true

    local up=0 i
    for i in $(seq 1 15); do
        if [[ "$(valkey-cli -p "$port" PING 2>/dev/null)" == "PONG" ]]; then up=1; break; fi
        sleep 1
    done

    if [[ "$up" -ne 1 ]]; then
        fail "throwaway valkey-server with libsearch.so started"
        tail -5 "$datadir/server.log" 2>/dev/null || true
        rm -rf "$datadir"
        return
    fi
    pass "valkey-server loaded libsearch.so"

    assert_command_output_contains "MODULE LIST shows search" "search" \
        valkey-cli -p "$port" MODULE LIST

    # Functional FT.* round-trip: create a vector index and list it.
    valkey-cli -p "$port" FT.CREATE smoketestidx ON HASH PREFIX 1 doc: \
        SCHEMA v VECTOR FLAT 6 TYPE FLOAT32 DIM 3 DISTANCE_METRIC L2 >/dev/null 2>&1 || true
    assert_command_output_contains "FT._LIST shows the created index" "smoketestidx" \
        valkey-cli -p "$port" FT._LIST

    valkey-cli -p "$port" SHUTDOWN NOSAVE >/dev/null 2>&1 || true
    rm -rf "$datadir"
}

###############################################################################
# Summary
###############################################################################
print_summary() {
    local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - START_TIME))
    local mins=$((duration / 60))
    local secs=$((duration % 60))
    local pass_pct=0
    if [[ $total -gt 0 ]]; then
        pass_pct=$(( (PASS_COUNT * 100) / total ))
    fi

    # Build pass-rate bar (20 chars wide)
    local bar_len=20
    local filled=$(( (PASS_COUNT * bar_len) / (total > 0 ? total : 1) ))
    local empty=$((bar_len - filled))
    local bar_fill="" bar_rest=""
    for ((i=0; i<filled; i++)); do bar_fill+="#"; done
    for ((i=0; i<empty;  i++)); do bar_rest+="-"; done

    printf "\n${BOLD}================================================================${RESET}\n"
    if [[ -n "$EXPECTED_VERSION" ]]; then
        printf "${BOLD}  Test Summary — Percona Valkey %s (%s)${RESET}\n" "$EXPECTED_VERSION" "$OS_FAMILY"
    else
        printf "${BOLD}  Test Summary — Percona Valkey (%s)${RESET}\n" "$OS_FAMILY"
    fi
    printf "${BOLD}================================================================${RESET}\n"

    # Packages tested
    printf "\n  ${CYAN}Packages tested:${RESET}\n"
    if [[ ${#INSTALLED_PKGS[@]} -gt 0 ]]; then
        for pkg in "${INSTALLED_PKGS[@]}"; do
            printf "    %-45s\n" "$pkg"
        done
    else
        printf "    (none captured)\n"
    fi

    # Results
    printf "\n  ${CYAN}Results:${RESET}\n"
    printf "    ${GREEN}PASS : %3d${RESET}\n" "$PASS_COUNT"
    printf "    ${RED}FAIL : %3d${RESET}\n" "$FAIL_COUNT"
    printf "    ${YELLOW}SKIP : %3d${RESET}\n" "$SKIP_COUNT"
    printf "    ─────────\n"
    printf "    Total: %3d\n" "$total"

    # Pass rate bar
    printf "\n  ${CYAN}Pass rate:${RESET} [${GREEN}%s${RESET}${RED}%s${RESET}] %d%%\n" \
        "$bar_fill" "$bar_rest" "$pass_pct"

    # Duration
    printf "  ${CYAN}Duration:${RESET}  %dm %02ds\n" "$mins" "$secs"

    # Failed tests detail
    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        printf "\n  ${RED}Failed tests:${RESET}\n"
        for t in "${FAILED_TESTS[@]}"; do
            printf "    ${RED}x${RESET} %s\n" "$t"
        done
    fi

    # Skipped tests detail
    if [[ ${#SKIPPED_TESTS[@]} -gt 0 ]]; then
        printf "\n  ${YELLOW}Skipped tests:${RESET}\n"
        for t in "${SKIPPED_TESTS[@]}"; do
            printf "    ${YELLOW}-${RESET} %s\n" "$t"
        done
    fi

    printf "\n${BOLD}================================================================${RESET}\n"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        printf "${RED}${BOLD}  RESULT: FAILED${RESET}\n"
        printf "${BOLD}================================================================${RESET}\n"
        return 1
    else
        printf "${GREEN}${BOLD}  RESULT: PASSED${RESET}\n"
        printf "${BOLD}================================================================${RESET}\n"
        return 0
    fi
}

test_bundle_meta() {
    section_header "Test: bundle meta-package (percona-valkey-bundle)"

    # Auto-skip when the bundle meta-package is not part of this run.
    local installed=0
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        rpm -q percona-valkey-bundle >/dev/null 2>&1 && installed=1
    else
        dpkg -s percona-valkey-bundle >/dev/null 2>&1 && installed=1
    fi
    if [[ "$installed" -ne 1 ]]; then
        skip "percona-valkey-bundle not installed — skipping bundle tests"
        return
    fi
    pass "percona-valkey-bundle is installed"

    local module_dir
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        module_dir="$(rpm --eval %{_libdir})/valkey/modules"
    else
        module_dir="/usr/lib/valkey/modules"
    fi

    # Installing the meta-package must have pulled in every module's .so.
    assert_file_exists "${module_dir}/libjson.so"         "json module pulled in by bundle"
    assert_file_exists "${module_dir}/libvalkey_bloom.so" "bloom module pulled in by bundle"
    assert_file_exists "${module_dir}/libsearch.so"       "search module pulled in by bundle"
    assert_file_exists "${module_dir}/libvalkey_ldap.so"  "ldap module pulled in by bundle"
}

###############################################################################
# Admin server (percona-valkey-admin-server)
###############################################################################
test_admin_server() {
    section_header "Test: admin server (percona-valkey-admin-server)"

    # Auto-skip when the admin server is not part of this run, carrying the
    # reason the install step recorded (see install_admin_from_repo).
    local installed=0
    if [[ "$OS_FAMILY" == "rpm" ]]; then
        rpm -q percona-valkey-admin-server >/dev/null 2>&1 && installed=1
    else
        dpkg -s percona-valkey-admin-server >/dev/null 2>&1 && installed=1
    fi
    if [[ "$installed" -ne 1 ]]; then
        skip "percona-valkey-admin-server not installed${ADMIN_SKIP_REASON:+ — $ADMIN_SKIP_REASON}"
        return
    fi
    ADMIN_WAS_INSTALLED=1
    pass "percona-valkey-admin-server is installed"

    local payload=/usr/lib/percona-valkey-admin-server
    local entry="$payload/apps/server/dist/index.cjs"
    assert_dir_exists  "$payload"               "admin payload directory"
    assert_file_exists "$entry"                 "admin server entrypoint"
    assert_dir_exists  "$payload/node_modules"  "bundled node_modules"
    assert_dir_exists  /usr/share/percona-valkey-admin-server/sbom "embedded SBOM directory"

    # The unit runs as the valkey-admin user under ProtectSystem=strict, so
    # these owners and modes are what let the service read its configuration
    # and write its data at all.
    local unit
    if [[ "$OS_FAMILY" == "deb" ]]; then
        unit=/lib/systemd/system/valkey-admin.service
    else
        unit=/usr/lib/systemd/system/valkey-admin.service
    fi
    assert_file_exists "$unit" "valkey-admin.service"
    assert_file_exists /etc/valkey-admin/valkey-admin.env "valkey-admin.env"
    assert_perms       /etc/valkey-admin/valkey-admin.env 640 "valkey-admin.env"
    assert_owner       /etc/valkey-admin/valkey-admin.env root:valkey-admin "valkey-admin.env"
    assert_dir_exists  /var/lib/valkey-admin "operator data directory"
    assert_perms       /var/lib/valkey-admin 750 "operator data directory"
    assert_owner       /var/lib/valkey-admin valkey-admin:valkey-admin "operator data directory"
    assert_command_succeeds "valkey-admin service user exists" id valkey-admin

    # The payload ships a prebuilt native addon. A runtime that satisfies the
    # dependency but cannot load it leaves the service crash-looping at start,
    # which no file-level check would catch.
    assert_command_succeeds "valkey-glide native addon loads under the installed node" \
        node -e "require('$payload/node_modules/@valkey/valkey-glide')"

    if has_systemd; then
        assert_command_succeeds "systemd can load valkey-admin.service" \
            systemctl cat valkey-admin.service
    fi

    # Functional: the real entrypoint, run as the real service user, serving
    # HTTP on a throwaway port with a throwaway DATA_DIR -- independent of
    # systemd so this also works in minimal containers, the same way the
    # module tests launch a throwaway valkey-server. Everything above can pass
    # on a payload that is complete but cannot actually start.
    local port=18080 datadir log status i
    datadir="$(mktemp -d)"
    log="$(mktemp)"
    chown valkey-admin:valkey-admin "$datadir"
    runuser -u valkey-admin -- env DEPLOYMENT_MODE=Web PORT="$port" DATA_DIR="$datadir" \
        node "$entry" >"$log" 2>&1 &
    local pid=$!

    status=""
    for i in $(seq 1 30); do
        status="$(node -e "
const http = require('http')
http.get({ host: '127.0.0.1', port: $port, path: '/' }, res => {
  console.log(res.statusCode)
  res.resume()
  process.exit(0)
}).on('error', () => process.exit(1))
" 2>/dev/null || true)"
        [[ -n "$status" ]] && break
        sleep 1
    done

    if [[ "$status" == "200" ]]; then
        pass "admin server serves HTTP 200 on / as the valkey-admin user"
    else
        fail "admin server serves HTTP 200 on / as the valkey-admin user (got: ${status:-no response})"
        sed -n '1,8p' "$log" | sed 's/^/        /'
    fi

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -rf "$datadir" "$log"
}

###############################################################################
# Main
###############################################################################
main() {
    # Parse arguments
    for arg in "$@"; do
        case "$arg" in
            --pkg-dir=*)
                PKG_DIR="${arg#*=}"
                INSTALL_MODE="pkg-dir"
                ;;
            --repo)
                INSTALL_MODE="repo"
                ;;
            --repo-channel=*)
                REPO_CHANNEL="${arg#*=}"
                ;;
            --version=*)
                EXPECTED_VERSION="${arg#*=}"
                ;;
            --help|-h)
                echo "Usage: $0 [--pkg-dir=DIR | --repo] [OPTIONS]"
                echo ""
                echo "Auto-detects OS, installs Percona Valkey packages, runs tests,"
                echo "removes packages, and verifies clean removal."
                echo ""
                echo "Install source (one required):"
                echo "  --pkg-dir=DIR           Directory containing .deb or .rpm packages"
                echo "  --repo                  Install from Percona repository"
                echo ""
                echo "Options:"
                echo "  --repo-channel=CHANNEL  Repo channel: testing (default), release, or experimental"
                echo "  --version=X.Y.Z         Expected Valkey version (auto-detected if omitted)"
                exit 0
                ;;
            *)
                echo "Unknown argument: $arg" >&2
                echo "Usage: $0 [--pkg-dir=DIR | --repo] [OPTIONS]" >&2
                exit 1
                ;;
        esac
    done

    START_TIME=$(date +%s)

    if [[ -z "$INSTALL_MODE" ]]; then
        echo "ERROR: either --pkg-dir or --repo is required" >&2
        echo "Usage: $0 [--pkg-dir=DIR | --repo] [OPTIONS]" >&2
        exit 1
    fi

    if [[ "$INSTALL_MODE" == "pkg-dir" ]]; then
        if [[ ! -d "$PKG_DIR" ]]; then
            echo "ERROR: Package directory does not exist: $PKG_DIR" >&2
            exit 1
        fi
        # Resolve to absolute path
        PKG_DIR="$(cd "$PKG_DIR" && pwd)"

        # Auto-detect version from package filenames if not provided
        if [[ -z "$EXPECTED_VERSION" ]]; then
            local pkg_file
            pkg_file="$(find "$PKG_DIR" -maxdepth 1 -name 'percona-valkey-server*' \( -name '*.deb' -o -name '*.rpm' \) | head -1)"
            if [[ -n "$pkg_file" ]]; then
                EXPECTED_VERSION="$(basename "$pkg_file" | grep -oP '[\._-]\K[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
            fi
        fi
        echo "Package directory: $PKG_DIR"
    else
        echo "Install mode: repo (channel=$REPO_CHANNEL)"
    fi

    if [[ -n "$EXPECTED_VERSION" ]]; then
        echo "Expected version: $EXPECTED_VERSION"
    fi
    detect_os

    # Install
    if [[ "$INSTALL_MODE" == "repo" ]]; then
        install_from_repo_"$OS_FAMILY"
    elif [[ "$OS_FAMILY" == "deb" ]]; then
        install_packages_deb
    else
        install_packages_rpm
    fi

    # Run tests — use set +e so individual failures don't abort
    set +e

    test_binaries
    test_user_group
    test_directories
    test_config_files
    test_systemd_unit_files
    test_systemd_service_hardening
    test_systemd_enable_disable
    test_systemd_start_stop_restart
    test_valkey_server_service
    test_valkey_sentinel_service
    test_systemd_runtime_environment
    test_systemd_restart_on_failure
    test_systemd_targets
    test_systemd_tmpfiles_sysctl
    test_compat_redis
    test_dev_headers
    test_logrotate
    test_sbom
    test_json_module
    test_audit_module
    test_bloom_module
    test_search_module
    test_bundle_meta
    test_admin_server

    # Stop any lingering services before removal
    if has_systemd; then
        if [[ "$OS_FAMILY" == "deb" ]]; then
            systemctl stop valkey-server valkey-sentinel 2>/dev/null || true
        else
            systemctl stop valkey@default valkey-sentinel@default 2>/dev/null || true
        fi
        sleep 1
    fi

    set -e

    # Remove
    if [[ "$OS_FAMILY" == "deb" ]]; then
        remove_packages_deb
    else
        remove_packages_rpm
    fi

    # Verify clean removal
    set +e
    test_clean_removal
    set -e

    # Summary
    print_summary
}

main "$@"
