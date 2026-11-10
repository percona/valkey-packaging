# percona-valkey-audit

This package installs the Valkey audit module shared object:

    /usr/lib64/valkey/modules/libvalkeyaudit.so   (RPM)
    /usr/lib/valkey/modules/libvalkeyaudit.so     (DEB)

and a commented-out reference of its settings:

    /etc/valkey/valkey.conf.d/valkey-audit.conf

The module is **not loaded automatically.** Enable it one of two ways:

1. Persistently, in `/etc/valkey/valkey.conf`:

       loadmodule /usr/lib64/valkey/modules/libvalkeyaudit.so   # adjust path on DEB

   Settings go on the same line (`loadmodule <path> audit.protocol file ...`)
   or as `audit.*` lines; see `valkey-audit.conf` for the list. Then restart the
   server: `systemctl restart valkey`

2. At runtime, via the CLI:

       valkey-cli MODULE LOAD /usr/lib64/valkey/modules/libvalkeyaudit.so

Verify with `valkey-cli MODULE LIST` (look for `name=audit`).

Upstream: https://github.com/percona/valkey-audit
