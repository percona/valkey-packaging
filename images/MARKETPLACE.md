# AWS Marketplace submission

Everything needed to submit the Percona Valkey AMIs to AWS Marketplace, plus the
listing content itself. Sections marked **per release** are refreshed for each
version; the rest is stable.

## Product identity

**Title:** Percona Valkey

**Short description (fewer than 200 characters):**

> Percona Valkey is a production-ready distribution of Valkey, the open source,
> high performance key-value data store. Free to use, with optional Percona
> support.

**Long description:**

> Percona Valkey packages the Valkey key-value data store for production use on
> Amazon Linux 2023, built and tested by Percona from the same sources as the
> Percona Valkey DEB and RPM packages.
>
> Valkey is an open source, in-memory data store used as a database, cache,
> message broker and streaming engine. It speaks the Redis protocol, so existing
> clients and tooling work unchanged.
>
> Each instance generates a unique password on first boot, listens on localhost
> only until you choose to expose it, and ships with the kernel settings Valkey
> needs for reliable background saves already applied.
>
> Two images are available. The server image provides Valkey with Sentinel and
> the full command-line tool set. The bundle image adds the JSON, Bloom filter,
> vector and full-text search, LDAP authentication, and audit logging modules,
> loaded and ready to use on first boot.
>
> Percona Valkey is free. Percona offers optional commercial support, services
> and consulting.

## Images

Two variants, each on two architectures.

| Variant | Packages | Modules loaded on boot |
|---|---|---|
| Server | `percona-valkey` | none |
| Bundle | `percona-valkey-bundle` | json, bloom, search, ldap, audit |

Both include `valkey-server`, `valkey-sentinel`, `valkey-cli`,
`valkey-benchmark`, `valkey-check-aof` and `valkey-check-rdb`. Sentinel is
installed but not enabled.

### Published AMIs — per release

Populate at submission time:

```bash
aws ec2 describe-images --owners self --region us-east-1 \
  --filters "Name=name,Values=percona-valkey-${VERSION}-*" \
  --query 'sort_by(Images,&CreationDate)[].[Name,ImageId,Architecture,CreationDate]' \
  --output table
```

| Variant | Architecture | AMI name | AMI id |
|---|---|---|---|
| Server | x86_64 | | |
| Server | arm64 | | |
| Bundle | x86_64 | | |
| Bundle | arm64 | | |

Region coverage is listed in `packer/release.pkvars.hcl`.

## Component versions — per release

| Component | Version |
|---|---|
| Valkey | 9.1.1 |
| valkey-json | 1.0.2 |
| valkey-bloom | 1.0.1 |
| valkey-search | 1.2.0 |
| valkey-ldap | 1.1.1 |
| valkey-audit | 1.0.0 |
| Base OS | Amazon Linux 2023 |

Module versions track the curated set from `valkey-io/valkey-bundle`
`versions.json`. Confirm them against the built image rather than this table:

```bash
rpm -qa 'percona-valkey*' --queryformat '%{NAME} %{VERSION}\n' | sort
```

## Instance type guidance

Valkey is memory-bound. `maxmemory` is set on first boot to **70% of detected
instance memory**, leaving headroom for copy-on-write during background saves,
which can transiently double the resident set of the data being written.

Usable dataset size is therefore roughly 70% of instance memory.

| Variant | Minimum | Recommended families |
|---|---|---|
| Server | 2 GB | `r7i` / `r7g` for memory-bound workloads, `m7i` / `m7g` for mixed |
| Bundle | 8 GB | `r7i` / `r7g` |

The bundle floor is higher because the search module maintains its own index
structures and worker threads outside the keyspace. Index memory is not governed
by `maxmemory`, so a bundle instance needs headroom beyond the dataset itself.
Size bundle instances against measured index footprint before production use.

Graviton (`r7g`, `m7g`) is a strong fit: Valkey is memory-bandwidth sensitive and
the arm64 images are built from the same sources.

## Security group guidance

The image listens on **localhost only** until reconfigured, so a permissive
security group alone does not expose Valkey. Both the security group and the
`bind` directive must be changed to accept remote connections.

| Port | Purpose | Recommended source |
|---|---|---|
| 22 | SSH administration | Administrator CIDR only |
| 6379 | Valkey | Application CIDR or security group only. Never `0.0.0.0/0` |
| 26379 | Sentinel, if enabled | Sentinel peers only |

Valkey has no transport encryption enabled by default. Traffic on 6379 is
plaintext including the password, so restrict it to a trusted network, or
configure TLS before crossing an untrusted one.

## Usage instructions

### Retrieving the generated password

Each instance generates its own 32-character password on first boot. It is not
shared between instances and is not present in the AMI.

Without logging in, from the instance system log:

```bash
aws ec2 get-console-output --region <region> --instance-id <instance-id> \
  --output text | grep -A6 'Percona Valkey'
```

Or over SSH, where it is shown in the message of the day at login, and readable
directly:

```bash
ssh ec2-user@<address>
sudo grep '^requirepass ' /etc/valkey/valkey-generated.conf
```

### Connecting

```bash
valkey-cli -a '<password>'
```

### Changing the password

```bash
sudo sed -i 's/^requirepass .*/requirepass <new-password>/' \
  /etc/valkey/valkey-generated.conf
sudo systemctl restart valkey@default
```

### Accepting remote connections

Edit `/etc/valkey/default.conf`, change the `bind` directive, restart, and open
the port in the security group:

```bash
sudo sed -i 's/^bind .*/bind 0.0.0.0 -::/' /etc/valkey/default.conf
sudo systemctl restart valkey@default
```

Do not do this without a password set and the security group restricted.

### Configuration layout

| Path | Purpose |
|---|---|
| `/etc/valkey/default.conf` | Instance configuration, edit this |
| `/etc/valkey/includes/valkey.defaults.conf` | Upstream defaults, included first |
| `/etc/valkey/valkey-generated.conf` | Per-instance password, memory limit and modules, included last |
| `/var/lib/valkey/default/` | Data directory |
| `/var/log/valkey/default.log` | Log |

The service is `valkey@default`, an instance of the `valkey@.service` template.
`systemctl status valkey@default` reports its state.

Directives in `valkey-generated.conf` win because it is included last. To pin a
value permanently, set it there rather than in `default.conf`.

### Modules, bundle image only

Modules are loaded by `loadmodule` lines written into
`/etc/valkey/valkey-generated.conf` on first boot, discovered from
`/usr/lib64/valkey/modules`. Verify with:

```bash
valkey-cli -a '<password>' MODULE LIST
```

Reports `json`, `bf`, `search`, `ldap`, `audit`, and the built-in `lua`. To run without a
module, remove its `loadmodule` line and restart the service.

## Security posture

Every item below is asserted by the test suite that runs inside the build. A
failure blocks image creation.

| Requirement | How it is met |
|---|---|
| No default or shared credentials | Password generated per instance on first boot |
| No baked SSH keys | No `authorized_keys` in the image |
| Unique host identity | SSH host keys removed at build, regenerated on first boot |
| No OS account passwords | Every account locked in `/etc/shadow` |
| Root SSH login disabled | `PermitRootLogin no` |
| No build artifacts | Package cache, provisioning logs, journal, shell history and machine id cleared |
| No build tooling shipped | Ansible and the test harness removed before the snapshot |
| Not exposed by default | `bind 127.0.0.1 -::1` and `protected-mode yes` |

Access is via the `ec2-user` account using the key pair chosen at launch.

## Encryption

The published AMIs are **unencrypted**, as AWS Marketplace requires for AMI
products. Enable EBS encryption at launch, or copy the AMI with encryption into
your own account, if encryption at rest is required.

## Self-service scan — per release

Share each AMI with the AWS Marketplace scanning account and run a scan from the
Marketplace Management Portal before submitting.

| Variant | Architecture | Scan date | Result |
|---|---|---|---|
| Server | x86_64 | | |
| Server | arm64 | | |
| Bundle | x86_64 | | |
| Bundle | arm64 | | |

To re-verify the hardening assertions directly against a published image, launch
it and run the suite from the repository:

```bash
scp -i <key> -r images/test/bats ec2-user@<address>:/tmp/
ssh -i <key> ec2-user@<address> \
  "sudo VALKEY_VARIANT=<variant> VALKEY_VERSION=<version> bats /tmp/bats/hardening.bats"
```

Run only `hardening.bats`. The other suites assert bake-time state: on a booted
instance the first-boot marker exists and the generated configuration is
populated, so `config.bats` reports failures that are correct behaviour.

## Open decisions

These need confirming with the AWS Marketplace seller account before submission.

1. **Listing structure.** An AMI is architecture-specific, so x86_64 and arm64
   cannot be one image. Confirm whether the seller portal expresses this as
   multiple delivery options within one product or as separate listings, and
   whether Server and Bundle should be two products or one product with two
   delivery options.
2. **Support and EULA.** The listing is free. Confirm which end user licence
   agreement applies and how optional Percona support is referenced.
3. **Region list.** `packer/release.pkvars.hcl` holds the current set. Confirm it
   matches the coverage the listing advertises.

## Licensing

Valkey is released under the BSD 3-Clause License. Module licences follow their
respective upstream projects. Amazon Linux 2023 is distributed under its own
terms.
