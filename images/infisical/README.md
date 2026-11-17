# infisical — self-built

English · [한국어](README.ko.md)

The Infisical backend (`infisical/infisical`, the standalone server paired with
secrets-operator), compiled directly from upstream source. Which chart or environment
this image is used by, and how the tag gets rolled out, is not something this
repository knows — it deals only with how the image is made.

> This image is an **unofficial rebuild** of Infisical. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0011](../../docs/decisions/0011-infisical-self-build.md); image selection rules
and the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).
## Why we build this ourselves

`infisical/infisical` was in use at `v0.158.0`, and upstream's newest tag when this
self-build started was `v0.164.1`. Measured against that tag, the blocking CVEs split into
two layers, and that structure still holds:

- **OS-package layer (Debian, `node:*-trixie-slim`).** Upstream itself fights this inside
  `Dockerfile.standalone-infisical` with version-pinned manual upgrades of specific Debian
  packages (`apt-get install ... libc6=... libssl3t64=...`, a list that grows every
  release). Swapping the base to SUSE BCI removes this entire layer — the Debian packages
  simply no longer exist in the image.
- **Application-dependency layer (Node/Go/Rust).** Following upstream's newest tag is the
  biggest lever — upstream raises its dependencies often, so only what is left gets forced
  up with npm (see "Differences from upstream"). The Go sidecar is removed by dropping it
  (table below).

This image tracks the newest tag on the support line (`APP_VERSION`, currently
`v0.167.11`) — upstream supports only its newest tag, with no maintenance branch
(`SUPPORT_NOTE` in `image.env`).

The exact CVE list and counts are re-produced by `scan-image.sh` and `image-gate.py` on
every build — see "Building and verifying" below.

## Differences from upstream

### Dropped — each confirmed against upstream's own source before cutting

| Item | Why it's safe to drop |
| --- | --- |
| Oracle Instant Client | `oracledb` defaults to thin mode (pure JS, no client needed). `initOracleClient()` is only called for the OracleDB wallet-mTLS connection method, and its failure is caught, not fatal (`sql-connection-fns.ts`) |
| smbclient | Not an npm dependency — shelled out to via `child_process` only when that specific feature actually runs (`lib/smb-rpc/smb-rpc-client.ts`). Unrelated to server boot |
| Bundled `infisical` CLI | Upstream installs it by piping a remote setup script straight into a shell (this repo's rule 7 forbids that pattern regardless). A separate tool, unrelated to the server process |
| From-source PQC (post-quantum) OpenSSL build | `pqc-openssl.ts` only reaches `/opt/openssl-pqc/bin/openssl` through a lazy `spawn()` — unrelated to boot, only that one feature degrades |
| Go sidecar (`backend-go/`, the Gateway on-prem relay) | The `go-sidecar.ts` plugin is gated by `if (!opts.enabled) return` — the binary path is never touched unless Gateway is configured |

### Not droppable — unixODBC's runtime library

The dynamic-secret provider registry (`providers/index.ts`) statically imports
`sap-ase.ts` and `sap-hana.ts` at server bootstrap, and both `import odbc from "odbc"`
at the top level. That means **just starting the server** — with no SAP ASE/HANA
dynamic secret configured — loads the `odbc` native addon, which needs `libodbc.so.2`
to resolve. Without it, the server fails to boot at all. So unixODBC's runtime
(`libodbc2`) stays in the final image. FreeTDS itself (the actual TDS driver
`odbcinst.ini` points at) is only touched on an actual connection attempt, so it is
dropped.

Upstream itself stopped shipping the Go sidecar in `v0.167.0` — that row of the table is
now the same state as upstream rather than a difference from it.

### Runtime Node — upstream runs 26, this image runs SLE's `nodejs24`

| Item | Upstream | This image |
| --- | --- | --- |
| Runtime Node | Node 26 from `node:26.12.1-trixie-slim` (`backend/package.json` declares `engines.node >=26.0.0`) | SLE_BCI 15.7's OS package `nodejs24` (24.22.1) |
| `npm` for the backend build | Node 26's bundled npm | SLE's `npm24` (11.19.1 — satisfies upstream's `engines.npm >=11.10.0`) |

Upstream moved to Node 26 in `v0.166.1`, but **SLE_BCI has no `nodejs26` package on either
15.7 or 16.0** (both stop at `nodejs22`/`nodejs24`, measured 2026-11-17). Candidates
compared:

- **Run on SLE's `nodejs24` — chosen.** Keeps the runtime Node on the OS-package path the
  vendor patches ([builder-languages.md](../../docs/image-authoring/builder-languages.md)
  "Node"). The `engines` mismatch is only an `EBADENGINE` warning from `npm install`, not
  an error. The Node 26 upgrade commit (`6409dce`) changed build tooling (tsup -> tsdown,
  ts-node -> tsx) and typings; no Node-26-only runtime API showed up in it — but that is
  a reading, and the actual evidence is `verify.sh` running this image from admin
  bootstrap through a secret write and read-back and passing.
- **Install nodejs.org's Node 26 tarball on BCI — rejected.** Checksum verification is
  possible, but the runtime Node then leaves the OS-package update path, its pin has to be
  raised by hand indefinitely, and the scanner sees it as a binary rather than an OS
  package.
- **Stay on a Node 22-era tag (`v0.164.1`) — rejected.** It is off the support line (only
  the newest tag is supported), and it keeps the three unfixable `@infisical/quic` CVEs
  (below) on exceptions.

**Condition for switching**: when SLE_BCI ships `nodejs26`, move `NODEJS_PKG`,
`NODEJS_DEVEL_PKG` and `NPM_PKG` to it. If upstream starts using an API Node 24 lacks
before then, `verify.sh` is what must catch it — if it breaks there, this decision is
reopened. Decision record: [ADR 0013](../../docs/decisions/0013-infisical-runtime-node24.md).

### Builder stages — only the backend uses SUSE BCI

| Stage | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Frontend builder | Official `node` image | Same (official `node` image, matching upstream's own pin) | Output is static Vite assets only — no native binaries, no ABI concern, so it keeps the normal default (official language image) |
| Backend builder | Official `node` image (Debian) | `registry.suse.com/bci/bci-base` (same base as the final stage) + `gcc14-c++` | The backend's production dependencies include native Node addons (`argon2`, `bcrypt`, `odbc`, `pkcs11js`). Compiling on Debian and running on SUSE BCI risks a glibc ABI mismatch — the C/Lua rule in [builder-languages.md](../../docs/image-authoring/builder-languages.md) ("keep the builder stage and the final stage on the same base and link dynamically"), applied to native Node addons |

Two measured traps in the backend builder:

- **SLE_BCI's `python3` package (3.6.15) is too old for `node-gyp`** — `node-gyp`'s
  bundled `gyp` fails with a `SyntaxError` on the walrus operator. `python313` is
  installed and symlinked to `/usr/bin/python3` (SLE_BCI has no `update-alternatives`).
- **SLE 15's default `gcc-c++` is GCC 7, which does not know the `-std=gnu++20` Node 24's
  headers require** (`pkcs11js` fails with `unrecognized command line option
  '-std=gnu++20'`). This never surfaced under Node 22. `gcc14-c++` is installed and
  selected through `CC`/`CXX` (`BUILDER_GCC_VERSION`). The runtime `libstdc++6` is 16.x,
  so the addons GCC 14 produces resolve their symbols against it.

### Force-upgraded Node dependencies (`NPM_DIRECT_UPGRADES` + `NPM_OVERRIDES`)

At `v0.167.11`, upstream's own lockfile already carries fixed versions of most packages
this image used to force up. So the lists were rebuilt from empty and re-measured — left
as they were, `NPM_OVERRIDES`' exact versions would have **pulled packages back down**
below what upstream already ships (e.g. the old pin `undici@7.29.0` against upstream's
lockfile `7.30.1`). What remains is three same-major fixes for MEDIUM/LOW findings
(values and reasons in `source.build.env`).

| Package | Upstream lockfile | This image |
| --- | --- | --- |
| `node-forge` | 1.4.2 | 1.4.3 |
| `fast-xml-parser` | 5.7.2 | 5.12.x |
| `@opentelemetry/instrumentation-http` | 0.220.0 | 0.222.0 |

Values come from trivy's `FixedVersion`, taking the minimum fixed version **on the
installed major line**. npm traps Go's force-upgrades never hit, each measured by a build
failing:

- **npm refuses to `overrides` a package that is also a direct dependency**
  (`npm error EOVERRIDE`). Hence two lists — `NPM_DIRECT_UPGRADES` bumps `dependencies`
  itself, and to also dedupe *nested* copies adds a self-referencing
  `overrides[pkg]["."]` with the same range (the EOVERRIDE check is a **textual** match,
  not a semver one, so the `^` must match too). `npm ci` refuses to run once `npm pkg set`
  has put `package.json` out of sync with the lockfile (`EUSAGE`), so `npm install` is used.
- **Where upstream's `package.json` already overrides the package with a plain string,
  `overrides[pkg]["."]` cannot be set** (`npm error EOVERRIDEVALUE` — `fast-xml-parser` is
  one). That string override is replaced with the same range instead. The loops run under
  `set -e` — before, an `npm pkg set` failing mid-loop could be swallowed silently.
- **Forcing a nested dependency can break a different package that pins it on purpose**
  (measured on an earlier tag: raising `uuid` alone broke `oci-common`'s legacy `uuid/v1`
  subpath import with `ERR_PACKAGE_PATH_NOT_EXPORTED` at boot — caught by `verify.sh`).
- Both lists apply **only to the two backend stages**. The frontend runs `npm ci` against
  upstream's lockfile as-is; its output is static assets that do not show up in the final
  image's SBOM.

### Resolved exception — `@infisical/quic` (Rust native addon)

At `v0.164.1`, the prebuilt `@infisical/quic` 1.0.8 (the QUIC transport of Gateway v1)
bundled `quiche` 0.18.0 and `shlex` 1.1.0, carrying three CVEs that could not be fixed
(CVE-2024-58266 CRITICAL, CVE-2025-7054 and CVE-2024-1765 HIGH) and were accepted as
`cve-exceptions.json` exceptions (it was that package's newest version, and moving
`js-quic` to `quiche` 0.24 needed a Rust source patch — the investigation is in
[ADR 0011](../../docs/decisions/0011-infisical-self-build.md) and this file's git
history).

**Upstream dropped that dependency in `v0.165.13` when it deprecated Gateway v1** ("deprecate
gateway v1"). Neither `v0.167.11`'s lockfile nor this image's SBOM contains
`@infisical/quic`, `quiche` or `shlex`. So these three were not accepted as exceptions;
they were **actually resolved by the release bump**. The corresponding exception entries,
which expired on 2026-11-07, have no reason to be renewed.

## Version management

**Pins not tracked automatically** — a person editing `source.build.env` and opening a PR
is itself the update trigger (there is no semi-automatic tool like
`suggest-go-upgrades.py` for this image).

| Key | What | When to raise it |
| --- | --- | --- |
| `APP_VERSION`, `SOURCE_COMMIT` | Upstream tag and its commit | When a new tag ships — only the newest is supported, so waiting leaves the support line |
| `NODE_BUILDER_TAG` | Frontend builder | Follows the `node:` tag in upstream's `Dockerfile.standalone-infisical` |
| `NODEJS_PKG`, `NODEJS_DEVEL_PKG`, `NPM_PKG` | Runtime/build Node | When SLE_BCI ships `nodejs26` ("Runtime Node" above) |
| `BUILDER_GCC_VERSION` | Compiler for the backend addons | Only when the build demands it |
| `NPM_DIRECT_UPGRADES`, `NPM_OVERRIDES` | Force-upgrade lists | **Re-measured from empty on every tag bump** — check first whether upstream's lockfile is already ahead |

**Exceptions**: no `cve-exceptions.json` entry applies to this image now. What was fixed by
the upgrades and tag bump above is distinct from what is accepted through an exception —
the latter is zero as of this build.

**Deferred**: `glob` 10.5.0 (CVE-2026-118773) and `minimatch` 9.0.9 (CVE-2026-118764),
both MEDIUM. The only fixed versions are `glob` 14 and `minimatch` 11, across a major —
upstream deliberately holds `glob` at 10 (`overrides.glob = ^10.5.0`), and `rimraf@3` and
`@octopusdeploy/api-client` use the glob 7/8 APIs. When upstream lifts that override, the
next rebuild follows.

**Condition for stopping the self-build**: as long as upstream's image is Debian-based the
OS-package layer remains, so this does not apply until upstream moves to a base that passes
this repository's bar.

## Building and verifying

```sh
# local build (no push)
IMAGE=infisical BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=infisical BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

This image's `verify.sh` differs from this repository's other single-binary self-builds —
all the app needs is Postgres and Redis, so it runs both as throwaway containers and boots
the image against them for real.

1. It polls `/api/status` — the endpoint the upstream Helm chart's readiness probe uses —
   until it returns 200, which means the auto-migration on boot ran to completion against
   a real Postgres.
2. It then does what an operator does first on a fresh instance: `/api/v1/admin/bootstrap`
   creates the admin, organization and a machine identity (password hashing — the native
   addons), and with that token it creates a project, writes a secret and reads it back,
   checking the value matches (the KMS envelope-encryption path). This step is the real
   evidence behind running on `nodejs24` instead of Node 26 (above).

Read the result from `/tmp/out/cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `/tmp/out/trivy-reports/*.json` reads `ok`. The verdict logic is
described in [docs/image-authoring/](../../docs/image-authoring/README.md).

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — frontend (official node) + backend (SUSE BCI) builders, SUSE BCI (`bci-base`) final stage |
| `source.build.env` | Pinned commit, versions, builder image tags, the npm `NPM_DIRECT_UPGRADES`/`NPM_OVERRIDES` lists. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification — boots the image against real throwaway Postgres+Redis, checks `/api/status`, then runs admin bootstrap -> project -> secret write and read-back |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/infisical:v0.167.11-security-hardened-20261117
                      └  app   ┘└ slug ┘└hardened┘└ build date ┘
```

## Not done yet — deployment verification

`verify.sh` confirms the server boots and exchanges a secret over the API against a
standalone Postgres/Redis, but installing this alongside `infisical-secrets-operator` in a
real Kubernetes cluster and confirming an `InfisicalSecret` actually syncs has not been
done yet.
