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

and recommends:

| Package | Provides |
|---|---|
| `percona-valkey-admin-server` | the web administration interface, on `127.0.0.1:8080` |

Curated versions for 9.1 (from `valkey-io/valkey-bundle` `versions.json`):
server 9.1.3, json 1.0.3, bloom 1.0.1, search 1.2.1, ldap 1.1.1.
Audit 1.0.0 and admin 1.2.0 are Percona additions; upstream's bundle ships
neither.

### Why admin is recommended and not required

`percona-valkey-admin-server` is the only package in the set that needs a
language runtime: `nodejs (>= 20)` on DEB, `(nodejs >= 1:20 or nodejs22 >=
1:22)` on RPM. Most targets cannot satisfy that from their own archives —
bookworm ships Node 18, jammy 12, noble 18, and on EL8/EL9 modular filtering
hides every modular `nodejs` until a stream is enabled. A hard dependency
would therefore make `install percona-valkey-bundle` itself fail on those
targets. As a recommendation it is installed by default (both `apt` and `dnf`
honour weak dependencies out of the box) wherever the runtime resolves, and
quietly left out where it does not.

To install it where the runtime needs arranging first:

```bash
# EL8 / EL9
dnf module enable nodejs:22

# Debian / Ubuntu below Node 20
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
```

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
