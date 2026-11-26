%if 0%{?suse_version}
%global is_suse 1
%global is_rhel 0
%else
%global is_suse 0
%global is_rhel 1
%endif

%if 0%{?rhel} || 0%{?el8} || 0%{?el9} || 0%{?el10}
%global rhel_version %{?rhel}%{?el8:8}%{?el9:9}%{?el10:10}
%endif

%if 0%{?amzn}
%global is_amazon 1
%else
%global is_amazon 0
%endif

%global valkey_name valkey

%if 0%{?is_suse}
%bcond_without docs
%else
%bcond_with docs
%endif

%bcond_with tests

# Build the Lua scripting engine as a dlopen'd shared module
# (libvalkeylua.so), new in Valkey 9.1. OFF by default: the upstream
# default statically links Lua into valkey-server. Enable with:
#   rpmbuild --with lua_module
%bcond_with lua_module

%if %{with lua_module}
%global lua_module_build_flag BUILD_LUA=module
%endif

%define _data_dir       %{_localstatedir}/lib/%{valkey_name}
%define _log_dir        %{_localstatedir}/log/%{valkey_name}
%define _conf_dir       %{_sysconfdir}/%{valkey_name}

%global valkey_modules_abi 1
%global valkey_modules_dir %{_libdir}/%{valkey_name}/modules

%if %{with docs}
# valkey-io/valkey-doc has no 9.2 tag yet (9.1.2 is its newest), so the docs
# subpackage -- built only on SUSE -- stays on the last published release.
# Drop the pin and go back to %%{version} once valkey-doc tags 9.2.
%global doc_version 9.1.2
%endif

# Zstandard streaming compression, new in Valkey 9.2 (BUILD_ZSTD=yes).
# Upstream links libzstd *statically* because it uses zstd's
# static-linking-only custom allocator API for memory accounting, and
# requires >= 1.4.7. EL ships no static libzstd at all -- not in
# BaseOS/AppStream, not in CRB/PowerTools, not in EPEL -- and EL8's libzstd
# is 1.4.4, below the floor. So on EL a pinned upstream release is built
# statically and bundled; every other distro uses its own static package.
# Amazon Linux 2023 leaves %%{rhel} unset and ships libzstd-static 1.5.5,
# so it takes the system path.
%if 0%{?rhel}
%bcond_without bundled_zstd
%else
%bcond_with bundled_zstd
%endif
%global zstd_version 1.5.7
%global zstd_sha256 eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3

%if %{with bundled_zstd}
%global zstd_build_flag BUILD_ZSTD=yes ZSTD_PREFIX="$PWD/zstd-root"
%else
%global zstd_build_flag BUILD_ZSTD=yes
%endif

%global build_flags \\\
    DEBUG="" \\\
    V=1 \\\
    BUILD_WITH_SYSTEMD=yes \\\
    BUILD_TLS=yes \\\
    %{zstd_build_flag} \\\
    %{?lua_module_build_flag} \\\
    USE_SYSTEM_JEMALLOC=yes \\\
    PREFIX=%{_prefix}

# INSTALL_LIB targets the arch libdir (e.g. /usr/lib64 on x86_64) so that
# libvalkeylua.so lands in the proper location. The build-time RPATH baked
# into the binaries via upstream's FINAL_LDFLAGS gets stripped at the end
# of the install section with chrpath -d.
%global install_flags \\\
    %{build_flags} \\\
    INSTALL_BIN=%{buildroot}%{_bindir} \\\
    INSTALL_LIB=%{buildroot}%{_libdir}

Name:           percona-valkey
Version:        9.2.1
Release:        1%{?dist}
Summary:        Persistent key-value database

# valkey: BSD-3-Clause
# libvalkey: BSD-3-Clause
# hdrhistogram, linenoise, lz4: BSD-2-Clause
# lua: MIT
# fpconv: BSL-1.0
# zstd (bundled on EL only): BSD-3-Clause OR GPL-2.0-only, used under BSD-3-Clause
License:        BSD-3-Clause AND BSD-2-Clause AND MIT AND BSL-1.0
URL:            https://valkey.io

Source0:        https://github.com/valkey-io/%{valkey_name}/archive/%{version}/%{valkey_name}-%{version}.tar.gz
Source1:        %{valkey_name}.logrotate
Source2:        %{valkey_name}.target
Source3:        %{valkey_name}@.service
Source4:        %{valkey_name}.tmpfiles.d
Source5:        %{valkey_name}.sysctl
Source6:        %{valkey_name}-sentinel@.service
Source7:        %{valkey_name}-sentinel.target
Source8:        %{valkey_name}-user.conf
Source9:        macros.%{valkey_name}
Source10:       migrate_redis_to_valkey.bash
Source11:       README.SUSE
Source12:       README.RHEL
%if %{with docs}
Source50:       https://github.com/valkey-io/%{valkey_name}-doc/archive/%{doc_version}/%{valkey_name}-doc-%{doc_version}.tar.gz
%endif

%if %{with bundled_zstd}
Source60:       https://github.com/facebook/zstd/releases/download/v%{zstd_version}/zstd-%{zstd_version}.tar.gz
%endif

Patch1001:      %{valkey_name}-conf.patch

BuildRequires:  make
BuildRequires:  gcc

%if 0%{?is_suse}
BuildRequires:  procps
%else
BuildRequires:  procps-ng
%endif
BuildRequires:  tcl
BuildRequires:  openssl
# Used to strip the build-time RPATH that upstream 9.1+ bakes into binaries
# via -Wl,-rpath,$(PREFIX)/lib:$(current_dir)/modules/lua. Without this the
# binaries leak both PREFIX and the source build directory into the ELF
# .dynamic section, tripping check-buildroot and lintian rpath warnings.
# Only needed when the Lua shared module is built (--with lua_module):
# upstream injects the rpath only in BUILD_LUA=module mode.
%if %{with lua_module}
BuildRequires:  chrpath
%endif

%if 0%{?is_suse}
BuildRequires:  jemalloc-devel
BuildRequires:  libopenssl-devel >= 1.1.1
BuildRequires:  pkgconfig
BuildRequires:  python3
BuildRequires:  sysuser-shadow
BuildRequires:  sysuser-tools
BuildRequires:  pkgconfig(libsystemd)
BuildRequires:  pkgconfig(systemd)
%else
BuildRequires:  jemalloc-devel
BuildRequires:  pkgconfig
BuildRequires:  python3
BuildRequires:  systemd-devel
%if 0%{?rhel_version} >= 8 || 0%{?is_amazon}
BuildRequires:  systemd-rpm-macros
%endif
%if 0%{?rhel_version} >= 9 || 0%{?is_amazon}
BuildRequires:  openssl-devel >= 3.0.0
%else
BuildRequires:  openssl-devel >= 1.1.1
%endif
%endif

# BUILD_ZSTD finds the system libzstd through pkg-config, and needs the
# static archive, which lives in a separate package.
%if %{without bundled_zstd}
%if 0%{?is_suse}
BuildRequires:  libzstd-devel-static >= 1.4.7
%else
BuildRequires:  libzstd-static >= 1.4.7
%endif
%endif

%if %{with docs}
BuildRequires:  pandoc
BuildRequires:  python3-pyyaml
%endif

%if 0%{?is_suse}
Recommends:     logrotate
%{?sysusers_requires}
%else
Requires:       logrotate
Requires(pre):  shadow-utils
%endif

# Bundled dependencies
Provides:       bundled(libvalkey) = 1.0.0
Provides:       bundled(lua-libs) = 5.1.5
Provides:       bundled(linenoise) = 1.0
Provides:       bundled(hdr_histogram) = 0.11.8
Provides:       bundled(fpconv)
Provides:       bundled(lz4) = 1.10.0
%if %{with bundled_zstd}
Provides:       bundled(zstd) = %{zstd_version}
%endif

Provides:       valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

Provides:       valkey = %{version}-%{release}
Obsoletes:      valkey < %{version}-%{release}

ExcludeArch:    %{ix86}

%description
Valkey is an advanced key-value store. It is often referred to as a data
structure server since keys can contain strings, hashes, lists, sets and
sorted sets.

You can run atomic operations on these types, like appending to a string;
incrementing the value in a hash; pushing to a list; computing set
intersection, union and difference; or getting the member with highest
ranking in a sorted set.

In order to achieve its outstanding performance, Valkey works with an
in-memory dataset. Depending on your use case, you can persist it either
by dumping the dataset to disk every once in a while, or by appending
each command to a log.

Valkey also supports trivial-to-setup master-slave replication, with very
fast non-blocking first synchronization, auto-reconnection on net split
and so forth.

Other features include Transactions, Pub/Sub, Lua scripting, Keys with a
limited time-to-live, and configuration settings to make Valkey behave like
a cache.

You can use Valkey from most programming languages.

%package        devel
Summary:        Development header for Valkey module development
Provides:       %{name}-static = %{version}-%{release}
Provides:       valkey-devel = %{version}-%{release}
Obsoletes:      valkey-devel < %{version}-%{release}

%description    devel
Header file required for building loadable Valkey modules. Includes the
valkeymodule.h API header and RPM macros for module packaging.

%package        compat-redis
Summary:        Conversion script and compatibility symlinks for Redis
Requires:       %{name} >= %{version}
Requires(post): /usr/bin/find
Provides:       valkey-compat-redis = %{version}-%{release}
Obsoletes:      valkey-compat-redis < %{version}-%{release}
%if 0%{?fedora} > 40 || 0%{?rhel} > 9
Obsoletes:      redis < 7.4
Provides:       redis = %{version}-%{release}
%else
Conflicts:      redis < 7.4
%endif

%description    compat-redis
This package contains compatibility symlinks and wrappers to enable
easy conversion from Redis to Valkey. It provides redis-* command names
that redirect to the equivalent valkey-* commands.

%package        compat-redis-devel
Summary:        Compatibility development header for Redis API Valkey modules
Requires:       %{name}-devel >= %{version}
Provides:       valkey-compat-redis-devel = %{version}-%{release}
Obsoletes:      valkey-compat-redis-devel < %{version}-%{release}
%if 0%{?fedora} > 40 || 0%{?rhel} > 9
Obsoletes:      redis-devel < 7.4
Provides:       redis-devel = %{version}-%{release}
Obsoletes:      redis-static < 7.4
Provides:       redis-static = %{version}-%{release}
%else
Conflicts:      redis-devel < 7.4
Conflicts:      redis-static < 7.4
%endif

%description    compat-redis-devel
Header file required for building loadable Valkey modules with the legacy
Redis API.

%if %{with docs}
%package        doc
Summary:        Documentation and extra man pages for %{name}
License:        CC-BY-SA-4.0
Provides:       valkey-doc = %{version}-%{release}
Obsoletes:      valkey-doc < %{version}-%{release}
%if 0%{?fedora} > 40 || 0%{?rhel} > 9
Obsoletes:      redis-doc < 7.4
Provides:       redis-doc = %{version}-%{release}
%endif

%description    doc
Documentation and additional man pages for Valkey.
%endif

%prep
%if %{with bundled_zstd}
echo "%{zstd_sha256}  %{SOURCE60}" | sha256sum -c -
%endif
%setup -n %{valkey_name}-%{version} %{?with_docs:-a50} %{?with_bundled_zstd:-a60}

%patch -P1001 -p1

mv deps/lua/COPYRIGHT             COPYRIGHT-lua
mv deps/libvalkey/COPYING         COPYING-libvalkey-BSD-3-Clause
mv deps/hdr_histogram/LICENSE.txt LICENSE-hdrhistogram
mv deps/hdr_histogram/COPYING.txt COPYING-hdrhistogram
mv deps/fpconv/LICENSE.txt        LICENSE-fpconv
mv deps/lz4/LICENSE               LICENSE-lz4
%if %{with bundled_zstd}
cp zstd-%{zstd_version}/LICENSE   LICENSE-zstd
%endif

%ifarch %ix86 %arm x86_64 s390x
sed -e 's/--with-lg-quantum/--with-lg-page=12 --with-lg-quantum/' -i deps/Makefile
%endif
%ifarch ppc64 ppc64le aarch64
sed -e 's/--with-lg-quantum/--with-lg-page=16 --with-lg-quantum/' -i deps/Makefile
%endif

api=$(sed -n -e 's/#define VALKEYMODULE_APIVER_[0-9][0-9]* //p' src/valkeymodule.h)
if test "$api" != "%{valkey_modules_abi}"; then
   : Error: Upstream API version is now ${api}, expecting %%{valkey_modules_abi}.
   : Update the valkey_modules_abi macro, the rpmmacros file, and rebuild.
   exit 1
fi

%build
%if %{with bundled_zstd}
# Static, position-independent libzstd in a private prefix that ZSTD_PREFIX
# (in build_flags) points the Valkey build at.
%make_build -C zstd-%{zstd_version}/lib libzstd.a CFLAGS="%{optflags} -fPIC"
make -C zstd-%{zstd_version}/lib install-static install-includes PREFIX="$PWD/zstd-root"
%endif

%make_build %{build_flags}

# A source tree that predates BUILD_ZSTD ignores the flag silently instead of
# failing, so confirm the feature really was compiled in: src/.make-settings
# records FINAL_CFLAGS, which carries -DHAVE_ZSTD when zstd is enabled. A
# release must have it; a release candidate cut before zstd landed
# (9.2.0-rc1) only warns.
if [ -f src/.make-settings ] && grep -q -- '-DHAVE_ZSTD' src/.make-settings; then
    :
else
    case "%{version}" in
    *rc*)
        echo "warning: BUILD_ZSTD=yes was ignored: %{version} predates zstd support" >&2
        ;;
    *)
        echo "error: BUILD_ZSTD=yes was requested but zstd support was not compiled in" >&2
        exit 1
        ;;
    esac
fi

%if 0%{?is_suse}
%sysusers_generate_pre %{SOURCE8} %{valkey_name}
%endif

%if %{with docs}
pushd %{valkey_name}-doc-%{doc_version}
%make_build VALKEY_ROOT=../
%make_build html VALKEY_ROOT=../
popd
%endif

%install
make install %{install_flags}

%if %{with lua_module}
# Upstream's install-lua-module hardcodes PREFIX/lib for the new shared
# Lua module and does not reliably honor the INSTALL_LIB command-line
# override across the top-level -> src/Makefile recursion, so on multilib
# distros (x86_64 RHEL where libdir is lib64) the .so lands in lib
# instead of lib64. Relocate it to the correct arch libdir manually and
# clean up the wrong-libdir copy if present.
install -Dm0644 src/modules/lua/libvalkeylua.so %{buildroot}%{_libdir}/libvalkeylua.so
rm -f %{buildroot}%{_prefix}/lib/libvalkeylua.so

# Strip the leaked build-time RPATH from binaries and the lua module.
# Upstream 9.1's src/Makefile bakes -Wl,-rpath,PREFIX/lib:BUILDDIR/modules/lua
# into every binary built when BUILD_LUA is not "no". The first entry is
# unnecessary (libvalkeylua.so lives in the arch libdir which is in glibc's
# default search path) and the second entry leaks the absolute build
# directory, which trips both check-buildroot and lintian rpath warnings.
chrpath -d %{buildroot}%{_bindir}/%{valkey_name}-server
chrpath -d %{buildroot}%{_bindir}/%{valkey_name}-cli
chrpath -d %{buildroot}%{_bindir}/%{valkey_name}-benchmark
chrpath -d %{buildroot}%{_libdir}/libvalkeylua.so 2>/dev/null || :
%endif

%if %{with docs}
pushd %{valkey_name}-doc-%{doc_version}
make install INSTALL_MAN_DIR=%{buildroot}%{_mandir} %{install_flags} VALKEY_ROOT=../
install -d %{buildroot}%{_docdir}/%{valkey_name}/
cp -ra _build/html/* %{buildroot}%{_docdir}/%{valkey_name}/
%if 0%{?is_rhel}
install -d %{buildroot}%{_defaultlicensedir}/%{name}-doc/
cp -a LICENSE %{buildroot}%{_defaultlicensedir}/%{name}-doc/
%endif
popd
%endif

rm -rf %{buildroot}%{_datadir}/%{valkey_name}

install -dm0750 %{buildroot}%{_data_dir}
install -dm0750 %{buildroot}%{_data_dir}/default
install -dm0750 %{buildroot}%{_log_dir}
install -dm0750 %{buildroot}%{_log_dir}/default
install -dm0755 %{buildroot}%{_conf_dir}
install -dm0755 %{buildroot}%{_conf_dir}/includes
install -dm0755 %{buildroot}%{valkey_modules_dir}

install -Dm0644 src/%{valkey_name}module.h %{buildroot}%{_includedir}/%{valkey_name}module.h
install -Dm0644 %{SOURCE9} %{buildroot}%{_rpmmacrodir}/macros.%{valkey_name}

# Embedded SBOM set (SPDX/CycloneDX json+xml, Syft table, license manifest),
# generated from the built tree by the shipped gen-module-sbom.sh — the same
# 6-file set as every module. Syft is on PATH via valkey_builder.sh install_deps;
# the script fails loudly if it is missing. %files ships %{_datadir}/%{name}/.
sh gen-module-sbom.sh %{name} %{version}-%{release} %{buildroot}%{_datadir}/%{name}/sbom .

install -Dm0640 valkey.conf %{buildroot}%{_conf_dir}/includes/valkey.defaults.conf
# No longer used by sentinel-default.conf, but kept so Sentinel configs from
# older packages that include it keep starting after an upgrade.
install -Dm0640 sentinel.conf %{buildroot}%{_conf_dir}/includes/sentinel.defaults.conf

# Install default instance configuration files
install -Dm0640 valkey.default.conf %{buildroot}%{_conf_dir}/default.conf
# Sentinel rewrites its whole config when it saves state, so it gets one
# self-contained file: an include would end up defining its primaries twice.
install -Dm0640 sentinel.conf %{buildroot}%{_conf_dir}/sentinel-default.conf

# Install system configuration
%if 0%{?is_suse}
install -Dm0644 %{SOURCE5} %{buildroot}%{_prefix}/lib/sysctl.d/00-%{valkey_name}.conf
%else
install -Dm0644 %{SOURCE5} %{buildroot}%{_sysconfdir}/sysctl.d/00-%{valkey_name}.conf
%endif

%if 0%{?suse_version} > 1500
install -Dm0644 %{SOURCE1} %{buildroot}%{_distconfdir}/logrotate.d/%{valkey_name}
%else
install -Dm0644 %{SOURCE1} %{buildroot}%{_sysconfdir}/logrotate.d/%{valkey_name}
%endif

install -Dm0644 %{SOURCE2} %{buildroot}%{_unitdir}/%{valkey_name}.target
install -Dm0644 %{SOURCE3} %{buildroot}%{_unitdir}/%{valkey_name}@.service
install -Dm0644 %{SOURCE6} %{buildroot}%{_unitdir}/%{valkey_name}-sentinel@.service
install -Dm0644 %{SOURCE7} %{buildroot}%{_unitdir}/%{valkey_name}-sentinel.target
install -Dm0644 %{SOURCE4} %{buildroot}%{_tmpfilesdir}/%{valkey_name}.conf

%if 0%{?is_suse}
install -Dm0644 %{SOURCE8} %{buildroot}%{_sysusersdir}/%{valkey_name}-user.conf
%else
install -Dm0644 %{SOURCE8} %{buildroot}%{_sysusersdir}/%{valkey_name}.conf
%endif

install -Dm0755 %{SOURCE10} %{buildroot}%{_libexecdir}/migrate_redis_to_valkey.bash

install -pDm644 src/redismodule.h %{buildroot}%{_includedir}/redismodule.h

for valkeybin in %{buildroot}%{_bindir}/valkey-*; do
    [ -f "$valkeybin" ] || continue
    redisbin=$(basename "$valkeybin" | sed 's/^valkey-/redis-/')
    redisbin_path="%{buildroot}%{_bindir}/${redisbin}"
    # Only create symlink if it doesn't exist (Valkey 9.0+ may create them automatically)
    if [ ! -e "$redisbin_path" ]; then
        ln -s "$(basename "$valkeybin")" "$redisbin_path"
    fi
done

install -dm0755 %{buildroot}%{_sbindir}
for redisbin in %{buildroot}%{_bindir}/redis-*; do
    [ -L "$redisbin" ] || [ -f "$redisbin" ] || continue
    sbin_target="%{buildroot}%{_sbindir}/$(basename "$redisbin")"
    # Only create if doesn't exist
    if [ ! -e "$sbin_target" ]; then
        ln -sr "$redisbin" "$sbin_target"
    fi
done

ln -sr %{buildroot}%{_unitdir}/%{valkey_name}.target %{buildroot}%{_unitdir}/redis.target
ln -sr %{buildroot}%{_unitdir}/%{valkey_name}@.service %{buildroot}%{_unitdir}/redis@.service
ln -sr %{buildroot}%{_unitdir}/%{valkey_name}-sentinel.target %{buildroot}%{_unitdir}/redis-sentinel.target
ln -sr %{buildroot}%{_unitdir}/%{valkey_name}-sentinel@.service %{buildroot}%{_unitdir}/redis-sentinel@.service

chmod 755 %{buildroot}%{_bindir}/%{valkey_name}-*

%if 0%{?is_suse}
cp %{SOURCE11} README.SUSE
%else
cp %{SOURCE12} README.RHEL
%endif

%check
# Ensure tclsh is findable (runtest looks for tclsh8.6/tclsh8.5;
# some distros only ship the unversioned 'tclsh' binary)
if ! command -v tclsh8.6 >/dev/null 2>&1 && ! command -v tclsh8.5 >/dev/null 2>&1; then
    if command -v tclsh >/dev/null 2>&1; then
        ln -sf "$(command -v tclsh)" /usr/local/bin/tclsh8.6
    fi
fi
# Generate TLS certificates for testing
./utils/gen-test-certs.sh
# Run unit tests (single-client to avoid races), with TLS
taskset -c 1 ./runtest --clients 1 --verbose --dump-logs --tls || true
# Cluster tests
timeout 30m ./runtest-cluster --tls || true
# Sentinel tests
./runtest-sentinel || true
# Clean up test certificates and temp files
rm -rf tests/tls || true
find tests/tmp ! -name .gitignore -type f -exec rm -rfv {} +


%if 0%{?is_suse}
%pre -f %{valkey_name}.pre
%service_add_pre %{valkey_name}.target %{valkey_name}@.service %{valkey_name}-sentinel.target %{valkey_name}-sentinel@.service
%else
%pre
%if 0%{?sysusers_create_compat:1}
%sysusers_create_compat %{SOURCE8}
%else
getent group valkey &>/dev/null || groupadd -r valkey
getent passwd valkey &>/dev/null || \
    useradd -r -g valkey -d /var/lib/valkey -s /sbin/nologin \
    -c "User for valkey key-value store" valkey
exit 0
%endif
%endif

%post
%if 0%{?is_suse}
%tmpfiles_create %{_tmpfilesdir}/%{valkey_name}.conf
%service_add_post %{valkey_name}.target %{valkey_name}@.service %{valkey_name}-sentinel.target %{valkey_name}-sentinel@.service
cat <<'EOF'
-----------------------------------------------------------------------------
Valkey has been installed successfully.

Please see %{_docdir}/%{valkey_name}/README.SUSE for configuration instructions.
-----------------------------------------------------------------------------
EOF
%else
%systemd_post %{valkey_name}.target %{valkey_name}@.service %{valkey_name}-sentinel.target %{valkey_name}-sentinel@.service
systemd-tmpfiles --create %{_tmpfilesdir}/%{valkey_name}.conf >/dev/null 2>&1 || :
cat <<'EOF'
-----------------------------------------------------------------------------
Valkey has been installed successfully.

Please see %{_docdir}/%{valkey_name}/README.RHEL for configuration instructions.
-----------------------------------------------------------------------------
EOF
%endif

%post compat-redis
%{_libexecdir}/migrate_redis_to_valkey.bash

%preun
%if 0%{?is_suse}
%service_del_preun %{valkey_name}.target %{valkey_name}@.service %{valkey_name}-sentinel.target %{valkey_name}-sentinel@.service
%else
%systemd_preun %{valkey_name}.target %{valkey_name}@.service %{valkey_name}-sentinel.target %{valkey_name}-sentinel@.service
%endif

%postun
%if 0%{?is_suse}
%service_del_postun %{valkey_name}.target %{valkey_name}@.service %{valkey_name}-sentinel.target %{valkey_name}-sentinel@.service
%else
%systemd_postun_with_restart %{valkey_name}@.service %{valkey_name}-sentinel@.service
%endif

%files
%license COPYING
%license COPYRIGHT-lua
%license LICENSE-hdrhistogram
%license COPYING-hdrhistogram
%license LICENSE-fpconv
%license LICENSE-lz4
%if %{with bundled_zstd}
%license LICENSE-zstd
%endif
%license COPYING-libvalkey-BSD-3-Clause
%doc 00-RELEASENOTES README.md
%if 0%{?is_suse}
%doc README.SUSE
%else
%doc README.RHEL
%endif

# SBOM (SPDX + CycloneDX), embedded supply-chain inventory
%{_datadir}/%{name}/

%if 0%{?suse_version} > 1500
%{_distconfdir}/logrotate.d/%{valkey_name}
%else
%config(noreplace) %{_sysconfdir}/logrotate.d/%{valkey_name}
%endif

%if 0%{?is_suse}
%{_prefix}/lib/sysctl.d/00-%{valkey_name}.conf
%else
%config(noreplace) %{_sysconfdir}/sysctl.d/00-%{valkey_name}.conf
%endif

%{_bindir}/%{valkey_name}-*
%if %{with lua_module}
%{_libdir}/libvalkeylua.so
%endif
%{_tmpfilesdir}/%{valkey_name}.conf
%if 0%{?is_suse}
%{_sysusersdir}/%{valkey_name}-user.conf
%else
%{_sysusersdir}/%{valkey_name}.conf
%endif
%{_unitdir}/%{valkey_name}@.service
%{_unitdir}/%{valkey_name}.target
%{_unitdir}/%{valkey_name}-sentinel@.service
%{_unitdir}/%{valkey_name}-sentinel.target

%dir %{_libdir}/%{valkey_name}
%dir %{valkey_modules_dir}

# Sentinel saves state by writing a temp file next to its config and
# renaming it over the config, and refuses to start if it cannot. The
# sticky bit lets the valkey group do that while only letting it replace
# files it owns, so root-owned configs such as default.conf stay protected.
%dir %attr(1770,root,%{valkey_name}) %{_conf_dir}
%dir %{_conf_dir}/includes
%config(noreplace) %attr(0640,root,%{valkey_name}) %{_conf_dir}/includes/valkey.defaults.conf
%config(noreplace) %attr(0640,root,%{valkey_name}) %{_conf_dir}/includes/sentinel.defaults.conf
%config(noreplace) %attr(0640,root,%{valkey_name}) %{_conf_dir}/default.conf
%config(noreplace) %attr(0640,%{valkey_name},%{valkey_name}) %{_conf_dir}/sentinel-default.conf

%dir %attr(0750,%{valkey_name},%{valkey_name}) %{_data_dir}
%dir %attr(0750,%{valkey_name},%{valkey_name}) %{_data_dir}/default
%dir %attr(0750,%{valkey_name},%{valkey_name}) %{_log_dir}
%dir %attr(0750,%{valkey_name},%{valkey_name}) %{_log_dir}/default

%ghost %dir %attr(0755,%{valkey_name},%{valkey_name}) /run/%{valkey_name}

%if %{with docs}
%{_mandir}/man1/%{valkey_name}*.gz
%{_mandir}/man5/%{valkey_name}.conf.5.gz
%endif

%files devel
%license COPYING
%{_includedir}/%{valkey_name}module.h
%{_rpmmacrodir}/macros.%{valkey_name}

%files compat-redis
%{_libexecdir}/migrate_redis_to_valkey.bash
%{_bindir}/redis-*
%{_sbindir}/redis-*
%{_unitdir}/redis.target
%{_unitdir}/redis@.service
%{_unitdir}/redis-sentinel.target
%{_unitdir}/redis-sentinel@.service

%files compat-redis-devel
%{_includedir}/redismodule.h

%if %{with docs}
%files doc
%if 0%{?is_rhel}
%license LICENSE
%endif
%doc %{_docdir}/%{valkey_name}/
%{_mandir}/man{3,7}/*%{valkey_name}*.gz
%endif

%changelog
* Thu Nov 26 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.2.1-1
- Bump to Valkey 9.2.1 (upstream 9.2.1 tag): bugfix release that restores
  pre-9.2 TLS certificate loading and fixes several crashes in IO threads,
  cluster bus handling, PHGET during forkless save and COMMAND GETKEYS EXEC

* Mon Oct 12 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.2.0-1
- Bump to Valkey 9.2.0 (upstream 9.2.0 tag)
- Build with BUILD_ZSTD=yes for Zstandard streaming compression; EL has no
  static libzstd, so a pinned zstd %{zstd_version} is built statically and
  bundled there, while other distros use their libzstd static package
- Declare the vendored lz4 that Valkey 9.2 bundles and ship its licence
- Make /etc/valkey root:valkey 1770 and ship sentinel-default.conf as a
  self-contained valkey-owned config: Valkey 9.2 Sentinel refuses to start
  unless it can create a temp file in its config directory
* Tue Sep 01 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.2-1
- Bump to Valkey 9.1.2 (upstream 9.1.2 tag)

* Thu Jul 23 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.1-1
- Bump to Valkey 9.1.1

* Tue Apr 14 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.0-1
- Bump to Valkey 9.1.0
- Built from upstream 9.1 branch (9.1.0 tag not yet released)

* Tue Feb 17 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.0.2-1.1
- Rename package from valkey to percona-valkey for Percona branding
- Add Provides/Obsoletes for smooth upgrades from valkey packages

* Tue Feb 17 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.0.1-1.1
- Fix: apply conf patch on all distros, not just SUSE
- Fix: install default instance configs (default.conf, sentinel-default.conf)
- Fix: use system jemalloc instead of bundled
- Fix: split build/install flags to avoid baking buildroot into binaries
- Fix: sentinel service WantedBy references correct target
- Fix: migration script robustness (guard missing dirs, quote variables)
- Fix: add Requires(pre) shadow-utils on RHEL
- Fix: logrotate catches logs in subdirectories
- Fix: renumber Source files (close Source5 gap)
- Add systemd service hardening directives
- Sync doc_version with package version

* Tue Jan 27 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.0.1-1
- Initial build
