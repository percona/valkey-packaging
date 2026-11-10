#!/usr/bin/env bats

VARIANT="${VALKEY_VARIANT:-slim}"
VERSION="${VALKEY_VERSION:-9.1.3}"
MODULE_DIR=/usr/lib64/valkey/modules

@test 'the percona-valkey package is installed' {
    rpm -q percona-valkey
}

@test 'the installed version matches the requested version' {
    [ "$(rpm -q --queryformat '%{VERSION}' percona-valkey)" = "$VERSION" ]
}

@test 'the bundle package is installed only for the bundle variant' {
    if [ "$VARIANT" = "bundle" ]; then
        rpm -q percona-valkey-bundle
    else
        ! rpm -q percona-valkey-bundle
    fi
}

@test 'all five modules are present for the bundle variant' {
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no modules'
    rpm -q percona-valkey-json
    rpm -q percona-valkey-bloom
    rpm -q percona-valkey-search
    rpm -q percona-valkey-ldap
    rpm -q percona-valkey-audit
    [ "$(find "$MODULE_DIR" -maxdepth 1 -name '*.so' -type f | wc -l)" -ge 5 ]
}

@test 'the admin server is installed only for the bundle variant' {
    if [ "$VARIANT" = "bundle" ]; then
        rpm -q percona-valkey-admin-server
    else
        ! rpm -q percona-valkey-admin-server
    fi
}

@test 'the admin server payload, unit and user are in place' {
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no admin server'
    [ -f /usr/lib/percona-valkey-admin-server/apps/server/dist/index.cjs ]
    [ -f /usr/lib/systemd/system/valkey-admin.service ]
    getent passwd valkey-admin
    [ "$(stat -c '%U:%G' /etc/valkey-admin/valkey-admin.env)" = "root:valkey-admin" ]
    [ "$(stat -c '%a' /etc/valkey-admin/valkey-admin.env)" = "640" ]
}

@test 'the admin server has a node >= 20 to run on' {
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no admin server'
    major="$(node --version | sed 's/^v//; s/\..*//')"
    [ "$major" -ge 20 ]
}

@test 'the admin server is enabled' {
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no admin server'
    systemctl is-enabled valkey-admin.service
}

@test 'the admin server is left bound to loopback' {
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no admin server'
    ! grep -qE '^SERVER_BIND_HOST=' /etc/valkey-admin/valkey-admin.env
}

@test 'the admin connection is unset at bake time' {
    # The first-boot unit fills these in with the password it generates; an
    # image that already carried them would ship a known credential.
    [ "$VARIANT" = "bundle" ] || skip 'slim variant ships no admin server'
    ! grep -qE '^VALKEY_(HOST|PORT|PASSWORD)=' /etc/valkey-admin/valkey-admin.env
}

@test 'no modules are present for the slim variant' {
    [ "$VARIANT" = "slim" ] || skip 'bundle variant ships modules'
    [ "$(find "$MODULE_DIR" -maxdepth 1 -name '*.so' -type f 2>/dev/null | wc -l)" -eq 0 ]
}

@test 'the server, sentinel, and tools binaries are present' {
    command -v valkey-server
    command -v valkey-sentinel
    command -v valkey-cli
    command -v valkey-benchmark
    command -v valkey-check-aof
    command -v valkey-check-rdb
}

@test 'the valkey user and group exist' {
    getent passwd valkey
    getent group valkey
}

@test 'the default valkey instance is enabled' {
    systemctl is-enabled valkey@default.service
}

@test 'the sentinel instance is installed but not enabled' {
    [ -f /usr/lib/systemd/system/valkey-sentinel@.service ]
    ! systemctl is-enabled valkey-sentinel@default.service
}
