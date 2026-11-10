%global valkey_modules_abi 1
# Meta-package: no compiled sources, so an arch build must not try to produce a
# -debuginfo/-debugsource subpackage (its %%files would be empty -> rpmbuild error).
%global debug_package %{nil}

Name:           percona-valkey-bundle
Version:        9.1.3
Release:        2%{?dist}
Summary:        Percona Valkey server bundled with all supported modules

# Architecture-dependent meta-package: it carries no binaries, but it is built
# per-arch (x86_64 / aarch64) so it lands in the same per-arch repository dirs
# as the server and modules, and its dependencies are arch-matched via %%{?_isa}
# (an x86_64 bundle pulls x86_64 modules, never a cross-arch mix).
License:        BSD-3-Clause
URL:            https://github.com/valkey-io/valkey-bundle
Source0:        percona-valkey-bundle-%{version}.tar.gz

# This is a meta-package: it ships no binaries of its own. Installing it pulls
# in the Percona Valkey server together with every supported module, so the
# whole stack is present with a single install. Versions track the curated
# bundle set (see valkey-io/valkey-bundle versions.json for 9.1):
#   server 9.1.3, json 1.0.3, bloom 1.0.1, search 1.2.1, ldap 1.1.1.
# valkey-audit is a Percona addition to that set.
Requires:       percona-valkey%{?_isa} >= 9.1.3
Requires:       percona-valkey-json%{?_isa} >= 1.0.3
Requires:       percona-valkey-bloom%{?_isa} >= 1.0.1
Requires:       percona-valkey-search%{?_isa} >= 1.2.1
Requires:       percona-valkey-ldap%{?_isa} >= 1.1.1
# 1.0.0-4 is the first audit build with portable CPU flags; 1.0.0-1..3 were
# built with -march=native.
Requires:       percona-valkey-audit%{?_isa} >= 1.0.0-4

# The web administration interface, as a weak dependency: dnf installs it along
# with the bundle wherever it can be resolved, and leaves it out where it
# cannot, instead of making the whole bundle uninstallable. It is the only
# package in the set that needs a language runtime -- "(nodejs >= 1:20 or
# nodejs22 >= 1:22)" -- and that floor is not met from the base repositories on
# every target the bundle is built for: on EL8 and EL9 modular filtering hides
# every modular nodejs until a stream is enabled. Amazon Linux 2023 resolves it
# through nodejs22 and EL10 through its base nodejs. A hard Requires would turn
# each of those into a failed `dnf install percona-valkey-bundle`.
#
# It is also a Percona addition rather than part of the upstream curated set
# (valkey-io/valkey-bundle ships no admin interface), which is the second
# reason to keep it weak.
Recommends:     percona-valkey-admin-server%{?_isa} >= 1.2.0

%description
percona-valkey-bundle is a meta-package that installs the Percona Valkey server
together with all supported modules in one step:

  * percona-valkey-json    (JSON.*  — native JSON data type)
  * percona-valkey-bloom   (BF.*    — Bloom filters)
  * percona-valkey-search  (FT.*    — vector / full-text search)
  * percona-valkey-ldap    (LDAP authentication)
  * percona-valkey-audit   (audit logging)

It additionally recommends percona-valkey-admin-server, the web administration
interface, which is installed along with the bundle wherever its Node (>= 20)
runtime can be satisfied.

It contains no files of its own; it only declares dependencies. The modules are
installed into the Valkey module directory but are not loaded automatically;
enable them with 'loadmodule' in valkey.conf or 'MODULE LOAD' at runtime.

%prep
%autosetup -p1 -n percona-valkey-bundle-%{version}

%build
# Nothing to build — this is a dependency-only meta-package.

%install
# No payload; only the documentation handled by %%license / %%doc below.

%files
%license LICENSE
%doc README.md

%changelog
* Tue Nov 10 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.3-2
- Add percona-valkey-audit to the bundle

* Tue Oct 27 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.3-1
- Release 9.1.3

* Tue Sep 01 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.2-1
- Release 9.1.2

* Thu Jul 23 2026 Evgeniy Patlan <evgeniy.patlan@percona.com> - 9.1.1-1
- Release 9.1.1

* Mon Jun 29 2026 Percona Build <info@percona.com> - 9.1.0-1
- Initial percona-valkey-bundle meta-package (server + json/bloom/search/ldap).
