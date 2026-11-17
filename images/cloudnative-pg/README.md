# cloudnative-pg — CloudNativePG operator, self-built

English · [한국어](README.ko.md)

The CNPG operator (controller) image, compiled directly from upstream source.

> This image is an **unofficial rebuild** of CloudNativePG. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision and the costs accepted are in
[ADR 0002](../../docs/decisions/0002-cloudnative-pg-operator-self-build.md); the
procedure for adding a self-built image generally is owned by
[docs/image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves — and why differently from `cnpg-postgresql`

The CVEs blocking the upstream published image at the gate come from the versions of Go
modules statically linked into the binary, not from OS packages. The published image's
base is distroless (effectively zero OS packages), so **swapping the base OS alone does
not fix it** — only recompiling from source changes the version of the module carrying
the CVE. A self-build (compiling from source) is the only viable response.

This differs in nature from `cnpg-postgresql` (base OS swap plus zypper patching), but
**orchestration shares the one
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh).**
As long as this image honours that script's contract (`build.env` declaring
`DOCKERFILE`, `TARGET`, `BUILD_ARGS`, and `APP_VERSION`; `verify.sh` exiting with
`VERIFY-OK`), the script never needs to know the image type — reasoning in
[docs/image-authoring/](../../docs/image-authoring/README.md).

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Build method | The Dockerfile only COPYs binaries prebuilt by goreleaser | Compiles from source inside the Dockerfile with `go build` | The CVEs come from statically linked Go module versions, so reusing a prebuilt binary resolves nothing — it has to be recompiled |
| Architecture file layout | Multi-arch binaries plus symlinks (`manager_amd64`/`manager_arm64`) | A single-architecture binary COPYed directly to both `/manager` and `/operator/manager_amd64` | At runtime the operator builds its "available architectures" list from the presence of `operator/manager_<GOARCH>` — without that file, reconciliation fails with `invalid architecture`. Replacing the symlink with an equivalent file placement produces the same effect |
| Final runtime base | `gcr.io/distroless/static-debian13:nonroot` | `registry.suse.com/bci/bci-micro` | Self-built images in this repository are standardised on SUSE BCI ([ADR 0001](../../docs/decisions/0001-cnpg-postgresql-image.md)) |
| nonroot account | Provided by the base image | Added by the Dockerfile directly to `/etc/passwd` and `/etc/group` | Unlike `bci-base`, `bci-micro` has no nonroot (uid 65532) account |

The builder stage (Go compilation) uses the official `golang` image as-is — it does not
survive into the final image, only the compiled artifacts move forward, so it is not
subject to scanning or policy.

`SOURCE_COMMIT` is **not tracked automatically.** The current pin is the commit the
upstream release tag `v1.30.1` points at, and `APP_VERSION` names that same tag —
`APP_VERSION` is injected into the binary's reported version through ldflags, so the two
always move together (`verify.sh` checks only that the reported version is
`APP_VERSION`; it cannot check the pairing with the commit). As with the PGDG version in
`cnpg-postgresql`, someone resolving the next patch release tag with
`git ls-remote --tags` and editing `source.build.env` to open a PR is itself the update
trigger. Fall back to a maintenance-branch commit only when a fix is needed that no
release tag carries yet
([ADR 0002](../../docs/decisions/0002-cloudnative-pg-operator-self-build.md)) — and then
choose `APP_VERSION` so that it does not hide that the commit is not yet any release.

`GO_MODULE_UPGRADES` carries **only the fixes the release tag does not yet carry** — once
the pinned release's `go.mod` requires a fixed version, that entry is removed.
`GO_BUILDER_TAG` sits at or above what `go.mod` requires, raised to the stdlib CVE fix
point. `google.golang.org/grpc@v1.83.1` (CVE-2026-84304, 2026-09-03), forced while a
post-`v1.30.0` maintenance-branch commit was pinned, was dropped because `v1.30.1`'s
`go.mod` requires grpc `v1.84.0`. The CVEs this self-build **actually fixes**, from the
2026-11-17 scan of the `v1.30.1` build (no exceptions are registered for this image):

| Pin | CVEs resolved |
| --- | --- |
| `GO_MODULE_UPGRADES="golang.org/x/net@v0.62.0"` (`v1.30.1` ships `v0.58.0`) | HIGH CVE-2026-78661 · CVE-2026-78669, MEDIUM CVE-2026-78659 · CVE-2026-78660 · CVE-2026-78663 · CVE-2026-97032 · CVE-2026-97045 |
| `GO_BUILDER_TAG=1.26.11-trixie` (was `1.26.6`) | stdlib HIGH CVE-2026-111943 · CVE-2026-78667 · CVE-2026-78669 · CVE-2026-97031, 9 MEDIUM, LOW CVE-2026-56857, unrated CVE-2026-97054 |

`suggest-go-upgrades.py` weighs only HIGH and above and suggested `1.26.10`. The unrated
CVE-2026-97054 is fixed only in `1.26.11`, and an unrated CVE with a fixed version must be
dispositioned ([remediation-priority.md](../../docs/image-authoring/remediation-priority.md)),
so the pin went one patch higher. The key is declared even when empty, because
`suggest-go-upgrades.py --apply` **never adds a missing key** — without the declaration,
this image silently drops out of the automated fix.

**Suggested review cadence**: whenever the gate reports a blocking CVE for this image
again, or upstream ships a new patch release — if that release already resolves the CVEs
above, moving to it always takes priority over keeping this self-build.

## Building and verifying

```sh
# local build (no push)
IMAGE=cloudnative-pg BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=cloudnative-pg BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** The result is summarised as effective C/H in `/tmp/out/cve-gate.md`. Even
when the gate passes, check that `CoverageProbe` in `/tmp/out/trivy-reports/*.json` reads
`ok` — `none` means the zero findings were not a measurement but an absence of scanner
data for that distribution.

`verify.sh` checks that `manager version` output actually reflects the pinned commit and
`APP_VERSION` (confirming ldflags injection), that the image's `Config.User` is `65532:65532`
(nonroot), and that `--help` exits cleanly — actually starting the controller (which
needs a Kubernetes API) is outside this smoke test's scope. Real deployment verification
follows a separate procedure.

### Source and version management

| Item | Value |
| --- | --- |
| Source | `https://github.com/cloudnative-pg/cloudnative-pg.git` |
| Pinned commit | `SOURCE_COMMIT` in `source.build.env` — the commit the upstream release tag (`v${APP_VERSION}`) points at. **Not tracked automatically** |
| Forced module upgrades | `GO_MODULE_UPGRADES` in `source.build.env` — derived with `suggest-go-upgrades.py`. Holds a value only while the pin is ahead of the release |
| Builder | The official `golang` image (`GO_BUILDER_TAG` in `source.build.env`, at least what go.mod requires — derived with `suggest-go-upgrades.py`) |
| Final base | `registry.suse.com/bci/bci-micro` |

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and invokes `docker run --entrypoint /manager` directly (a superset of injecting a guest script — it still works when the final image has no shell) |

There is only one base variant, so the filenames are fixed at `source.*` — if variants
grow, as in `cnpg-postgresql`, they branch into
`<variant>.Dockerfile` / `<variant>.build.env`.

### Tags

```
<registry>/cloudnative-pg:1.30.1-security-hardened-20260730
                           └ app ─┘└ slug ┘└hardened┘└ build date ┘
```

The build date (`20260730`) is illustrative — the real value is filled in at build time.
