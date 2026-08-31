# 0011. Replace the infisical image with a source-compiled self-build

- Status: Accepted

## Decision

The `infisical/infisical` image (the Infisical backend, paired with the
`infisical-secrets-operator` image from [0010](0010-infisical-secrets-operator-self-build.md))
is built here as `infisical`. The build definition is
[images/infisical/](../../images/infisical/) — the commit the upstream `v0.164.1` tag
points at is compiled with:

- **Four features dropped entirely** (Oracle Instant Client, the bundled `infisical`
  CLI, smbclient, the from-source PQC OpenSSL build, and the Go "sidecar" binary for
  the Gateway on-prem relay) — each confirmed against upstream's own source to be
  reached only through a lazily-spawned child process or an explicitly gated code path,
  never touched at server bootstrap.
- **unixODBC's runtime library kept** — the one thing in that list that is not
  droppable, because the dynamic-secret provider registry statically imports the
  `odbc` npm package at server bootstrap regardless of configuration.
- **26 Node production dependencies force-upgraded** via npm's `overrides` mechanism.
- **The backend builder stage moved onto SUSE BCI** (not the official `node` image
  upstream uses), because the backend's production dependencies include native Node
  addons and cross-distro compilation risks a glibc ABI mismatch.
- **One CVE set (3 CVEs, in the Rust-native `@infisical/quic` addon) left as an
  approved exception** rather than fixed, because a real fix needs a Rust/napi-rs build
  pipeline this repository does not have.

## Context

dip-catalog's `infisical-standalone` chart was pinned to `v0.158.0` — six minor
versions behind upstream's `v0.164.1`. A live rescan of `v0.158.0` found 879 effective
HIGH/CRITICAL CVEs; rescanning `v0.164.1` found 354 — most of the reduction from
upstream's own churn, confirming a tag bump alone (lever 1) already does real work.
What's left on `v0.164.1` splits into two layers:

- **273 effective HIGH/CRITICAL from OS packages** (Debian 13.3, the `node:*-trixie-slim`
  base). Upstream is visibly fighting the same problem — `Dockerfile.standalone-infisical`
  itself contains a block of manual `apt-get install --only-upgrade` pins for known-CVE
  Debian packages. A base OS swap (lever 2, done here via self-build since design rule
  2 requires SUSE BCI for every image regardless) removes this entire layer, since the
  Debian packages simply cease to exist in the image.
- **81 effective HIGH/CRITICAL from application dependencies** (Node, Go, Rust) —
  compiled-in versions that a tag bump or base swap cannot reach.

## Rationale

- **Feature-drop safety was established by reading upstream's own source, not
  assumed.** Each dropped item was traced to its actual invocation site before being
  cut: `oracledb`'s thin-mode default and the try/caught `initOracleClient()` call
  (only for wallet mTLS); `smbclient`'s lazy `child_process` spawn; the PQC OpenSSL
  path's lazy `spawn()`; the Go sidecar plugin's `if (!opts.enabled) return` guard. None
  of these are touched by a default boot. This is the same standard
  [0006](0006-apisix-ingress-controller-self-build.md) and
  [0009](0009-kyverno-self-build.md) hold CVE evidence to, applied to a drop decision
  instead of a CVE claim.
- **unixODBC was not dropped, on the same evidentiary standard, in the other
  direction** — `providers/index.ts` statically imports `sap-ase.ts`/`sap-hana.ts`,
  both of which `import odbc from "odbc"` at the top level. That import chain runs at
  server bootstrap regardless of configuration, so `libodbc.so.2` must resolve or the
  server fails to boot. Confirmed by `verify.sh` actually booting the image.
- **The backend builder uses SUSE BCI, extending an existing rule rather than
  inventing one.** [builder-languages.md](../../docs/image-authoring/builder-languages.md)'s
  C/Lua section already states the principle ("keep the builder stage and the final
  stage on the same base and link dynamically" — no static glibc on SLE_BCI). Native
  Node addons (`argon2`, `bcrypt`, `odbc`) are compiled C/C++ code with the identical
  ABI concern; the frontend build, which produces no native code, keeps the normal
  default (the official `node` image) with no such risk. One cost of building on
  SLE_BCI specifically: its `python3` package is 3.6.15, too old for `node-gyp` (a
  `SyntaxError` on the walrus operator inside `node-gyp`'s bundled `gyp`) — resolved by
  installing `python313` and symlinking it to `/usr/bin/python3`, since SLE_BCI has no
  `update-alternatives` to do that automatically.
- **Force-upgrading 26 Node dependencies used npm's `overrides` as the direct analogue
  of `GO_MODULE_UPGRADES`** — same principle (minimum version on the currently-installed
  major line, derived from trivy's `FixedVersion`, not hand-picked), applied to a
  different package manager, with two npm-specific mechanics Go's force-upgrades never
  hit, both found by an actual build failing rather than anticipated in advance: npm
  refuses to `overrides` a package that is also a direct dependency (8 of the 26 go
  through a separate `NPM_DIRECT_UPGRADES` path instead, bumping `dependencies` plus a
  textually-matching self-referencing `overrides[pkg]["."]` entry to also dedupe nested
  copies — `npm ci` was replaced with `npm install` in both build stages for the same
  underlying reason); and forcing a nested dependency can break a *different* package
  that pins it deliberately (`oci-common@2.108.0`, direct, pinned `uuid@3.3.3` for its
  legacy `uuid/v1` subpath API, which uuid 9+ dropped entirely — crashed the server at
  boot with `ERR_PACKAGE_PATH_NOT_EXPORTED` until `oci-common` itself was bumped to its
  latest release). Two packages had no same-major fix available
  (`ip-address` 9.x -> 10.x, `sigstore` 2.x -> 4.x) and were raised across a major
  anyway; `verify.sh` booting the server end-to-end against a real Postgres (auto-migration
  included) and Redis is the check that this didn't break anything, filling the same
  role `go build` succeeding does for a Go force-upgrade.
- **`@infisical/quic`'s CVEs were not force-upgraded, because there was nothing to
  upgrade to** — the package is already pinned to its own latest published version.
  Registered as an exception in `cve-exceptions.json` instead of either leaving the
  gate red or standing up a new Rust/napi-rs build pipeline for a single dependency.
- **Functional verification goes further than this repository's other self-builds**,
  because it can: this app needs only Postgres and Redis, both trivial to run as
  throwaway containers for the duration of a smoke test, so `verify.sh` actually boots
  the built image against them and polls `/api/status` (the same endpoint the upstream
  Helm chart's readiness probe uses) rather than stopping at a CLI-only check. Real
  Kubernetes deployment verification alongside `infisical-secrets-operator` is still a
  separate, not-yet-done procedure.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  every self-build in this repository.
- **Four upstream features are unavailable by default** (Oracle DB dynamic secrets,
  SMB operations, the bundled CLI, PQC certificate support, and the Gateway on-prem
  relay). Each was confirmed to fail gracefully (a caught error or an ENOENT on spawn)
  rather than crash the server — but a deployment that later needs one of these would
  need to either drop back to upstream's image or extend this one.
- **The backend builder's move to SUSE BCI is a bigger divergence from upstream's own
  build than most self-builds here take** — upstream never tests a bci-base-compiled
  build of its native addons.
- **A person updates `SOURCE_COMMIT`, the npm `overrides` list, and re-evaluates the
  `@infisical/quic` exception.** None of it is tracked automatically.
- **The `@infisical/quic` exception is an accepted risk, not a fix** — it expires and
  forces a re-review; if Infisical ever publishes a newer `@infisical/quic`, or if this
  repository ever gains a Rust/napi-rs pattern, this should be revisited before the
  exception is simply renewed.

## Conditions for revisiting

- **If Infisical publishes a newer `@infisical/quic`** that resolves the `quiche`/`shlex`
  CVEs, bump to it and drop the exception.
- **If someone picks up the Rust patch this exception is standing in for** — an actual
  build attempt (not just "no toolchain here") found the real blocker: bumping
  `js-quic`'s vendored `quiche` from 0.18.0 to 0.24.9 requires also bumping its direct
  `boring` dependency 3 -> 4.3 (a native-library-link conflict, which resolves cleanly —
  BoringSSL itself compiles fine), but quiche's own public API changed across that gap
  — 9 fields dropped from `quiche::Stats`, 2 methods renamed, 2 methods with changed
  signatures, one mutability mismatch, all in `js-quic`'s
  `src/native/napi/connection.rs`. Full list and exact identifiers are in
  `images/infisical/README.md`'s "Exception" section — read that before re-investigating
  from scratch. Fixing it means patching `js-quic`'s Rust source to the new API and
  verifying actual QUIC behavior, not just a successful `cargo check` — upstream itself
  has not done this yet (confirmed against `js-quic`'s `master` as of this writing).
- **If a deployment needs one of the four dropped features** — reconsider building that
  specific toolchain back in (this is where the actual cost of dropping the Go sidecar
  or Oracle support would be paid) rather than reverting to the upstream image wholesale.
- **If unexpected runtime problems appear from compiling native Node addons on
  `bci-base`** — this would be the first sign the cross-base-matching approach needs
  reconsidering.
- **If separately managed deployment verification (installing alongside
  `infisical-secrets-operator` in a real cluster) finds a problem.**
