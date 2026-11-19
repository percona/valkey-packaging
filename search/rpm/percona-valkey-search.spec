%global valkey_name        valkey
%global valkey_modules_dir %{_libdir}/%{valkey_name}/modules
%global valkey_modules_abi 1

# The module statically links gRPC/Protobuf/Abseil/ICU; the resulting debuginfo
# is huge and not useful for downstream, so skip the debug package.
%global debug_package %{nil}

Name:           percona-valkey-search
Version:        1.2.1
Release:        1%{?dist}
Summary:        Vector and full-text search module for Percona Valkey

License:        BSD-3-Clause
URL:            https://github.com/valkey-io/valkey-search
Source0:        percona-valkey-search-%{version}.tar.gz

BuildRequires:  cmake >= 3.16
BuildRequires:  make
BuildRequires:  git
BuildRequires:  autoconf
BuildRequires:  automake
BuildRequires:  libtool
BuildRequires:  pkgconfig
BuildRequires:  openssl-devel
BuildRequires:  systemd-devel
# A C++20 toolchain (g++ >= 12) is provided out-of-band by
# valkey_builder.sh --search_deps (gcc-toolset on RHEL), so it is not a
# BuildRequires; %build sources the toolset if present.

Requires:       percona-valkey%{?_isa}
Requires:       valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

%description
valkey-search provides a search index data type for Percona Valkey via the
libsearch.so loadable module (FT.CREATE, FT.SEARCH, FT.INFO, FT.AGGREGATE,
FT.DROPINDEX, ...), supporting vector similarity and full-text queries. The
module is installed into the Valkey module directory; it is not loaded
automatically. Enable it with 'loadmodule' in valkey.conf or 'MODULE LOAD'.

Note: this package compiles its dependencies (gRPC, Protobuf, Abseil, ICU,
highwayhash) from source at build time, which requires network access.

%prep
%autosetup -n percona-valkey-search-%{version}

%build
# Select a C++20 toolchain (g++ >= 12). RHEL 8/9 default gcc is < 12 and Amazon
# Linux 2023 ships gcc 11 by default, so --search_deps installs a newer one and
# we pick it here, in order:
#   1) a gcc-toolset (RHEL 8/9, via SCL enable script)
#   2) an Amazon Linux gccNN package (binaries named gccNN-g++/gccNN-gcc)
#   3) the system default (Oracle Linux 10 / Fedora already ship gcc >= 12)
if ls /opt/rh/gcc-toolset-*/enable >/dev/null 2>&1; then
    source "$(ls /opt/rh/gcc-toolset-*/enable | sort -V | tail -1)"
else
    for v in 14 13 12; do
        if command -v gcc${v}-g++ >/dev/null 2>&1; then
            export CC="gcc${v}-gcc" CXX="gcc${v}-g++"
            # The RPM build flags load the system annobin gcc plugin (and other
            # gcc-specific specs) built for the DEFAULT gcc. The alternate gcc${v}
            # (e.g. Amazon Linux gcc14) cannot load them, so the very first compile
            # fails with "C compiler cannot create executables". gcc-toolset ships
            # its own matching annobin, but a plain gccNN package does not — drop
            # the system-gcc -specs flags for this build.
            for _f in CFLAGS CXXFLAGS FFLAGS FCFLAGS LDFLAGS; do
                eval "_v=\${$_f:-}"
                _v="$(printf '%s' "$_v" | sed -E 's@-specs=/usr/lib/rpm/redhat/redhat-(annobin-cc1|hardened-cc1|hardened-ld)@@g')"
                eval "export $_f=\"\$_v\""
            done
            break
        fi
    done
fi
# build.sh builds ICU from source, FetchContent-builds gRPC/Protobuf/Abseil/
# highwayhash, then compiles the module -> .build-release/libsearch.so.
# Use the Unix Makefiles generator (make is always in base; avoids depending on
# ninja-build, which on RHEL lives in EPEL and isn't reliably available).
export CMAKE_GENERATOR="Unix Makefiles"
CMAKE_EXTRA_ARGS="-DBUILD_UNIT_TESTS=OFF" ./build.sh --jobs=%{?_smp_build_ncpus}%{!?_smp_build_ncpus:$(nproc)}

%install
install -d %{buildroot}%{valkey_modules_dir}
install -m 0755 .build-release/libsearch.so %{buildroot}%{valkey_modules_dir}/libsearch.so

# Embedded SBOM set (SPDX/CycloneDX json+xml, Syft table, license manifest),
# generated from the built tree by the shipped gen-module-sbom.sh. Crucially this
# runs AFTER build.sh, so .build-release/.deps (gRPC, Protobuf, Abseil, ICU,
# highwayhash) are cataloged — the statically-linked deps a source-only scan
# would miss. Syft is on PATH via valkey_builder.sh --search_deps; the script
# fails loudly if it is missing.
sh gen-module-sbom.sh %{name} %{version} %{buildroot}%{_datadir}/%{name}/sbom .

%files
%license LICENSE
%doc README.md README.packaging.md
%{valkey_modules_dir}/libsearch.so
%{_datadir}/%{name}/

%changelog
* Tue Oct 27 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.2.1-1
- Update to upstream valkey-search 1.2.1

* Tue Sep 01 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.2.0-2
- Rebuild against Percona Valkey 9.1.2

* Thu Jun 25 2026 Percona Build <info@percona.com> - 1.2.0-1
- Initial percona-valkey-search package (upstream valkey-search 1.2.0)
