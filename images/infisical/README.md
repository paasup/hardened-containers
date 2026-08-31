# infisical — self-built

English · [한국어](README.ko.md)

The Infisical backend (`infisical/infisical`, the standalone server paired with
secrets-operator), compiled directly from upstream source. Which chart or environment
this image is used by, and how the tag gets rolled out, is not something this
repository knows — it deals only with how the image is made (for reference, this image
is consumed by the sibling repository `dip-catalog`'s `infisical-standalone` chart).

> This image is an **unofficial rebuild** of Infisical. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0011](../../docs/decisions/0011-infisical-self-build.md); image selection rules
and the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

`infisical/infisical` was pinned at `v0.158.0` in dip-catalog — six minor versions
behind upstream's latest (`v0.164.1`) — so a tag bump alone already does a lot of the
work. This image targets the latest tag (`v0.164.1`).

Measured against that latest tag, the blocking CVEs split into two layers:

- **OS-package layer (Debian 13.3, `node:22.22.0-trixie-slim`) — 273 effective
  HIGH/CRITICAL.** Upstream itself is fighting this same problem inside
  `Dockerfile.standalone-infisical` with manual point-patches (`apt-get install
  --only-upgrade libgnutls30t64=... libc6=... ...`). Swapping the base to SUSE BCI
  removes this entire layer — the Debian packages simply no longer exist in the image.
- **Application-dependency layer (Node/Go/Rust) — 81 effective HIGH/CRITICAL.** Most of
  it (26 node-pkg packages) is resolved by force-upgrading via npm `overrides` (see
  "Differences from upstream" below). The Go sidecar's and the Rust native addon's CVEs
  went away by dropping those components entirely (see below) — with one exception,
  `@infisical/quic`.

The exact CVE list and counts are re-produced by `scan-image.sh` and `image-gate.py` on
every build — see "Building and verifying" below.

## Differences from upstream

### Dropped — each confirmed against upstream's own source before cutting

| Item | Why it's safe to drop |
| --- | --- |
| Oracle Instant Client | `oracledb` ^6.4.0 defaults to thin mode (pure JS, no client needed). `initOracleClient()` is only called for the OracleDB wallet-mTLS connection method, and its failure is caught, not fatal (`sql-connection-fns.ts`) |
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

### Builder stages — only the backend uses SUSE BCI

| Stage | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Frontend builder | Official `node` image | Same (official `node` image, matching upstream's own pin) | Output is static Vite assets only — no native binaries, no ABI concern, so it keeps the normal default (official language image) |
| Backend builder | Official `node` image (Debian) | `registry.suse.com/bci/bci-base` (same base as the final stage) | The backend's production dependencies include native Node addons (`argon2`, `bcrypt`, `odbc`). Compiling on Debian and running on SUSE BCI risks a glibc ABI mismatch — the same principle as the C/Lua rule in [builder-languages.md](../../docs/image-authoring/builder-languages.md) ("keep the builder stage and the final stage on the same base and link dynamically"), extended to native Node addons |

### Force-upgraded Node dependencies (26, `NPM_DIRECT_UPGRADES` + `NPM_OVERRIDES`)

Like `golang.org/x/*` modules, most `node-pkg` findings are **transitive** dependencies.
npm's equivalent of `go get` is the `overrides` field (`npm pkg set
overrides[<pkg>]=<version>`, then `npm install`). Values are not hand-picked — they come
from trivy's `FixedVersion`, taking the minimum version **on the same major line already
installed** (two exceptions forced onto a newer major because no same-major fix exists:
`ip-address` -> 10.x, `sigstore` -> 4.x). Exact values and the CVEs behind them are in
`source.build.env`.

Two things this repository's Go-based force-upgrades never have to handle, both
measured by an actual build failing:

- **npm refuses to `overrides` a package that is also a direct dependency**
  (`npm error EOVERRIDE`) — 8 of the 26 (`@fastify/static`, `axios`, `dd-trace`,
  `nanoid`, `nodemailer`, `oci-common`, `scim-patch`, `uuid`) are direct dependencies of
  `backend/package.json`, so they go through `NPM_DIRECT_UPGRADES` instead (bumps
  `dependencies` itself, plus a matching self-referencing `overrides[pkg]["."]` entry to
  also dedupe every *nested* copy other packages pull in — npm's EOVERRIDE check is a
  **textual** comparison against `dependencies`, not a semver one, so the two values
  must match character-for-character, `^` included). `npm ci` was replaced with
  `npm install` in both build stages for the same reason: `npm ci` refuses to proceed
  once `npm pkg set` has put `package.json` out of sync with the committed
  `package-lock.json`, by design.
- **Forcing a nested dependency can break a *different* package that pins it on
  purpose.** `oci-common@2.108.0` (direct, the OCI Vault integration) pins
  `uuid@3.3.3` and imports uuid's legacy `uuid/v1` subpath — removed entirely from
  uuid's `package.json` `exports` map starting with uuid 9. Forcing `uuid` to 11.1.1
  without also bumping `oci-common` crashed the server at boot
  (`ERR_PACKAGE_PATH_NOT_EXPORTED`, caught by `verify.sh`, not by the gate). Bumping
  `oci-common` to its own latest (2.140.0, which already uses modern `uuid` itself)
  resolved both the crash and the nested CVE at once — this is why `oci-common` is in
  `NPM_DIRECT_UPGRADES` even though nothing scanned it directly.
- **SLE_BCI's `python3` package (3.6.15) is too old for `node-gyp`** — compiling the
  native addons (`odbc`, `argon2`, `bcrypt`) needs Python 3.8+; 3.6 fails with a
  `SyntaxError` on the walrus operator inside `node-gyp`'s bundled `gyp`.
  `source.Dockerfile`'s backend builder installs `python313` and symlinks it to
  `/usr/bin/python3` (SLE_BCI has no `update-alternatives` to do this automatically).

### Exception — `@infisical/quic` (Rust native addon)

A genuine production dependency for the Gateway/QUIC transport, shipped as a prebuilt
platform binary via npm `optionalDependencies` (no Rust toolchain needed to consume
it). The problem: it's already pinned to its **latest published version** (1.0.8,
released 2025-03), and that version still carries 3 CVEs (1 CRITICAL, 2 HIGH —
`shlex`, `quiche`) — there's no newer version to move to. Actually fixing them means
rebuilding this addon from Infisical's own Rust source, and this repository has no
Rust/napi-rs build pattern yet. Registered as an exception in `cve-exceptions.json` —
rationale: upstream's own package, no newer version published, a proper fix would
require a toolchain this repo doesn't have.

## Building and verifying

```sh
# local build (no push)
IMAGE=infisical BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=infisical BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

This image's `verify.sh` differs from this repository's other single-binary
self-builds — since all the app actually needs is Postgres and Redis, it really spins
both up as throwaway containers and boots the image against them, polling the same
`/api/status` endpoint the upstream Helm chart's readiness probe uses until it returns
200. The auto-migration-on-boot step (`auto-start-migrations.ts` upstream) running to
completion against a real Postgres is itself a meaningful check that the npm
`overrides` force-upgrades didn't break dependency resolution or break the app at
runtime.

Read the result from `/tmp/out/cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `/tmp/out/trivy-reports/*.json` reads `ok`. The verdict logic is
described in [docs/image-authoring/](../../docs/image-authoring/README.md).

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — frontend (official node) + backend (SUSE BCI) builders, SUSE BCI (`bci-base`) final stage |
| `source.build.env` | Pinned commit, versions, builder image tags, the npm `NPM_DIRECT_UPGRADES`/`NPM_OVERRIDES` lists. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification — boots the image against real throwaway Postgres+Redis and polls `/api/status` |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/infisical:v0.164.1-security-hardened-20260831
                      └  app  ┘└ slug ┘└hardened┘└ build date ┘
```

## Not done yet — deployment verification

`verify.sh` confirms the server boots and migrates against a standalone Postgres/Redis,
but installing this alongside `infisical-secrets-operator` in a real Kubernetes cluster
and confirming an `InfisicalSecret` actually syncs has not been done yet.
