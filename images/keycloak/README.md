# keycloak — self-built

English · [한국어](README.ko.md)

The upstream Keycloak distribution (tar.gz) repackaged onto a SUSE BCI rootfs, with the
vulnerable jars shipped inside it replaced by fixed versions.

> This image is an **unofficial rebuild** of Keycloak. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The procedure for adding a self-built image generally is in
[docs/image-authoring/](../../docs/image-authoring/README.md).

The decision, the candidates compared, and the costs accepted (including the BCI version
choice and the rootfs assembly method) are in
[ADR 0008](../../docs/decisions/0008-keycloak-self-build.md); image selection rules and
the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Upstream `quay.io/keycloak/keycloak:26.6.4` has **17 blocking findings at the gate (17
effective HIGH, 0 CRITICAL)**. The layers differ completely in nature.

| Layer | Count | Representative CVEs | Fixed by a newer tag or base OS swap? |
| --- | --- | --- | --- |
| UBI9 rpm | 5 | `java-21-openjdk-headless` ×3, `libacl`, `pcre2` | Partly. 3 are resolved by updating rpms |
| Bundled jars | 12 | netty ×6, jackson ×3, postgresql-jdbc, mssql-jdbc, keycloak-services | **No** |

Those 12 split three ways in how they are addressed — the self-build did not "fix" all of
them. netty, jackson, and postgresql-jdbc are genuinely replaced by the jar overlay
described under "Differences from upstream" below. The 5 keycloak-services findings are
resolved by moving to 26.7.1 (see "We still move to 26.7.1" below). **The one mssql-jdbc
finding is not an overlay target** — it is actually a trivy false positive, and the risk
is accepted through an exception in `cve-exceptions.json` (see "Version management").

### Result of evaluating a newer tag first (image-authoring/README.md checklist step 1)

**The 12 jar findings are not resolved by raising the keycloak version.** keycloak
`26.6.4` and the latest `26.7.1` both have `quarkus.version` of `3.33.2.1`, and the
Quarkus 3.33.2.1 BOM pins `netty 4.1.135.Final` and `jackson-bom 2.21.2` (measured:
comparing keycloak's `pom.xml` across both tags plus `quarkusio/quarkus`
`bom/application/pom.xml@3.33.2.1`). The fixed versions for the blocking CVEs are netty
`4.1.136.Final` and jackson `2.21.4` — until the next Quarkus BOM lands, the upstream
image offers no path.

**A base OS swap does not touch jars either.** The CVEs are in jars shipped with the
distribution rather than in OS packages — structurally the same as the statically linked
Go modules in `cloudnative-pg` and `etcd`.

So **a self-build that replaces the jars directly is the only lever**. It is the same kind
of dependency override as the etcd image resolving its issue with one
`replace golang.org/x/text` line in `go.work`, and orchestration shares the one
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh).

### We still move to 26.7.1

`26.6.4` is vulnerable to 5 `keycloak-services` HIGH findings patched only in `26.7.1`
(and `26.6.5`) — CVE-2026-16102 / 16442 / 16443 / 15572 / 15573 (plus 2 MEDIUM, measured
from the GitHub Security Advisories). They simply were not in the trivy DB at scan time,
so the gate did not catch them.

The chart (`keycloakx`) **stays at 7.2.2, the latest.** The chart's
`appVersion: 26.6.4` is only the default when `image.tag` is unset
(`templates/statefulset.yaml` — `.Values.image.tag | default .Chart.AppVersion`), and we
specify the tag explicitly. Its appVersion trailing 26.7.1 is a release-cadence lag in the
codecentric chart, not a chart defect.

## Shape and base OS

**Shape: "reinstall upstream artifacts onto another distribution"** (the first of the two
shapes in image-authoring/README.md). Keycloak is not Maven-built from source — the tar.gz
upstream releases is used as-is, and only the runtime rootfs becomes SUSE.

| Item | Value |
| --- | --- |
| Distribution | `github.com/keycloak/keycloak/releases/download/$KEYCLOAK_VERSION/keycloak-$KEYCLOAK_VERSION.tar.gz` |
| Builder | `registry.suse.com/bci/bci-base:15.7` (zypper needed) |
| Final rootfs seed | `registry.suse.com/bci/bci-micro:15.7` |
| Final stage | `FROM scratch` plus the rootfs above |

### Background to the base OS decision (image-authoring/README.md rule 2)

Upstream uses a `ubi9` builder with a `ubi9-micro` final stage. Since every other
self-built image in this repository is SUSE BCI, and trivy's SLES 15.7 coverage is
confirmed by the gate's `CoverageProbe` positive control (rescanning with injected
sentinel packages), **consistency across images was prioritised over "stay as close to
upstream as possible"**.

**BCI 16.0 is available, but 15.7 is used — the newer one is older for this image.** All
the other required packages exist in 16.0, but its JDK lags.

| BCI | `java-21-openjdk-headless` |
| --- | --- |
| 15.7 | `21.0.12.0-150600.3.29.1` |
| 16.0 | `21.0.11.0-160000.2.1` |

`21.0.12` is the fixed version for CVE-2026-41254 and CVE-2026-47063, so going to 16.0
would have left two of the very blocking CVEs this image exists to remove. **When 16.0's
JDK catches up with 15.7, we move** — the re-measurement procedure is in the
`suse.build.env` comments.

### Why the rootfs is built with the "seed" method

Upstream's `ubi-null.sh` installs packages into an empty installroot and lays that rootfs
**over** `ubi9-micro`. Porting that structure to SUSE directly shadows `bci-micro`'s rpmdb
with the new one, and **micro's own packages disappear from the SBOM entirely** — that is
not fewer CVEs but a scanning blind spot, and a textbook case of what the gate warns
about: a base OS swap that only lowers the number.

So `bci-micro`'s filesystem is laid down as a seed and packages are installed on top with
`zypper --installroot`. The rpmdb is appended to micro's, so every OS package in the final
image appears in the SBOM. Always confirm this after the build (see "Building" below).

## Differences from upstream

Compared with upstream
[`quarkus/container/Dockerfile`](https://github.com/keycloak/keycloak/blob/main/quarkus/container/Dockerfile),
there are only three differences.

1. **The runtime rootfs is SUSE BCI** — see above. The package list
   (`RUNTIME_PACKAGES`) was derived from the 44 rpms in the upstream image's SBOM. `sed`
   and `grep` **are not optional** — `bin/kc.sh` is a `/bin/sh` script that uses `sed` in
   `esceval()` and `grep` for argument parsing, and `bci-micro` has no `sed`.
2. **The vulnerable jar overlay** (`overlay-jars.sh`) — jars in `lib/lib/main/` have
   **their contents, not their filenames**, replaced with fixed versions, because the
   Quarkus fast-jar classpath references the filenames directly. The targets are defined
   by the `*_OLD`/`*_VERSION` pairs in `suse.build.env`:

   | Group | Targets | Version |
   | --- | --- | --- |
   | `io.netty` | the whole family, 17 artifacts | `4.1.135.Final` → `4.1.136.Final` |
   | `com.fasterxml.jackson.core` | `jackson-core`, `jackson-databind` | `2.21.2` → `2.21.4` |
   | `org.postgresql` | `postgresql` | `42.7.11` → `42.7.12` |
   | `io.micrometer` | the whole family, 4 artifacts | `1.16.3` → `1.16.6` |

   For netty and micrometer the **whole family** is raised, not only the artifacts with a
   CVE — both are unsupported when artifact versions are mixed. jackson guarantees
   compatibility within 2.21.x and `jackson-annotations` is versioned separately at
   `2.21`, so only the two with CVEs are changed.

   netty, jackson, and postgresql-jdbc were part of the original 12-finding tally under
   "Why we build this ourselves". **micrometer was found in a later scan and added to the
   overlay** — include it when re-adding the tally (see "Version management" below).

   This is not disguise — trivy determines versions from `META-INF/maven/**/pom.properties`
   inside the jar (falling back to a sha1↔GAV index), so the SBOM reports the new version
   accurately, and the contents really are the new version.
3. **`bin/client/` removed** — `keycloak-admin-cli-<ver>.jar` is an uber-jar that shades
   jackson, so jar replacement cannot fix it (measured from the SBOM: the FilePath of
   `jackson-databind@2.21.2` is this file). Being a standalone CLI (`kcadm.sh` /
   `kcreg.sh`) that the server JVM never loads, it was removed from the hardened image.
   **This is the only functional difference from upstream** — if `kcadm` is needed in
   operations, use the upstream image as a separate container.

Running `kc.sh build` once in the final stage is not a difference — with no options, build
reproduces the pre-augmentation state of the release tar, and it exists to confirm at
build time that augmentation actually passes with the overlaid jars (not to produce an
optimised image).

## Version management

`APP_VERSION`/`KEYCLOAK_VERSION` and the `*_OLD`/`*_VERSION` jar versions are **not
tracked automatically.** Someone reading an upstream release and editing `suse.build.env`
to open a PR is itself the update trigger.

`overlay-jars.sh` **fails the build** if it finds no jar at any `*_OLD` version. That
prevents the state where upstream bumped a dependency, the script silently did nothing,
and the build "succeeded" with the CVEs still present.

**The mssql-jdbc CVE is not an overlay target.** It is included in the 12-finding tally
under "Why we build this ourselves", but it is actually a trivy false positive:
`mssql-jdbc-13.2.1.jre11.jar` is mis-decomposed into two components because of filename
truncation — the installed artifact is already the fixed version. There is no way to
remove it from the image side (the mssql driver is part of the Quarkus augmentation, so
deleting the file breaks the classpath), so the risk is accepted through the
`CVE-2025-59250` exception in the repository root's `cve-exceptions.json` — **the
self-build did not fix it.** When that exception expires, the gate blocks again and forces
a re-review.

The tally (under "Why we build this ourselves") and the overlay targets (under
"Differences from upstream") must always add up — update both whenever another CVE is
blocked.

**Suggested review cadence**: whenever the gate reports a blocking CVE for this image
again, or when Keycloak ships a release with an updated Quarkus BOM — **once the BOM moves
up and makes the overlay unnecessary, removing that spec always takes priority over
keeping this self-build.**

## Building

```sh
# local build (no push)
IMAGE=keycloak BASE_OS=suse bash scripts/build/build-hardened-image.sh /tmp/kc-out

# through to a registry push
IMAGE=keycloak BASE_OS=suse REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/kc-out
```

> **Running on an arm64 host (Apple Silicon)**: `linux/amd64` is emulated through QEMU, so
> the real startup in `verify.sh` is very slow — Quarkus augmentation alone takes ~100
> seconds and full startup can exceed 300. `verify.sh` waits 600 seconds by default,
> adjustable with `VERIFY_BOOT_TIMEOUT`. On a native amd64 runner it takes one to two
> minutes.

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.**

After the build, check:

1. The last line of `verify.log` is `VERIFY-OK`
2. The blocking findings in `cve-gate.md` — nothing beyond what is registered in the
   repository root's `cve-exceptions.json`
3. **The coverage self-check reads `ok`** (`none` means zero findings is not really zero —
   see "Do not take scanner output at face value" in
   `docs/image-authoring/scanner-caveats.md`)
4. **There is no rpmdb masking** — the OS package count in the SBOM should correspond to
   `bci-micro` alone plus what was installed. The upstream UBI9 image had 44 OS packages.
   If it dropped to single digits, the seed method did not work and the design must be
   revisited.

What `verify.sh` checks: the shell tools kc.sh uses, java 21, the `en_US.UTF-8` locale and
`Asia/Seoul` timezone, that `bin/client` is gone, **the `pom.properties` version inside
each overlaid jar** (the contents, not the filename — the same basis trivy uses), and,
after a real `start-dev` startup, the OIDC discovery response, admin token issuance, and
`GET /admin/realms`. External postgres, ingress, and clustering are outside this smoke
test's scope — real deployment verification follows a separate procedure.

### File layout

| File | Role |
| --- | --- |
| `suse.Dockerfile` | Build definition — a bci-base builder (rootfs assembly, unpacking the distribution, jar overlay) plus a `FROM scratch` final stage |
| `suse.build.env` | keycloak version, base images, runtime packages, jar overlay versions. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `overlay-jars.sh` | Replaces the vulnerable jars and removes `bin/client`. Builder-stage only (never run directly on the host) |
| `verify.sh` | Functional verification. Runs on the host under bash, combining guest shell injection, host-side python3 jar inspection, and a real startup |
| `image.env` | The default build variant — holds only `DEFAULT_BASE_OS=suse` |

There is only one base variant, so the filenames are fixed at `suse.*`.

### Tags

```
<registry>/keycloak:26.7.1-bci15.7-hardened-20260807
                     └ app ┘└ slug ┘└hardened┘└ build date ┘
```
