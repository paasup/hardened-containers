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

Keycloak ships its jars statically inside the upstream distribution, and their versions
are pinned by the Quarkus BOM Keycloak follows. So when a blocking CVE appears, **each
layer has a different remedy.**

| Layer | Remedy | Fixed by a newer tag or base OS swap? |
| --- | --- | --- |
| OS packages (JDK, glibc, …) | a rebuild makes zypper install the current patch | Yes — a base OS matter |
| Keycloak's own code (`keycloak-services`, …) | raise `KEYCLOAK_VERSION` | Yes — a newer tag |
| Bundled jars pinned by the Quarkus BOM | **none** until a Keycloak release raises the BOM | **No** |

The third layer is why this image is built here. A base OS swap does not touch jars
(structurally the same as the statically linked Go modules in `cloudnative-pg` and
`etcd`), and a newer tag only helps once the BOM moves. The jar overlay fills the gap in
between — the same kind of dependency override as the etcd image adding one `replace`
line to `go.work`, and orchestration shares the one
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh). The
measurement that first led here (comparing the Quarkus BOMs of 26.6.4 and 26.7.1) is in
[ADR 0008](../../docs/decisions/0008-keycloak-self-build.md).

### Moving to the 26.8 line

Keycloak maintains only the current minor (`SUPPORT_NOTE` in `image.env`). 26.7 went
end-of-life on 2026-10-01, when 26.8.0 shipped, and `check-support-line.py` failed daily
from then on. Because this moves the line, it was handled as a migration rather than a
pin raise — what actually changed upstream was established first.

- **The container contract is unchanged.** Upstream `quarkus/container/Dockerfile` and
  `ubi-null.sh` are identical between 26.7.2 and 26.8.2 (still
  `java-21-openjdk-headless`), and `bin/kc.sh` is byte-for-byte the same. So
  `RUNTIME_PACKAGES`, `USER` and `ENTRYPOINT` are untouched.
- **Quarkus moves from `3.33.3.1` to `3.40.1.1`,** and that resolves most of the previous
  overlay targets and of the jars the rescan newly flagged in the base distribution
  (measured from 26.8.2's `lib/lib/main`):

  | jar | 26.7.2 | 26.8.2 | Result |
  | --- | --- | --- | --- |
  | netty family | `4.1.136.Final` (overlaid to `4.1.137.Final`) | `4.1.139.Final` | overlay removed |
  | jackson-core/databind | `2.21.5` | `2.21.7` | resolved |
  | bcprov-jdk18on | `1.84` | `1.86` | resolved |
  | freemarker | `2.3.32` | `2.3.35` | resolved |
  | mssql-jdbc | `13.2.1.jre11` | `13.4.0.jre11` | see "Version management" |
  | opentelemetry-api | `1.57.0` (overlaid to `1.62.0`) | `1.62.0` | below the fix `1.67.0` — overlay removed, **deferred** (see "Differences from upstream") |
  | guava | `33.5.0-jre` | `33.6.0-jre` | below the fix `33.7.2-jre` — **new overlay** |
  | mariadb-java-client | `3.5.9` | `3.5.10` | below the fix `3.5.11` — **new overlay** |

- **26.8.2 itself fixes a large batch of Keycloak-code CVEs** (the "Security fixes" in its
  release notes — SAML parser DoS, account takeover, forged DCR claims, and more). They
  are not in trivy's database, so the gate never catches them, but the risk is real and
  the 26.7 line no longer receives backports.

guava is blocking (HIGH) while mariadb is MEDIUM/LOW, but a rebuild forced by a blocking
CVE takes every fixable finding with it
([remediation-priority.md](../../docs/image-authoring/remediation-priority.md), "The unit
of cost is a rebuild, not a CVE"). opentelemetry-api (MEDIUM) was attempted for the same
reason, but broke the real startup and was deferred — see below.

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

**BCI 16.0 is available, but 15.7 is used.** When this was adopted, 16.0's
`java-21-openjdk-headless` lagged 15.7's (the comparison is in ADR 0008). Re-measured in
2026-11, both have caught up to `21.0.12.1` (15.7: `21.0.12.1-150600.3.32.1`, 16.0:
`21.0.12.1-160000.1.1`), so **moving to 16.0 is now worth reviewing** — but it was kept
out of this migration. A base OS move also brings the rest of the package names, the tag
slug (`TAG_SLUG`) and an update to ADR 0008 with it, and is a separate decision. The
re-measurement procedure is in the `suse.build.env` comments.

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
there are only three differences. (Fetching the tar.gz and checking it with
`sha256sum -c` against `KEYCLOAK_SHA256` committed in `suse.build.env`, rather than
upstream's bare `ADD`, follows the supply-chain rule — CLAUDE.md design rule 7 — and
produces the same result.)

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
   | `com.google.guava` | `guava` | `33.6.0-jre` → `33.7.2-jre` |
   | `org.mariadb.jdbc` | `mariadb-java-client` | `3.5.10` → `3.5.11` |

   Both are single artifacts raised within the same major — the `failureaccess` that
   guava `33.7.2-jre` requires is `1.0.3`, the same as for `33.6.0-jre`.

   **opentelemetry is not overlaid (deferred).** The fixed version of
   `opentelemetry-api` is `1.67.0`; its POM requires `context 1.67.0`, which requires
   `common 1.67.0`, so all three were raised together and built. Augmentation
   (`kc.sh build`) passed, but **the real startup with tracing enabled died unable to find
   `io/opentelemetry/api/internal/ConfigUtil`** — in 1.67 that class moved to
   `io.opentelemetry.common.impl`, and `InstrumentationUtil` also left `api.internal`,
   while the SDK and exporters Quarkus 3.40.1.1 ships (`1.62.0`) and
   `opentelemetry-instrumentation-api 2.28.1` link against exactly those `api.internal`
   classes (measured from the bytecode of the distribution's jars). Fixing it would mean
   raising the whole SDK, exporter and instrumentation stack beyond what the Quarkus
   extension was built against — not a risk worth taking for one MEDIUM. Per "the blocking
   fix is never held hostage" (remediation-priority.md), the image ships with the blocking
   fixes and this CVE is **deferred**. It is resolved once a Keycloak release's Quarkus BOM
   raises OpenTelemetry to `1.67.0` or later. (The `api`-only overlay on 26.7.x was only
   ever verified with a tracing-disabled startup — which is why `verify.sh` now starts
   with tracing enabled.)

   netty, jackson-core/jackson-databind, postgresql-jdbc, and micrometer were overlay
   targets here at one point, but were removed once Keycloak raised its Quarkus BOM and the
   base distribution started shipping the fixed versions (netty in 26.8.2, the rest in
   26.7.2).

   This is not disguise — trivy determines versions from `META-INF/maven/**/pom.properties`
   inside the jar (falling back to a sha1↔GAV index), so the SBOM reports the new version
   accurately, and the contents really are the new version.
3. **`bin/client/` removed** — `keycloak-admin-cli-<ver>.jar` is an uber-jar that shades
   its dependencies (jackson and others), so jar replacement cannot fix it (measured from
   the SBOM at adoption: the FilePath of `jackson-databind@2.21.2` is this file). Being a standalone CLI (`kcadm.sh` /
   `kcreg.sh`) that the server JVM never loads, it was removed from the hardened image.
   **This is the only functional difference from upstream** — if `kcadm` is needed in
   operations, use the upstream image as a separate container.

Running `kc.sh build` once in the final stage is not a difference — with no options, build
reproduces the pre-augmentation state of the release tar, and it exists to confirm at
build time that augmentation actually passes with the overlaid jars (not to produce an
optimised image).

## Version management

The following values are **not tracked automatically** — someone reading an upstream
release and editing `suse.build.env` to open a PR is itself the update trigger.

| Value | Note |
| --- | --- |
| `APP_VERSION`, `KEYCLOAK_VERSION` | Always equal. The line must match `SUPPORT_LINE` (`26.8`) in `image.env` |
| `KEYCLOAK_SHA256` | Changes with the version. Computed from the downloaded tar.gz and cross-checked against the `.sha1` asset on the upstream release |
| `GUAVA_OLD`/`GUAVA_VERSION`, `MARIADB_OLD`/`MARIADB_VERSION` | Overlay pairs |
| `BUILDER_BASE`, `MICRO_BASE` | BCI version — see "Background to the base OS decision" above |

`check-support-line.py` only reports whether the line is end-of-life (exit 2) or behind
within the line (exit 1). Following patch releases within the line is also done by a
person.

`overlay-jars.sh` **fails the build** if it finds no jar at any `*_OLD` version. That
prevents the state where upstream bumped a dependency, the script silently did nothing,
and the build "succeeded" with the CVEs still present. Raising `KEYCLOAK_VERSION` usually
hits this failure first — if the jar's new base version is at or past the fixed version,
delete the spec; otherwise move only `*_OLD`.

**Remediations are kept apart.** This image's CVEs are handled four ways:

- **Fixed by the overlay** — the jars in the table under "Differences from upstream".
- **Fixed by raising the Keycloak version** — the jars the base resolved in the table
  under "Moving to the 26.8 line", and Keycloak's own code CVEs.
- **Deferred** — the opentelemetry-api MEDIUM (fixed in `1.67.0`). The reason is under
  "Differences from upstream" above. Collected when the next Keycloak release raises the
  BOM.
- **Risk accepted through an exception** — `CVE-2025-59250` (mssql-jdbc) in
  `cve-exceptions.json`. **The self-build did not fix it.** It was a trivy false positive:
  trivy mis-decomposed the one file `mssql-jdbc-13.2.1.jre11.jar` into two components
  (`13.2.1.jre11` / `13.2.1`) because of filename truncation — the installed artifact was
  already the fixed version. 26.8.2 ships `13.4.0.jre11`, and on the 26.8.2 build's gate
  this CVE **no longer matches** — trivy still decomposes the file into two components
  (`13.4.0.jre11` / `13.4.0`), but both are outside the vulnerable range. So this image no
  longer needs the exception (retiring the entry belongs to the exception-review
  procedure). The decomposition habit itself remains, so re-check whenever the mssql-jdbc
  version changes.

**When to stop self-building**: once a Keycloak release's Quarkus BOM raises every
overlay target to its fixed version or later, the overlay is empty, and the only
differences left are the SUSE BCI rootfs and the removal of `bin/client`. **Once the BOM
moves up and makes an overlay unnecessary, removing that spec always takes priority over
keeping this self-build.** Review it whenever the gate reports a blocking CVE for this
image again, or when Keycloak ships a release with an updated Quarkus BOM.

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
after a real `start-dev --tracing-enabled=true` startup, the OIDC discovery response,
admin token issuance, and `GET /admin/realms`. Because tracing is on, the startup and
those requests really load the OpenTelemetry stack, and the server log is then checked for
class-linkage errors (`NoSuchMethodError`, `NoClassDefFoundError`, …) — a startup with
tracing off never touches that stack and misses incompatibilities like the opentelemetry
overlay above. No OTLP collector is started — export-failure warnings are
expected.

What it does **not** check: the path that connects to a real database through the mariadb
driver (the startup uses the dev-file DB, so the mariadb driver is never loaded — only the
overlaid jar's content version and augmentation passing are confirmed), and external
postgres, ingress, and clustering. Real deployment verification follows a separate
procedure.

### File layout

| File | Role |
| --- | --- |
| `suse.Dockerfile` | Build definition — a bci-base builder (rootfs assembly, unpacking the distribution, jar overlay) plus a `FROM scratch` final stage |
| `suse.build.env` | keycloak version, base images, runtime packages, jar overlay versions. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `overlay-jars.sh` | Replaces the vulnerable jars and removes `bin/client`. Builder-stage only (never run directly on the host) |
| `verify.sh` | Functional verification. Runs on the host under bash, combining guest shell injection, host-side python3 jar inspection, and a real startup |
| `image.env` | The default build variant (`DEFAULT_BASE_OS=suse`), the root README grouping (`CATEGORY`), and the upstream support line (`SUPPORT_*`) |

There is only one base variant, so the filenames are fixed at `suse.*`.

### Tags

```
<registry>/keycloak:26.8.2-bci15.7-hardened-20261117
                     └ app ┘└ slug ┘└hardened┘└ build date ┘
```
