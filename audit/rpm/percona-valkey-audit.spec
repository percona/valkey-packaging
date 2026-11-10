%global valkey_name        valkey
%global valkey_modules_dir %{_libdir}/%{valkey_name}/modules
%global valkey_modules_abi 1

Name:           percona-valkey-audit
Version:        1.0.0
Release:        4%{?dist}
Summary:        Audit logging module for Percona Valkey

License:        BSD-3-Clause
URL:            https://github.com/percona/valkey-audit
Source0:        percona-valkey-audit-%{version}.tar.gz
# Patches are kept in audit/debian/patches (shared with the DEB quilt series).
# Build as C11: CMake < 3.21 cannot enable C17 for GCC.
Patch0:         0001-build-use-C11-instead-of-C17.patch
# Report 1.0.0, not 1.0.0-rc1, in MODULE LIST / INFO.
Patch1:         0002-version-mark-1.0.0-as-GA.patch

BuildRequires:  gcc
# CMake's project() enables CXX by default, so a C++ compiler must be present.
BuildRequires:  gcc-c++
BuildRequires:  cmake >= 3.10
BuildRequires:  make
# Provides /usr/include/valkeymodule.h; building against the server's own header
# keeps the module ABI-aligned with the installed server.
BuildRequires:  percona-valkey-devel

# The module is loaded by the server, so it requires the server package (named
# "percona-valkey" on RPM) and the matching module ABI it provides.
Requires:       percona-valkey%{?_isa}
Requires:       valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

Provides:       valkey-audit = %{version}-%{release}
Obsoletes:      valkey-audit < %{version}-%{release}

%description
valkey-audit provides audit logging for Percona Valkey via the
libvalkeyaudit.so loadable module. It logs connections, authentication,
configuration changes, key operations and other commands to a file, syslog or
a TCP endpoint, in text, JSON or CSV format, with exclusion rules by user, IP
and command. The module is installed into the Valkey module directory; it is
not loaded automatically. Enable it with 'loadmodule' in valkey.conf or
'MODULE LOAD' at runtime.

%prep
%autosetup -p1 -n percona-valkey-audit-%{version}

%build
# Distro compiler/linker flags (incl. -g for the debuginfo package and the
# hardening flags), which plain cmake does not pick up on its own.
export CFLAGS="${CFLAGS:-%{optflags}}"
export LDFLAGS="${LDFLAGS:-%{?__global_ldflags}}"
# AUDIT_C_FLAGS_RELEASE replaces upstream's "-O3 -march=native" default, which
# would tie the binary to the build host's CPU. Passing CMAKE_C_FLAGS_RELEASE
# does not work: CMakeLists.txt overwrites it from AUDIT_C_FLAGS_RELEASE.
# VALKEY_AUDIT_TESTS=OFF skips the test suite and its googletest download.
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DAUDIT_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
    -DVALKEY_INCLUDE_DIR=%{_includedir} \
    -DVALKEY_AUDIT_TESTS=OFF
cmake --build build -j$(nproc)

%install
# The modules directory itself is owned by percona-valkey; this package only
# installs the module file into it.
install -d %{buildroot}%{valkey_modules_dir}
install -m 0755 build/libvalkeyaudit.so %{buildroot}%{valkey_modules_dir}/libvalkeyaudit.so

# Commented-out settings reference, at the path earlier packages used.
install -d %{buildroot}%{_sysconfdir}/%{valkey_name}/valkey.conf.d
sed -e 's|/usr/lib/valkey/modules|%{valkey_modules_dir}|g' valkey-audit.conf \
    > %{buildroot}%{_sysconfdir}/%{valkey_name}/valkey.conf.d/valkey-audit.conf
chmod 0644 %{buildroot}%{_sysconfdir}/%{valkey_name}/valkey.conf.d/valkey-audit.conf

# Embedded SBOM set (SPDX/CycloneDX json+xml, Syft table, license manifest),
# generated from the built tree by the shipped gen-module-sbom.sh. Syft is put on
# PATH by valkey_builder.sh --audit_deps; the script fails loudly if it is missing.
sh gen-module-sbom.sh %{name} %{version} %{buildroot}%{_datadir}/%{name}/sbom .

%files
%license LICENSE
%doc README.md README.packaging.md
%{valkey_modules_dir}/libvalkeyaudit.so
%dir %{_sysconfdir}/%{valkey_name}/valkey.conf.d
%config(noreplace) %{_sysconfdir}/%{valkey_name}/valkey.conf.d/valkey-audit.conf
%{_datadir}/%{name}/

%changelog
* Tue Nov 10 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.0.0-4
- Move packaging to valkey-packaging; build from percona/valkey-audit
- Build with portable CPU flags instead of -march=native
- Report version 1.0.0 instead of 1.0.0-rc1

* Mon May 25 2026 Martin Visser <mvisser@hotmail.com> - 1.0.0-1
- Bump to 1.0.0
- Updated for Valkey 9.1 compatibility

* Tue Mar 03 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 0.2.2-1
- Initial RPM packaging
