# percona-valkey-bundle

A meta-package that installs the **Percona Valkey server** together with **all
supported modules** in a single step. It mirrors the upstream
[`valkey-bundle`](https://github.com/valkey-io/valkey-bundle) curated set, as
OS packages (DEB/RPM) instead of a Docker image.

Installing `percona-valkey-bundle` pulls in:

| Package | Commands | Module |
|---|---|---|
| `percona-valkey` / `percona-valkey-server` | — | the Valkey server |
| `percona-valkey-json` | `JSON.*` | native JSON data type (`libjson.so`) |
| `percona-valkey-bloom` | `BF.*` | Bloom filters (`libvalkey_bloom.so`) |
| `percona-valkey-search` | `FT.*` | vector / full-text search (`libsearch.so`) |
| `percona-valkey-ldap` | — | LDAP authentication (`libvalkey_ldap.so`) |
| `percona-valkey-audit` | `AUDITUSERS` | audit logging (`libvalkeyaudit.so`) |

Curated versions for 9.1 (from `valkey-io/valkey-bundle` `versions.json`):
server 9.1.2, json 1.0.2, bloom 1.0.1, search 1.2.0, ldap 1.1.1.
Audit 1.0.0 is a Percona addition; upstream's bundle does not ship it.

## Install

```bash
# RPM (RHEL/Oracle/Amazon)
percona-release enable valkey-91 release   # or 'testing'
dnf install percona-valkey-bundle

# DEB (Debian/Ubuntu)
percona-release enable valkey-91 release
apt-get update && apt-get install percona-valkey-bundle
```

The meta-package itself ships **no files** — it only declares dependencies.

## Loading the modules

The modules are installed into the Valkey module directory
(`%{_libdir}/valkey/modules` on RPM, `/usr/lib/valkey/modules` on DEB) but are
**not loaded automatically**. Enable the ones you want, either in `valkey.conf`:

```
loadmodule /usr/lib64/valkey/modules/libjson.so
loadmodule /usr/lib64/valkey/modules/libvalkey_bloom.so
loadmodule /usr/lib64/valkey/modules/libsearch.so
loadmodule /usr/lib64/valkey/modules/libvalkey_ldap.so
loadmodule /usr/lib64/valkey/modules/libvalkeyaudit.so
```

or at runtime with `MODULE LOAD` (requires `enable-module-command yes`).

A Percona-branded **`percona-valkey-bundle` Docker image** (server + all modules,
auto-loaded by the entrypoint) is also produced from this repository under
`docker/`.
