%global valkey_name        valkey
%global valkey_modules_dir %{_libdir}/%{valkey_name}/modules
%global valkey_modules_abi 1

Name:           percona-valkey-json
Version:        1.0.3
Release:        1%{?dist}
Summary:        Native JSON data type module for Percona Valkey

License:        BSD-3-Clause
URL:            https://github.com/valkey-io/valkey-json
Source0:        percona-valkey-json-%{version}.tar.gz

BuildRequires:  gcc-c++
BuildRequires:  cmake >= 3.17
BuildRequires:  make
# Provides /usr/include/valkeymodule.h; building against the server's own header
# keeps the module ABI-aligned with the installed server (no valkey clone).
BuildRequires:  percona-valkey-devel

# The module is loaded by the server, so it requires the server package (named
# "percona-valkey" on RPM) and the matching module ABI it provides.
Requires:       percona-valkey%{?_isa}
Requires:       valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

%description
valkey-json provides native JSON support for Percona Valkey via the libjson.so
loadable module, implementing the JSON.* command family with JSONPath queries.
The module is installed into the Valkey module directory; it is not loaded
automatically. Enable it with 'loadmodule' in valkey.conf or 'MODULE LOAD' at
runtime.

%prep
%autosetup -p1 -n percona-valkey-json-%{version}

%build
# valkey-json compiles with -Wno-format (upstream CMakeLists), which cancels
# the distro's -Wformat and makes -Werror=format-security fail as
# "'-Wformat-security' ignored without '-Wformat'". Strip that one flag from
# the injected build flags (format hardening is moot when -Wformat is disabled).
export CFLAGS="$(echo "${CFLAGS-}" | sed -e 's/-Werror=format-security//g')"
export CXXFLAGS="$(echo "${CXXFLAGS-}" | sed -e 's/-Werror=format-security//g')"

# Fully offline release build: VALKEY_MODULE_H_PATH (supported upstream since
# valkey-json 1.0.3) makes CMake copy the system valkeymodule.h instead of
# cloning valkey-io/valkey, and
# the RapidJSON source-dir override uses the vendored copy instead of cloning it.
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_RELEASE=ON \
    -DENABLE_UNIT_TESTS=OFF \
    -DENABLE_INTEGRATION_TESTS=OFF \
    -DVALKEY_MODULE_H_PATH=%{_includedir}/%{valkey_name}module.h \
    -DFETCHCONTENT_SOURCE_DIR_RAPIDJSON=$(pwd)/deps/rapidjson
cmake --build build -j$(nproc)

%install
# The modules directory itself is owned by percona-valkey-server; this package
# only installs the module file into it.
install -d %{buildroot}%{valkey_modules_dir}
install -m 0755 build/src/libjson.so %{buildroot}%{valkey_modules_dir}/libjson.so

# Embedded SBOM set (SPDX/CycloneDX json+xml, Syft table, license manifest),
# generated from the built tree by the shipped gen-module-sbom.sh. Syft is put on
# PATH by valkey_builder.sh --json_deps; the script fails loudly if it is missing.
sh gen-module-sbom.sh %{name} %{version} %{buildroot}%{_datadir}/%{name}/sbom .

%files
%license LICENSE
%doc README.md README.packaging.md
%{valkey_modules_dir}/libjson.so
%{_datadir}/%{name}/

%changelog
* Tue Oct 27 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.0.3-1
- Update to upstream valkey-json 1.0.3

* Tue Sep 01 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 1.0.2-2
- Rebuild against Percona Valkey 9.1.2

* Wed Jun 24 2026 Percona Build <info@percona.com> - 1.0.2-1
- Initial percona-valkey-json package (upstream valkey-json 1.0.2)
