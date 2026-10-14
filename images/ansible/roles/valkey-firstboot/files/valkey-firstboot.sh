#!/bin/bash
set -euo pipefail

# Every path is overridable so the suite in test/unit can exercise this against a
# temporary directory instead of a live system.
ROOT="${VALKEY_FIRSTBOOT_ROOT:-}"
MEMINFO="${VALKEY_FIRSTBOOT_MEMINFO:-/proc/meminfo}"
MODULE_DIR="${VALKEY_FIRSTBOOT_MODULE_DIR:-/usr/lib64/valkey/modules}"
CONSOLE="${VALKEY_FIRSTBOOT_CONSOLE:-/dev/console}"
VARIANT="${VALKEY_VARIANT:-slim}"

CONF_DIR="${ROOT}/etc/valkey"
GENERATED_CONF="${CONF_DIR}/valkey-generated.conf"
ADMIN_ENV="${ROOT}/etc/valkey-admin/valkey-admin.env"
MARKER="${CONF_DIR}/.firstboot-done"
MOTD_DIR="${ROOT}/etc/motd.d"
MOTD_FILE="${MOTD_DIR}/30-valkey"

MAXMEMORY_PERCENT=70
PASSWORD_LENGTH=32

generate_password() {
    # Alphanumeric only: valkey.conf gives no special meaning to these characters,
    # so the value never needs quoting or escaping.
    #
    # Reading a fixed chunk before filtering keeps the producer from being killed
    # by SIGPIPE, which would otherwise trip pipefail. The filter discards roughly
    # three quarters of the bytes, so the loop covers a short first draw.
    local candidate=""
    while [ "${#candidate}" -lt "$PASSWORD_LENGTH" ]; do
        candidate+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
    done
    printf '%s' "${candidate:0:$PASSWORD_LENGTH}"
}

compute_maxmemory_bytes() {
    local total_kb
    total_kb=$(awk '/^MemTotal:/ { print $2 }' "$MEMINFO")
    echo $(( total_kb * 1024 * MAXMEMORY_PERCENT / 100 ))
}

discover_modules() {
    [ -d "$MODULE_DIR" ] || return 0
    find "$MODULE_DIR" -maxdepth 1 -type f -name '*.so' | sort
}

write_generated_conf() {
    local password="$1" maxmemory="$2"

    {
        echo "requirepass ${password}"
        echo "maxmemory ${maxmemory}"
        echo "maxmemory-policy noeviction"

        if [ "$VARIANT" = "bundle" ]; then
            while IFS= read -r module; do
                echo "loadmodule ${module}"
            done < <(discover_modules)
        fi
    } > "$GENERATED_CONF"

    chmod 0640 "$GENERATED_CONF"
    if [ -z "${VALKEY_FIRSTBOOT_SKIP_CHOWN:-}" ]; then
        # Matches the ownership the package gives default.conf: the server reads
        # its credentials but cannot rewrite them.
        chown root:valkey "$GENERATED_CONF"
    fi
}

valkey_port() {
    local port=""
    if [ -f "${CONF_DIR}/default.conf" ]; then
        port=$(awk '$1 == "port" { print $2; exit }' "${CONF_DIR}/default.conf")
    fi
    printf '%s' "${port:-6379}"
}

write_admin_env() {
    local password="$1" tmp

    # Only the bundle image installs the admin server, so the env file's
    # presence is the gate -- no variant check needed here.
    [ -f "$ADMIN_ENV" ] || return 0

    # The admin server takes a preconfigured connection from its environment.
    # Without these three the UI comes up with no instance to manage and the
    # operator has to paste the generated password in by hand. It is the same
    # secret that already sits in valkey-generated.conf and the login banner.
    #
    # The content is written back through the existing file rather than
    # replacing it, so the package's 0640 root:valkey-admin survives: the unit
    # runs as valkey-admin and reads this file, nothing else may.
    tmp=$(mktemp)
    grep -vE '^(VALKEY_HOST|VALKEY_PORT|VALKEY_PASSWORD)=' "$ADMIN_ENV" > "$tmp" || true
    {
        echo "VALKEY_HOST=127.0.0.1"
        echo "VALKEY_PORT=$(valkey_port)"
        echo "VALKEY_PASSWORD=${password}"
    } >> "$tmp"
    cat "$tmp" > "$ADMIN_ENV"
    rm -f "$tmp"
}

write_banner() {
    local password="$1" banner

    banner=$(cat <<EOF

+++++++++++++++++++++++++++ Percona Valkey +++++++++++++++++++++++++++

  A unique password was generated for this instance:

      ${password}

  Connect with:  valkey-cli -a '${password}'

  Valkey listens on localhost only. Review /etc/valkey/default.conf
  before exposing it, and change this password once setup is complete.
EOF
)

    if [ -f "$ADMIN_ENV" ]; then
        banner+=$(cat <<EOF


  The admin interface listens on 127.0.0.1:8080, already connected to this
  instance. Reach it over an SSH tunnel:

      ssh -L 8080:127.0.0.1:8080 <user>@<this host>
EOF
)
    fi

    banner+=$(cat <<EOF


+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

EOF
)

    mkdir -p "$MOTD_DIR"
    printf '%s\n' "$banner" > "$MOTD_FILE"
    chmod 0644 "$MOTD_FILE"

    # Reaching the console puts the password in the EC2 system log, which is the
    # only way to recover it when SSH access is not yet working.
    printf '%s\n' "$banner" > "$CONSOLE" 2>/dev/null || true
}

main() {
    if [ -e "$MARKER" ]; then
        return 0
    fi

    mkdir -p "$CONF_DIR"

    local password maxmemory
    password=$(generate_password)
    maxmemory=$(compute_maxmemory_bytes)

    write_generated_conf "$password" "$maxmemory"
    write_admin_env "$password"
    write_banner "$password"

    touch "$MARKER"
}

main "$@"
