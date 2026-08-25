# cnpg-postgresql — CloudNativePG PostgreSQL, self-built

English · [한국어](README.ko.md)

The PostgreSQL instance image managed by the CNPG operator, built here. The decision, the
candidates compared, and the costs accepted are in
[ADR 0001](../../docs/decisions/0001-cnpg-postgresql-image.md); image selection rules and
the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

> This image is an **unofficial rebuild** of PostgreSQL / CloudNativePG. It is not
> affiliated with, endorsed by, or supported by the upstream projects. See
> [NOTICE](../../NOTICE) for trademark and licensing notices.

## Why we build this ourselves

The upstream `system` tag family is deprecated (targeted by the in-core barman
phase-out). The replacement candidate, the `standard` family, carries many CRITICAL/HIGH
findings that block the gate, and most of them have no fixed version at the distribution
level (classified `unimportant` / `no-dsa` / `postponed` / unclassified) — moving to a
newer tag alone does not resolve them.

Switching the base OS to SUSE BCI changes the vendor verdict on those same CVEs (SUSE has
already backported them). However, zero findings on its own cannot distinguish "genuinely
clean" from "the scanner does not cover this distribution" — this gate confirms that on
every scan with the coverage self-check (`CoverageProbe`). If the self-check is not `ok`,
zero findings is not evidence of anything.

An Ubuntu-based self-build was also a candidate, but gid 26 is already taken by the `tape`
group, so `postgres` ended up in that group — it worked, but the hygiene problem was real,
and because the candidate was not adopted it fell outside the rebuild cycle and its
findings grew quickly. SUSE BCI does not have this problem.

## Differences from upstream

`suse.Dockerfile` ports upstream CNPG (Debian / apt / PGDG-deb) to SUSE (zypper /
PGDG-rpm). The detailed correspondence is in the comment at the top of that file.

| Item | Upstream (Debian) | This image (SUSE) | Reason |
| --- | --- | --- | --- |
| Base | `standard-trixie` family (Debian) | `registry.suse.com/bci/bci-base:15.7` | Different vendor CVE verdicts, plus gid hygiene |
| Package manager | apt + PGDG deb | zypper + PGDG rpm | An unavoidable consequence of the base OS change |
| `pg-failover-slots` extension | Included | Excluded | No package in the PGDG zypp repository |
| uid/gid | 26 (forced with `usermod`) | 26 (created by the PGDG RPM) | RPM-family convention — no adjustment needed |
| Binary path | `/usr/lib/postgresql/18/bin` | `/usr/pgsql-18/bin` (with a compatibility symlink alongside) | In case any code hardcodes the path |

**Principle: keep the divergence from the upstream Dockerfile minimal.** Arbitrarily
trimming the package set, uid, or extension list breaks conditions the operator expects
of the image.

The `zypper update` in the `patched` stage corresponds to `apt-get upgrade` in the Debian
version — base images are only rebuilt periodically, so they lag the distribution
archive, and without this step the unpatched vulnerabilities of that moment simply remain.

### Checking for upstream build recipe changes (manual, not automated)

If the `cloudnative-pg/postgres-containers` repository changes its own Dockerfile
structure (new extensions, new hardening steps), this port has to follow. Because the
distributions differ (Debian versus SUSE), CI cannot produce a meaningful diff — **the
suggested cadence is to skim the upstream Dockerfile at every CNPG minor release** and,
if the structure changed, re-port `suse.Dockerfile` by hand.

## Version management

`APP_VERSION`, `PG_VERSION` (the exact EVR string of the PGDG package), `BASE`, and
`EXTENSIONS` are **not tracked automatically.** Someone reading a new release in the PGDG
repository and editing `suse.build.env` to open a PR is itself the update trigger.
`PG_VERSION` must not be bumped by looking at major.minor alone — the whole EVR (for
example `18.4-4200001PGDG.sles15.7`) has to match exactly what the PGDG repository
actually publishes, or `zypper install` will not fetch that version.

Whether to follow a change in the upstream build recipe itself (new extensions, new
hardening steps) is covered in the section above — that is a case of re-porting the
structure of `suse.Dockerfile`, not of changing a value.

---

## Building and verifying

```sh
IMAGE=cnpg-postgresql BASE_OS=suse bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** If functional verification fails it never reaches the scan — an image that
does not work is not accepted as a result, even at zero CVEs.

Read the result from `cve-gate.md` in the output directory (`/tmp/out`). Two things to
check:

- **Is effective CRITICAL/HIGH zero?**
- **Does the coverage self-check (`CoverageProbe`) read `ok`?** `none` means the zero
  findings were not a measurement but an absence of scanner data for this distribution,
  and in that case the gate blocks.

Both conditions and the gate mechanism generally are covered in
[image-authoring/](../../docs/image-authoring/README.md).

To push to a registry, set `REGISTRY`. The tag carries the build date — even at the same
application version the result of `zypper update` differs from one point in time to
another, so rolling tags are avoided in favour of a fixed tag including the build date.

```
<registry>/cnpg-postgresql:18.4-bci15.7-hardened-20260729
                            └ app ┘└ base ─┘└hardened┘└ build date ┘
```

### File layout

| File | Role |
| --- | --- |
| `<base-os>.Dockerfile` | Build definition |
| `<base-os>.build.env` | Base, application version, extension list. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Shared across base operating systems — the CNPG requirements are independent of the base |
| `image.env` | The default base OS variant (`DEFAULT_BASE_OS`) |

The structure stays the same as base operating systems are added —
`build-hardened-image.sh` selects `<base-os>.build.env` from the `BASE_OS` environment
variable.

Real deployment verification (bringing it up in a cluster and confirming behaviour)
follows a separate procedure.
