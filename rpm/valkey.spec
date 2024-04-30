Name:              valkey
Version:           7.2.5
Release:           1%{?dist}
Summary:           A persistent key-value database
License:           BSD-3-Clause AND BSD-2-Clause AND MIT AND BSL-1.0
URL:               https://valkey.io
Source0:           %{name}-%{version}.tar.gz
Source1:           %{name}.logrotate
Source2:           %{name}-sentinel.service
Source3:           %{name}.service
Source4:           %{name}.sysusers
Source5:           %{name}-limit-systemd
Source6:           %{name}.sysconfig
Source7:           %{name}-sentinel.sysconfig
Source8:           macros.%{name}
Source9:           conf_update.sh

Conflicts:         redis

BuildRequires:     make
BuildRequires:     gcc
BuildRequires:     pkgconfig(libsystemd)
BuildRequires:     systemd-devel
BuildRequires:     systemd-rpm-macros
BuildRequires:     openssl-devel
Requires:          logrotate
Requires(pre):     shadow-utils
Requires(post):    systemd
Requires(preun):   systemd
Requires(postun):  systemd

Provides:          bundled(hiredis) = 1.0.3
Provides:          bundled(jemalloc) = 5.3.0
Provides:          bundled(lua-libs) = 5.1.5
Provides:          bundled(linenoise) = 1.0
Provides:          bundled(lzf)
Provides:          bundled(hdr_histogram) = 0.11.0
Provides:          bundled(fpconv)

%global valkey_modules_abi 1
%global valkey_modules_dir %{_libdir}/%{name}/modules
Provides:          valkey(modules_abi)%{?_isa} = %{valkey_modules_abi}

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

You can use Valkey from most programming languages also.

%package           devel
Summary:           Development header for Valkey module development
Provides:          %{name}-static = %{version}-%{release}
Conflicts:         redis-devel

%description       devel
Header file required for building loadable Valkey modules.


%package           compat
Summary:           Config conversion scripts from redis to valkey
Requires:          valkey

%description       compat
%summary


%prep
%autosetup -n %{name}-%{version} -p1

mv deps/lua/COPYRIGHT             COPYRIGHT-lua
mv deps/jemalloc/COPYING          COPYING-jemalloc
mv deps/hiredis/COPYING COPYING-hiredis-BSD-3-Clause
mv deps/hdr_histogram/LICENSE.txt LICENSE-hdrhistogram
mv deps/hdr_histogram/COPYING.txt COPYING-hdrhistogram
mv deps/fpconv/LICENSE.txt        LICENSE-fpconv


%ifarch ppc64 ppc64le aarch64
sed -e 's/--with-lg-quantum/--with-lg-page=16 --with-lg-quantum/' -i deps/Makefile
%else
sed -e 's/--with-lg-quantum/--with-lg-page=12 --with-lg-quantum/' -i deps/Makefile
%endif

api=`sed -n -e 's/#define VALKEYMODULE_APIVER_[0-9][0-9]* //p' src/valkeymodule.h`
%global make_flags DEBUG="" V="echo" PREFIX=%{buildroot}%{_prefix} BUILD_WITH_SYSTEMD=yes BUILD_TLS=yes

%build
%make_build %{make_flags}

%install
%make_install %{make_flags}
rm -rf %{buildroot}%{_datadir}/%{name}
install -p -D -m 0644 %{SOURCE4} %{buildroot}%{_sysusersdir}/%{name}.conf

install -d %{buildroot}%{_sharedstatedir}/%{name}
install -d %{buildroot}%{_localstatedir}/log/%{name}
install -d %{buildroot}%{_localstatedir}/run/%{name}
install -d %{buildroot}%{valkey_modules_dir}
install -pDm644 %{SOURCE1} %{buildroot}%{_sysconfdir}/logrotate.d/%{name}
install -pDm640 %{name}.conf  %{buildroot}%{_sysconfdir}/%{name}/%{name}.conf
install -pDm640 sentinel.conf %{buildroot}%{_sysconfdir}/%{name}/sentinel.conf
mkdir -p %{buildroot}%{_unitdir}
install -pm644 %{SOURCE3} %{buildroot}%{_unitdir}
install -pm644 %{SOURCE2} %{buildroot}%{_unitdir}
install -p -D -m 644 %{SOURCE5} %{buildroot}%{_unitdir}/%{name}.service.d/limit.conf
install -p -D -m 644 %{SOURCE5} %{buildroot}%{_unitdir}/%{name}-sentinel.service.d/limit.conf

chmod 755 %{buildroot}%{_bindir}/%{name}-*
install -pDm644 src/%{name}module.h %{buildroot}%{_includedir}/%{name}module.h
install -pDm644 %{SOURCE8} %{buildroot}%{_rpmmacrodir}/macros.%{name}
install -Dpm 644 %{SOURCE6} %{buildroot}%{_sysconfdir}/sysconfig/%{name}
install -Dpm 644 %{SOURCE7} %{buildroot}%{_sysconfdir}/sysconfig/%{name}-sentinel
install -Dpm 755 %{SOURCE9} %{buildroot}%{_libexecdir}/conf_update.sh


%pre
%sysusers_create_compat %{SOURCE4}


%post
%systemd_post %{name}.service
%systemd_post %{name}-sentinel.service


%post compat
%{_libexecdir}/conf_update.sh


%preun
%systemd_preun %{name}.service
%systemd_preun %{name}-sentinel.service


%postun
%systemd_postun_with_restart %{name}.service
%systemd_postun_with_restart %{name}-sentinel.service


%files
%license COPYING
%license COPYRIGHT-lua
%license COPYING-jemalloc
%license LICENSE-hdrhistogram
%license COPYING-hdrhistogram
%license LICENSE-fpconv
%license COPYING-hiredis-BSD-3-Clause
%config(noreplace) %{_sysconfdir}/logrotate.d/%{name}
%attr(0750, valkey, root) %dir %{_sysconfdir}/%{name}
%attr(0640, valkey, root) %config(noreplace) %{_sysconfdir}/%{name}/%{name}.conf
%attr(0640, valkey, root) %config(noreplace) %{_sysconfdir}/%{name}/sentinel.conf
%dir %{_libdir}/%{name}
%dir %{valkey_modules_dir}
%dir %attr(0750, valkey, valkey) %{_sharedstatedir}/%{name}
%dir %attr(0750, valkey, valkey) %{_localstatedir}/log/%{name}
%{_bindir}/%{name}-*
%{_bindir}/redis-*
%{_unitdir}/%{name}.service
%{_unitdir}/%{name}-sentinel.service
%dir %{_unitdir}/%{name}.service.d
%{_unitdir}/%{name}.service.d/limit.conf
%dir %{_unitdir}/%{name}-sentinel.service.d
%{_unitdir}/%{name}-sentinel.service.d/limit.conf
%dir %attr(0755, valkey, valkey) %ghost %{_localstatedir}/run/%{name}
%{_sysusersdir}/%{name}.conf
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}
%config(noreplace) %{_sysconfdir}/sysconfig/%{name}-sentinel


%files devel
%license COPYING
%{_includedir}/%{name}module.h
%{_rpmmacrodir}/macros.%{name}


%files compat
%{_libexecdir}/conf_update.sh


%changelog
* Sun Apr 21 2024 Evgeniy Patlan <jevgeniy.patlan@percona.com> - 7.2.5-1
- Initial build
