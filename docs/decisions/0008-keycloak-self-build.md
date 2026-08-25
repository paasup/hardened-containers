# 0008. Build the Keycloak image ourselves

- Status: Accepted

## Decision

The Keycloak image is built here. The build definition is
[images/keycloak/](../../images/keycloak/) — upstream's published tar.gz is used as-is
and repackaged onto a SUSE BCI rootfs, then the vulnerable jars shipped inside the
distribution have their contents replaced while keeping their filenames
(`overlay-jars.sh`).

Two further decisions come with this self-build — the final base's BCI version (15.7,
not 16.0) and the rootfs assembly method (seed, not installroot overlay). All three are
recorded in this one ADR.

## Context

Upstream `quay.io/keycloak/keycloak:26.6.4` had 17 blocking findings at the gate (17
effective HIGH, 0 CRITICAL). The layers differ completely in nature — of the 5 in the
UBI9 rpm layer, some are resolved by updating rpms, but the 12 in the bundled jar layer
(netty ×6, jackson ×3, postgresql-jdbc, mssql-jdbc, keycloak-services) are not.

## Rationale

### (a) Choosing a self-build — replacing jars was the only lever

- **Moving to a newer tag was evaluated first** (step 1 of the new-image checklist in
  image-authoring/README.md). Both `26.6.4` and the latest `26.7.1` have
  `quarkus.version` of `3.33.2.1`, and that Quarkus BOM pins `netty 4.1.135.Final` and
  `jackson-bom 2.21.2` (measured: comparing keycloak's `pom.xml` across both tags plus
  `quarkusio/quarkus` `bom/application/pom.xml@3.33.2.1`). The fixed versions for the
  blocking CVEs at the time were netty `4.1.136.Final` and jackson `2.21.4`, so until the
  next Quarkus BOM landed there was no path via a newer tag.
- **A base OS swap does not touch jars either.** The CVEs are in jars shipped with the
  distribution rather than in OS packages — structurally the same as the statically
  linked Go modules in `cloudnative-pg` and `etcd`
  ([0002](0002-cloudnative-pg-operator-self-build.md),
  [0003](0003-etcd-image-self-build.md)).
- So a self-build that replaces the jars directly was the only lever available at the
  time. It is the same kind of dependency override as etcd resolving its issue with one
  `replace golang.org/x/text` line in `go.work`, and it shares the same single
  orchestrator,
  [scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh).

### (b) BCI 15.7 vs 16.0 — the newer one was older for this image

A new SLE major (16.0) was available, but measuring the needed package versions per
candidate tag led to keeping 15.7 (see "Pick the BCI version by measuring, per image" in
image-authoring/base-os-policy.md).

| BCI | `java-21-openjdk-headless` |
| --- | --- |
| 15.7 | `21.0.12.0-150600.3.29.1` |
| 16.0 | `21.0.11.0-160000.2.1` |

`21.0.12` was, at the time, the fixed version for CVE-2026-41254 and CVE-2026-47063
among this image's blocking CVEs — going to 16.0 would have left both in place. All the
other required packages (`glibc-locale-base`, `ca-certificates-mozilla`, `sed`, `grep`,
`findutils`, `timezone`) exist in 16.0 too, so this one JDK patch-level difference was
the only variable.

### (c) rootfs assembly — seed versus installroot overlay

Upstream's `ubi-null.sh` installs packages into an empty installroot and lays that
rootfs **over** `ubi9-micro`. Porting that structure to SUSE directly was evaluated
first and fails: `bci-micro` has no package manager but does have an rpmdb
(`/usr/lib/sysimage/rpm`), so laying a rootfs installed into an empty installroot over
it shadows micro's rpmdb with the new one and **micro's own packages disappear from the
SBOM entirely** — that is not fewer CVEs, it is a scanning blind spot.

Instead, `bci-micro`'s filesystem is laid down as a seed and packages are installed on
top with `zypper --installroot` — the rpmdb is appended to micro's, so every OS package
in the final image appears in the SBOM. After the build, the OS package count in the
SBOM (44 in upstream's UBI9) confirms whether masking occurred — dropping to single
digits means the seed approach did not work. This rootfs seed pattern is common to every
image that adds packages on top of `bci-micro`, so it is generalised in the "Adding
packages on top of `bci-micro`" section of
[docs/image-authoring/base-os-policy.md](../image-authoring/base-os-policy.md).

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md) and
  [0002](0002-cloudnative-pg-operator-self-build.md).
- **A person updates `KEYCLOAK_VERSION` and the `*_OLD`/`*_VERSION` jar versions.** They
  are not tracked automatically — reading an upstream release and editing
  `suse.build.env` to open a PR is itself the update trigger. `overlay-jars.sh` fails the
  build if it finds no jar at the `*_OLD` version, preventing the state where upstream
  bumped a dependency and the overlay silently does nothing.
- **`bin/client` (`kcadm` / `kcreg`) was removed.** `keycloak-admin-cli-<ver>.jar` is an
  uber-jar that shades jackson, so it cannot be fixed by jar replacement; the entire
  standalone CLI — which the server JVM never loads — was dropped instead. This is the
  only functional difference from upstream. If `kcadm` is needed in operations, use the
  upstream image as a separate container.
- **Until BCI 16.0's JDK catches up with 15.7, there is a re-measurement burden every
  time a new BCI tag appears.** The re-measurement procedure is in the
  `images/keycloak/suse.build.env` comments.
- **Until the Quarkus BOM moves up and makes the overlay unnecessary, whether to keep
  this self-build must be re-decided at every Keycloak release.**
- **This is a configuration upstream does not test.** BCI-based rootfs seed assembly is
  not in Keycloak's CI matrix.

## Conditions for revisiting

- **When the Quarkus BOM pins the fixed netty and jackson versions** — removing that jar
  overlay spec always takes priority over keeping this self-build.
- **When `java-21-openjdk-headless` in BCI 16.0 (or later) catches up with 15.7's patch
  level** — move to the newer BCI.
- **If unexpected runtime problems appear with the `bci-micro` seed approach** (rpmdb
  masking recurring, for instance) — revisit the rootfs assembly method.
