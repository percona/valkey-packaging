#!/usr/bin/env bats

SCRIPT="${BATS_TEST_DIRNAME}/../../ansible/roles/valkey-firstboot/files/valkey-firstboot.sh"

setup() {
    export VALKEY_FIRSTBOOT_ROOT="$BATS_TEST_TMPDIR/root"
    export VALKEY_FIRSTBOOT_MEMINFO="$BATS_TEST_TMPDIR/meminfo"
    export VALKEY_FIRSTBOOT_MODULE_DIR="$BATS_TEST_TMPDIR/modules"
    export VALKEY_FIRSTBOOT_CONSOLE="$BATS_TEST_TMPDIR/console"
    export VALKEY_FIRSTBOOT_SKIP_CHOWN=1
    mkdir -p "$VALKEY_FIRSTBOOT_ROOT/etc/valkey" "$VALKEY_FIRSTBOOT_MODULE_DIR"
    printf 'MemTotal:       16384000 kB\n' > "$VALKEY_FIRSTBOOT_MEMINFO"
    GENERATED="$VALKEY_FIRSTBOOT_ROOT/etc/valkey/valkey-generated.conf"
    MARKER="$VALKEY_FIRSTBOOT_ROOT/etc/valkey/.firstboot-done"
    MOTD="$VALKEY_FIRSTBOOT_ROOT/etc/motd.d/30-valkey"
    ADMIN_ENV="$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin/valkey-admin.env"
}

@test 'generates a 32 character alphanumeric password' {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    password=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    [ "${#password}" -eq 32 ]
    [[ "$password" =~ ^[A-Za-z0-9]+$ ]]
}

@test 'generates a different password on a clean run' {
    run "$SCRIPT"
    first=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    rm -rf "$VALKEY_FIRSTBOOT_ROOT/etc/valkey"
    mkdir -p "$VALKEY_FIRSTBOOT_ROOT/etc/valkey"
    run "$SCRIPT"
    second=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    [ "$first" != "$second" ]
}

@test 'sets maxmemory to 70 percent of MemTotal' {
    run "$SCRIPT"
    # 16384000 kB * 1024 * 70 / 100
    [ "$(grep '^maxmemory ' "$GENERATED" | cut -d' ' -f2)" -eq 11744051200 ]
}

@test 'sets the eviction policy to noeviction' {
    run "$SCRIPT"
    grep -qx 'maxmemory-policy noeviction' "$GENERATED"
}

@test 'writes no loadmodule lines for the slim variant' {
    touch "$VALKEY_FIRSTBOOT_MODULE_DIR/libjson.so"
    export VALKEY_VARIANT=slim
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    grep -q '^requirepass ' "$GENERATED"
    ! grep -q '^loadmodule ' "$GENERATED"
}

@test 'writes one loadmodule line per module for the bundle variant' {
    touch "$VALKEY_FIRSTBOOT_MODULE_DIR"/{libjson.so,libvalkey_bloom.so,libsearch.so}
    export VALKEY_VARIANT=bundle
    run "$SCRIPT"
    [ "$(grep -c '^loadmodule ' "$GENERATED")" -eq 3 ]
    grep -q "^loadmodule $VALKEY_FIRSTBOOT_MODULE_DIR/libjson.so$" "$GENERATED"
}

@test 'ignores non-module files in the module directory' {
    touch "$VALKEY_FIRSTBOOT_MODULE_DIR"/{libjson.so,README.txt}
    export VALKEY_VARIANT=bundle
    run "$SCRIPT"
    [ "$(grep -c '^loadmodule ' "$GENERATED")" -eq 1 ]
}

@test 'tolerates a missing module directory' {
    rmdir "$VALKEY_FIRSTBOOT_MODULE_DIR"
    export VALKEY_VARIANT=bundle
    run "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test 'creates the completion marker' {
    run "$SCRIPT"
    [ -e "$MARKER" ]
}

@test 'is a no-op when the marker exists' {
    run "$SCRIPT"
    first=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)" = "$first" ]
}

@test 'writes the password to the console and the motd' {
    run "$SCRIPT"
    password=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    grep -q "$password" "$VALKEY_FIRSTBOOT_CONSOLE"
    grep -q "$password" "$MOTD"
}

@test 'fills in the admin connection when the admin server is installed' {
    install -d -m0750 "$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin"
    printf 'DEPLOYMENT_MODE=Web\nPORT=8080\n' > "$ADMIN_ENV"
    chmod 0640 "$ADMIN_ENV"
    printf 'port 6379\n' > "$VALKEY_FIRSTBOOT_ROOT/etc/valkey/default.conf"

    run "$SCRIPT"
    [ "$status" -eq 0 ]
    password=$(grep '^requirepass ' "$GENERATED" | cut -d' ' -f2)
    grep -qx 'VALKEY_HOST=127.0.0.1' "$ADMIN_ENV"
    grep -qx 'VALKEY_PORT=6379' "$ADMIN_ENV"
    grep -qx "VALKEY_PASSWORD=${password}" "$ADMIN_ENV"
    # The settings the package shipped must survive.
    grep -qx 'DEPLOYMENT_MODE=Web' "$ADMIN_ENV"
    grep -qx 'PORT=8080' "$ADMIN_ENV"
}

@test 'takes the admin connection port from the server configuration' {
    install -d -m0750 "$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin"
    printf 'PORT=8080\n' > "$ADMIN_ENV"
    printf 'port 6380\n' > "$VALKEY_FIRSTBOOT_ROOT/etc/valkey/default.conf"

    run "$SCRIPT"
    grep -qx 'VALKEY_PORT=6380' "$ADMIN_ENV"
}

@test 'defaults the admin connection port when the configuration has none' {
    install -d -m0750 "$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin"
    printf 'PORT=8080\n' > "$ADMIN_ENV"

    run "$SCRIPT"
    grep -qx 'VALKEY_PORT=6379' "$ADMIN_ENV"
}

@test 'keeps the admin env file at mode 0640 while writing to it' {
    install -d -m0750 "$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin"
    printf 'PORT=8080\n' > "$ADMIN_ENV"
    chmod 0640 "$ADMIN_ENV"

    run "$SCRIPT"
    # Both halves matter: writing through a temporary file and moving it into
    # place would leave the operator password readable at 0600 root-only (the
    # unit could not read it) or 0644 (anyone could).
    grep -q '^VALKEY_PASSWORD=' "$ADMIN_ENV"
    [ "$(stat -c '%a' "$ADMIN_ENV")" = "640" ]
}

@test 'writes each admin connection setting exactly once on a rerun' {
    install -d -m0750 "$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin"
    printf 'PORT=8080\nVALKEY_HOST=10.0.0.1\nVALKEY_PASSWORD=stale\n' > "$ADMIN_ENV"

    run "$SCRIPT"
    [ "$(grep -c '^VALKEY_HOST=' "$ADMIN_ENV")" -eq 1 ]
    [ "$(grep -c '^VALKEY_PASSWORD=' "$ADMIN_ENV")" -eq 1 ]
    ! grep -q '^VALKEY_HOST=10.0.0.1$' "$ADMIN_ENV"
    ! grep -q '^VALKEY_PASSWORD=stale$' "$ADMIN_ENV"
}

@test 'leaves no admin env behind when the admin server is not installed' {
    run "$SCRIPT"
    [ "$status" -eq 0 ]
    [ ! -e "$ADMIN_ENV" ]
    ! grep -q 'admin interface' "$MOTD"
}

@test 'mentions the admin interface in the banner only when it is installed' {
    install -d -m0750 "$VALKEY_FIRSTBOOT_ROOT/etc/valkey-admin"
    printf 'PORT=8080\n' > "$ADMIN_ENV"

    run "$SCRIPT"
    grep -q 'admin interface listens on 127.0.0.1:8080' "$MOTD"
    grep -q 'admin interface listens on 127.0.0.1:8080' "$VALKEY_FIRSTBOOT_CONSOLE"
}

@test 'restricts the generated configuration to mode 0640' {
    run "$SCRIPT"
    [ "$(stat -c '%a' "$GENERATED")" = "640" ]
}
