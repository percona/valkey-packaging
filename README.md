# percona-valkey-packaging

OS packaging (DEB/RPM) for [Percona Valkey](https://valkey.io) — a Percona-branded distribution of the Valkey key-value store.

## Repository structure

```
valkey-packaging/
  scripts/
    valkey_builder.sh       # Main build driver (RPM & DEB)
    test_packages.sh        # Package validation test suite
    test_in_docker.sh       # Multi-OS Docker test runner
  debian/                   # Debian packaging (control, rules, patches, etc.)
  rpm/
    percona-valkey.spec     # Percona-branded RPM spec
    valkey.spec             # Upstream community RPM spec
```

## Prerequisites

Build dependencies can be installed automatically with the `--install_deps` flag (requires root), or manually:

**RPM-based systems (RHEL, Rocky, Oracle, Amazon Linux, Fedora, SUSE):**

```
rpm-build rpmdevtools gcc make wget tar gzip git
jemalloc-devel openssl-devel pkgconfig
python3 tcl procps-ng systemd-devel
```

**DEB-based systems (Debian, Ubuntu):**

```
build-essential debhelper devscripts dh-exec dpkg-dev fakeroot
libjemalloc-dev libssl-dev libsystemd-dev libhiredis-dev
liblua5.1-dev liblzf-dev pkg-config tcl tcl-dev openssl
```

## Building packages

All builds use `scripts/valkey_builder.sh`. A build directory (`--builddir`) is required and must differ from the current working directory.

### Full RPM build (on an RPM-based host)

```bash
mkdir -p /tmp/BUILD

scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_sources \
  --build_src_rpm \
  --build_rpm \
  --install_deps \
  --version=9.1.3 \
  --branch=9.1.3
```

Output RPMs are placed in `/tmp/BUILD/rpm/` and in the current directory under `rpm/`.
A Syft SBOM (SPDX + CycloneDX) of the Valkey source tree is generated at build time,
**embedded inside the package** under `/usr/share/percona-valkey/sbom/`, and also copied
to the `sbom/` output directory.

### Full DEB build (on a Debian/Ubuntu host)

```bash
mkdir -p /tmp/BUILD

scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_sources \
  --build_src_deb \
  --build_deb \
  --install_deps \
  --version=9.1.3 \
  --branch=9.1.3
```

Output .deb files are placed in `/tmp/BUILD/deb/` and in the current directory under `deb/`.
The same Syft SBOM (SPDX + CycloneDX) is **embedded inside `percona-valkey-server`** under
`/usr/share/percona-valkey/sbom/` and also copied to the `sbom/` output directory.

### Using local packaging scripts

By default the builder clones packaging scripts from GitHub. To use the `debian/` and `rpm/` directories from this repository instead:

```bash
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_sources \
  --build_rpm \
  --install_deps \
  --use_local_packaging_script
```

### percona-valkey-json (JSON module)

The [valkey-json](https://github.com/valkey-io/valkey-json) module (`libjson.so`)
is packaged separately from the server, with its own upstream version. It is
built through the same driver using the `*_json_*` flags:

```bash
# RPM (on an RPM-based host)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_json_sources \
  --build_json_src_rpm --build_json_rpm \
  --json_version=1.0.3

# DEB (on a Debian/Ubuntu host)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_json_sources \
  --build_json_src_deb --build_json_deb \
  --json_version=1.0.3
```

`--get_json_sources` clones valkey-json at the requested tag, vendors RapidJSON,
and produces a self-contained tarball. The module is compiled **offline** against
the system `valkeymodule.h` shipped by `percona-valkey-dev` / `percona-valkey-devel`
(a packaging patch replaces valkey-json's build-time clone of `valkey-io/valkey`),
so that package must be installed before the build. Output packages land in
`/tmp/BUILD/rpm/` or `/tmp/BUILD/deb/`. The resulting `percona-valkey-json` package
installs `libjson.so` into the Valkey module directory and depends on
`percona-valkey-server`; the module is **not** loaded automatically — enable it
with `loadmodule` in `valkey.conf` or `MODULE LOAD` at runtime.

### percona-valkey-audit (audit logging module)

The [valkey-audit](https://github.com/percona/valkey-audit) module
(`libvalkeyaudit.so`, a C module) is packaged the same way, with its own
upstream version, through the `*_audit_*` flags:

```bash
# RPM (on an RPM-based host)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --audit_deps \
  --get_audit_sources \
  --build_audit_src_rpm --build_audit_rpm \
  --release=4

# DEB (on a Debian/Ubuntu host)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --audit_deps \
  --get_audit_sources \
  --build_audit_src_deb --build_audit_deb \
  --release=4
```

Upstream has no `v1.0.0` tag yet, so `--audit_branch` defaults to a pinned
`main` commit (any branch, tag or commit works). `audit/debian/patches` carries
two fixes that ref still needs, shared by the RPM spec and the DEB quilt series:
building as C11 (CMake < 3.21 cannot enable C17) and reporting `1.0.0` instead
of `1.0.0-rc1`. Drop them once upstream tags a release that includes both.

The build passes `-DAUDIT_C_FLAGS_RELEASE="-O2 -DNDEBUG"`: upstream's default is
`-O3 -march=native`, which ties the binary to the build host's CPU, and
`-DCMAKE_C_FLAGS_RELEASE` does not override it. Packages up to `1.0.0-3` were
built from the module's own `packaging/` dir and carry that host-specific code,
so build with `--release=4` or higher so upgrades replace them.

The package installs `libvalkeyaudit.so` into the Valkey module directory and a
commented-out settings reference at `/etc/valkey/valkey.conf.d/valkey-audit.conf`,
and depends on `percona-valkey-server`. The module is **not** loaded
automatically.

### percona-valkey-bloom (Bloom filter module)

The [valkey-bloom](https://github.com/valkey-io/valkey-bloom) module
(`libvalkey_bloom.so`, a Rust module) is packaged the same way, with its own
upstream version:

```bash
# RPM (on an RPM-based host)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --bloom_deps \
  --get_bloom_sources \
  --build_bloom_src_rpm --build_bloom_rpm \
  --bloom_version=1.0.1

# DEB (on a Debian/Ubuntu host) — swap the build flags:
#   --build_bloom_src_deb --build_bloom_deb
```

`--bloom_deps` installs the build toolchain (Rust via rustup, plus `clang` for
the `valkey-module` crate's bindgen step). `--get_bloom_sources` clones
valkey-bloom and **vendors all cargo dependencies** into the tarball, so the
module compiles **offline** (`cargo build --release --offline`). No
`valkeymodule.h`/`percona-valkey-dev` is needed — the module links nothing
valkey-specific. The resulting `percona-valkey-bloom` package installs
`libvalkey_bloom.so` into the Valkey module directory and depends on
`percona-valkey-server`; it is **not** loaded automatically (`MODULE LIST`
shows `name=bf`; try `BF.ADD k x` / `BF.EXISTS k x`).

### percona-valkey-search (Search module)

The [valkey-search](https://github.com/valkey-io/valkey-search) module
(`libsearch.so`, vector / full-text search) is packaged the same way:

```bash
# RPM (on an RPM-based host)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --search_deps \
  --get_search_sources \
  --build_search_src_rpm --build_search_rpm \
  --search_version=1.2.1

# DEB (on a Debian/Ubuntu host) — swap the build flags:
#   --build_search_src_deb --build_search_deb
```

`--search_deps` installs cmake, make, autotools (for ICU), the openssl/systemd
headers, and a **C++20 toolchain (g++ ≥ 12)** — gcc-toolset on RHEL, `gcc14` on
Amazon Linux 2023, `g++-12` on Debian/Ubuntu. The build then runs upstream
`build.sh` (with the Unix Makefiles generator), which **compiles
gRPC, Protobuf, Abseil, highwayhash and ICU from source** and links the module
→ `libsearch.so` (this needs **build-time network access** and is a heavy,
long-running build). The resulting `percona-valkey-search` package installs
`libsearch.so` into the Valkey module directory and depends on
`percona-valkey-server`; it is **not** loaded automatically (`MODULE LIST`
shows `name=search`; try `FT.CREATE` / `FT._LIST` / `FT.SEARCH`).

> **Note:** valkey-search requires a C++20 compiler (g++ ≥ 12). On distros whose
> default gcc is older but a newer one is available, `--search_deps` installs it
> and `%build`/`rules` selects it: gcc-toolset on Oracle Linux 8/9, `gcc14` on
> Amazon Linux 2023, `g++-12` on Ubuntu jammy (bookworm/noble/trixie already
> default to ≥ 12).
>
> **Debian bullseye (11) is not supported for valkey-search** — it has no
> g++ ≥ 12 in base or backports (newest is g++-11) and its clang is < 16, so the
> module cannot be built there. The search build matrix therefore starts at
> Debian bookworm. `percona-valkey-json`, `percona-valkey-bloom`, and the server
> still build on bullseye.

### percona-valkey-bundle (meta-package — server + all modules)

`percona-valkey-bundle` is a **dependency-only meta-package** that installs the
Percona Valkey server together with every module (`json`, `bloom`, `search`,
`ldap`) in one step. It ships no files of its own — installing it pulls in the
whole stack. It has no upstream source to compile, so there are no `*_deps` /
`get_*_sources` clone steps; the build just assembles a tiny source tarball
(README + LICENSE) and packages the metadata.

```bash
# RPM (per-arch meta-package)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_bundle_sources \
  --build_bundle_src_rpm --build_bundle_rpm

# DEB (per-arch meta-package)
scripts/valkey_builder.sh \
  --builddir=/tmp/BUILD \
  --get_bundle_sources \
  --build_bundle_src_deb --build_bundle_deb
```

The resulting `percona-valkey-bundle` package depends on `percona-valkey`
(`percona-valkey-server` on DEB) plus `percona-valkey-json`,
`percona-valkey-bloom`, `percona-valkey-search`, and `percona-valkey-ldap`.
Versions track the curated set from `valkey-io/valkey-bundle` `versions.json`
(9.1: server 9.1.3, json 1.0.3, bloom 1.0.1, search 1.2.1, ldap 1.1.1). The
modules are still **not loaded automatically** — enable the ones you want with
`loadmodule` / `MODULE LOAD`.

> `percona-valkey-ldap` is built from its own repository
> (`EvgeniyPatlan/valkey-ldap`, `percona-packaging` branch); the bundle only
> declares the dependency.

A Percona-branded **bundle Docker image** is also provided
(`docker/Dockerfile.bundle` + `docker/bundle-docker-entrypoint.sh`): it installs
`percona-valkey-bundle` from the Percona repo, and its entrypoint
auto-discovers and `--loadmodule`s every module in the Valkey module directory.

```bash
docker build -f docker/Dockerfile.bundle -t percona-valkey-bundle:9.1.3 docker/
```

### Builder flags reference

| Flag | Description |
|------|-------------|
| `--builddir=DIR` | **Required.** Working directory for the build |
| `--get_sources` | Clone Valkey source from `--repo` at `--branch` |
| `--build_src_rpm` | Build source RPM |
| `--build_rpm` | Build binary RPMs (requires source RPM) |
| `--build_src_deb` | Build source DEB package |
| `--build_deb` | Build binary DEB packages (requires source DEB) |
| `--install_deps` | Install build dependencies (requires root) |
| `--version=VER` | Version string (default: `9.1.3`) |
| `--release=REL` | Release number (default: `1`) |
| `--branch=BRANCH` | Git branch/tag to check out (default: `9.1.3`) |
| `--repo=URL` | Source repository URL (default: `https://github.com/valkey-io/valkey.git`) |
| `--use_local_packaging_script` | Use `debian/` and `rpm/` from this repo instead of cloning |
| `--get_json_sources` | Clone valkey-json, vendor RapidJSON, build an offline source tarball |
| `--build_json_src_rpm` | Build the percona-valkey-json source RPM |
| `--build_json_rpm` | Build the percona-valkey-json binary RPM |
| `--build_json_src_deb` | Build the percona-valkey-json source DEB |
| `--build_json_deb` | Build the percona-valkey-json binary DEB |
| `--json_version=VER` | valkey-json version (default: `1.0.3`) |
| `--json_branch=REF` | valkey-json git ref (default: same as `--json_version`) |
| `--json_repo=URL` | valkey-json source repo (default: `https://github.com/valkey-io/valkey-json.git`) |
| `--audit_deps` | Install valkey-audit build deps (Percona repo, `percona-valkey-dev(el)`, cmake, gcc) |
| `--get_audit_sources` | Clone valkey-audit at `--audit_branch` and build a source tarball |
| `--build_audit_src_rpm` | Build the percona-valkey-audit source RPM |
| `--build_audit_rpm` | Build the percona-valkey-audit binary RPM |
| `--build_audit_src_deb` | Build the percona-valkey-audit source DEB |
| `--build_audit_deb` | Build the percona-valkey-audit binary DEB |
| `--audit_version=VER` | valkey-audit version (default: `1.0.0`) |
| `--audit_branch=REF` | valkey-audit git branch, tag or commit (default: a pinned upstream `main` commit) |
| `--audit_repo=URL` | valkey-audit source repo (default: `https://github.com/percona/valkey-audit.git`) |
| `--bloom_deps` | Install valkey-bloom build deps (Rust via rustup, clang) |
| `--get_bloom_sources` | Clone valkey-bloom, vendor cargo deps, build an offline source tarball |
| `--build_bloom_src_rpm` | Build the percona-valkey-bloom source RPM |
| `--build_bloom_rpm` | Build the percona-valkey-bloom binary RPM |
| `--build_bloom_src_deb` | Build the percona-valkey-bloom source DEB |
| `--build_bloom_deb` | Build the percona-valkey-bloom binary DEB |
| `--bloom_version=VER` | valkey-bloom version (default: `1.0.1`) |
| `--bloom_branch=REF` | valkey-bloom git ref (default: same as `--bloom_version`) |
| `--bloom_repo=URL` | valkey-bloom source repo (default: `https://github.com/valkey-io/valkey-bloom.git`) |
| `--search_deps` | Install valkey-search build deps (g++≥12 toolchain, cmake, ninja, autotools) |
| `--get_search_sources` | Clone valkey-search into a source tarball |
| `--build_search_src_rpm` | Build the percona-valkey-search source RPM |
| `--build_search_rpm` | Build the percona-valkey-search binary RPM |
| `--build_search_src_deb` | Build the percona-valkey-search source DEB |
| `--build_search_deb` | Build the percona-valkey-search binary DEB |
| `--search_version=VER` | valkey-search version (default: `1.2.1`) |
| `--search_branch=REF` | valkey-search git ref (default: same as `--search_version`) |
| `--search_repo=URL` | valkey-search source repo (default: `https://github.com/valkey-io/valkey-search.git`) |
| `--get_bundle_sources` | Assemble the percona-valkey-bundle meta-package source tarball |
| `--build_bundle_src_rpm` | Build the percona-valkey-bundle source RPM |
| `--build_bundle_rpm` | Build the percona-valkey-bundle binary RPM (per-arch meta) |
| `--build_bundle_src_deb` | Build the percona-valkey-bundle source DEB |
| `--build_bundle_deb` | Build the percona-valkey-bundle binary DEB (per-arch meta) |
| `--bundle_version=VER` | valkey-bundle version (default: `9.1.3`) |

## Testing packages

### `test_packages.sh` — single-host test suite

Runs on the current host. Auto-detects OS family (DEB vs RPM), installs packages, runs validation tests, removes packages, and verifies clean removal. Requires root.

**Test from locally built packages:**

```bash
sudo bash scripts/test_packages.sh --pkg-dir=/tmp/BUILD/deb
```

**Test from Percona repository:**

```bash
sudo bash scripts/test_packages.sh --repo --repo-channel=testing
```

**Test flags:**

| Flag | Description |
|------|-------------|
| `--pkg-dir=DIR` | Install from local .deb/.rpm files in DIR |
| `--repo` | Install from Percona repository |
| `--repo-channel=CHANNEL` | Repo channel: `testing` (default), `release`, or `experimental` |
| `--version=X.Y.Z` | Expected Valkey version (auto-detected from package filenames if omitted) |

**Test categories executed:**

- Binary installation (valkey-server, valkey-cli, valkey-sentinel, valkey-benchmark, valkey-check-aof, valkey-check-rdb)
- User/group creation (`valkey` user and group)
- Directory structure (`/var/lib/valkey`, `/var/log/valkey`, `/etc/valkey`, `/run/valkey`)
- Configuration files
- Systemd unit files and service hardening (ProtectSystem, PrivateTmp, NoNewPrivileges, etc.)
- Systemd enable/disable, start/stop/restart
- Valkey server functional tests (PING, SET/GET, CONFIG, INFO, persistence)
- Valkey sentinel functional tests
- Runtime environment (PID file, socket, process user)
- Restart-on-failure behavior
- Systemd targets and tmpfiles/sysctl
- Redis compatibility symlinks (`redis-cli`, `redis-server`, etc.)
- Development headers (`valkey/valkey-module.h`)
- Logrotate configuration
- Embedded SBOM (SPDX + CycloneDX under `/usr/share/percona-valkey/sbom/`)
- Clean removal verification

### `test_in_docker.sh` — multi-OS Docker test matrix

Launches systemd-enabled Docker containers, copies packages in, runs `test_packages.sh`, and reports a summary table.

**Single image, repo-based:**

```bash
scripts/test_in_docker.sh --repo --image=ubuntu:24.04
```

**Single image, local packages:**

```bash
scripts/test_in_docker.sh --pkg-dir=./build/deb --image=debian:bookworm
```

**Full matrix (all supported images):**

```bash
scripts/test_in_docker.sh --pkg-dir=./build/deb --all
```

**Run directly on host (no Docker):**

```bash
scripts/test_in_docker.sh --repo --no-docker
```

**Docker test flags:**

| Flag | Description |
|------|-------------|
| `--pkg-dir=DIR` | Install from local .deb/.rpm files in DIR |
| `--repo` | Install from Percona repository |
| `--repo-channel=CHANNEL` | Repo channel: `testing` (default), `release`, or `experimental` |
| `--image=IMAGE` | Run on a single Docker image (e.g. `ubuntu:24.04`) |
| `--all` | Run on all supported images matching the package type |
| `--no-docker` | Run `test_packages.sh` directly on the current host |
| `--version=X.Y.Z` | Expected Valkey version (passed to `test_packages.sh`) |
| `--keep` | Don't remove containers after run (useful for debugging) |

**Supported Docker images:**

| Family | Images |
|--------|--------|
| DEB | `ubuntu:24.04`, `debian:bookworm` |
| RPM | `rockylinux:9`, `oraclelinux:9`, `amazonlinux:2023` |

## Supported platforms

### DEB packages

| Distribution | Architectures |
|-------------|---------------|
| Ubuntu 24.04 (Noble) | x86_64, aarch64 |
| Debian 12 (Bookworm) | x86_64, aarch64 |

### RPM packages

| Distribution | Architectures |
|-------------|---------------|
| RHEL / Rocky / Alma 9 | x86_64, aarch64 |
| Oracle Linux 9 | x86_64, aarch64 |
| Amazon Linux 2023 | x86_64, aarch64 |
| Fedora (latest) | x86_64, aarch64 |
| openSUSE / SLES | x86_64, aarch64 |

### DEB packages produced

| Package | Description |
|---------|-------------|
| `percona-valkey-server` | Server binary and systemd units |
| `percona-valkey-sentinel` | Sentinel binary and systemd unit |
| `percona-valkey-tools` | CLI, benchmark, check-aof, check-rdb |
| `percona-valkey-dev` | Module development headers |
| `percona-valkey-compat-redis` | Redis compatibility symlinks |
| `percona-valkey-compat-redis-dev` | Redis compatibility dev headers |
| `percona-valkey-doc` | Documentation |

The JSON module is built and versioned independently (see
[percona-valkey-json](#percona-valkey-json-json-module) above) and produced for
both DEB and RPM:

| Package | Description |
|---------|-------------|
| `percona-valkey-json` | JSON data type module (`libjson.so`), loaded manually |
| `percona-valkey-audit` | Audit logging module (`libvalkeyaudit.so`), loaded manually |
| `percona-valkey-bloom` | Bloom filter module (`libvalkey_bloom.so`), loaded manually |
| `percona-valkey-search` | Vector/full-text search module (`libsearch.so`), loaded manually |

## License

Valkey is released under the [BSD 3-Clause License](https://github.com/valkey-io/valkey/blob/unstable/LICENSE.txt).
