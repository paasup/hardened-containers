# 0009. Replace the kyverno image family with source-compiled self-builds

- Status: Accepted

## Decision

All seven images kyverno ships are built here: `images/kyverno/`,
`images/kyverno-cli/`, `images/kyvernopre/`, `images/background-controller/`,
`images/cleanup-controller/`, `images/reports-controller/`, and
`images/readiness-checker/`. Each compiles the commit the upstream `v1.19.0` tag points
at, reproducing the corresponding `./cmd/<binary>` build from kyverno's own `Makefile`
(`ko-build-*`/`ko-publish-*` targets) as a standard multi-stage Dockerfile instead of
`ko`. The final runtime base is SUSE BCI (`bci-micro`) — the same pattern as
[0006](0006-apisix-ingress-controller-self-build.md) (apisix-ingress-controller).

## Context

kyverno does not ship a Dockerfile at all — every one of its seven images is built by
[`ko`](https://ko.build) per `.ko.yaml`:

```yaml
defaultBaseImage: ghcr.io/wolfi-dev/static:alpine
```

That reference is a **floating tag, not a digest**. `ghcr.io/wolfi-dev/static:alpine` is
a community replacement for Chainguard's paywalled `cgr.dev/chainguard/static`
(`wolfi-dev/tools` repository), and its apko build config pins no specific Alpine
release — with no pin, apko defaults to Alpine's **rolling `edge` branch**. Alpine only
cuts a numbered stable release from edge twice a year (May/November); trivy's official
Alpine advisory database only covers those numbered releases, never `edge` itself.

This was confirmed directly, not inferred:

- `.ko.yaml` is byte-for-byte identical between kyverno `v1.18.2` (scans cleanly) and
  `v1.19.0` (blocked) — the difference is entirely in what the floating tag happened to
  resolve to at each build time, not anything in kyverno's own repository.
- Pulling `ghcr.io/wolfi-dev/static:alpine` and reading `/etc/os-release` gives
  `VERSION_ID=3.25.0_alpha20260805`, `PRETTY_NAME="Alpine Linux edge"` — a real Alpine
  edge pre-release marker, not corrupted metadata.
- `wolfi-dev/tools`' `release.yaml` rebuilds and re-publishes this tag **daily**
  (01:00 UTC cron), yet that `VERSION_ID` was observed unchanged across a full week
  (2026-08-20 through 2026-08-27) — packages update daily, but the pre-release version
  marker itself only advances when Alpine's own release engineering moves it.
- Running this repository's own coverage self-check
  (`scripts/gate/scan-image.sh`'s probe logic, ported from the same technique used in
  the dip-catalog `sbom.yml` pipeline) against that base image directly, on 2026-08-27,
  still returns `CoverageProbe: none` — trivy genuinely has no advisory data for this
  edge snapshot, confirmed by sentinel-package injection, not just an absence of raw
  findings.

Because the apko config carries no Alpine branch pin, this base will keep tracking
`edge` indefinitely — a future kyverno rebuild is not "one release away" from a scannable
base; it depends on Alpine's own edge-marker cadence, which is unpredictable in this
window. A newer kyverno tag does not fix it (`v1.19.0` is already the newest, and the
same unpinned base ships every version); neither does swapping which upstream tag we
track — the base is not something kyverno's own release picks.

## Rationale

- **The cause is entirely the build's base image, not OS packages installed on top of
  it or vulnerable application code** — kyverno's binaries are static Go binaries
  (`CGO_ENABLED=0` per its `Makefile`). Compiling them ourselves onto a base trivy can
  actually score is a complete fix, not a mitigation.
- **All seven images share one `.ko.yaml`/`defaultBaseImage`**, so all seven carry the
  identical gap — there is no image-specific investigation left to do; the same
  Dockerfile pattern (builder → `go build ./cmd/<binary>` → `bci-micro`) applies to each,
  differing only in which `cmd/` directory is compiled and the resulting binary name.
- **Functional verification passed** (binary present and executable, version output
  reflecting the pinned commit, `--help` exiting cleanly, running as the same nonroot
  UID/GID kyverno's upstream base assigns) — confirmed per image in
  `images/<name>/verify.sh`. The Kubernetes API server integration each controller needs
  to actually run is outside this smoke test's scope — deployment verification is a
  separate procedure.
- **`CGO_ENABLED=0` produces static binaries**, so `bci-micro` (no package manager, no
  shell tools beyond `bash`/coreutils) is sufficient — the same reasoning as
  [0006](0006-apisix-ingress-controller-self-build.md).

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost** — the same cost
  every self-build here accepts.
- **A person updates `SOURCE_COMMIT` on every kyverno release, across all seven
  `build.env` files.** Nothing here is auto-tracked; `GO_BUILDER_TAG` candidates come
  from `scripts/build/suggest-go-upgrades.py`, but applying one is still a person opening
  a PR.
- **This self-build must be re-evaluated at every kyverno release** — there is no
  "upstream fixed it upstream" path available, since the problem is not in kyverno's own
  repository. The condition for dropping the self-build is `wolfi-dev/static:alpine`
  pinning (or otherwise consistently resolving to) a numbered, trivy-covered Alpine
  release — not a kyverno version bump.
- **This is a configuration upstream does not test.** kyverno's own CI never builds on
  SUSE BCI; behavior differences (if any) are ours to catch.
- **Seven images means seven times the recurring maintenance** of a single-image
  self-build — accepted because all seven are required by the chart kyverno ships as one
  unit; self-building a subset would leave the chart's gate blocked on whichever images
  were skipped.

## Conditions for revisiting

- **If `ghcr.io/wolfi-dev/static:alpine` (or whatever base kyverno's `.ko.yaml` points at
  next) resolves to a numbered Alpine release trivy has data for, and stays there across
  a kyverno rebuild** — the upstream image becomes usable again, which takes priority
  over self-building.
- **If kyverno starts publishing pre-built images on a different, pinned base** (for
  example if they adopt a digest-pinned or Chainguard-licensed base) — re-evaluate
  against that new upstream artifact directly.
- **If unexpected runtime problems appear on `bci-micro`** for any of the seven —
  promote that image to `bci-base` or reconsider another BCI variant.
- **If deployment verification (a real Kubernetes cluster, separate from this
  repository) finds a problem with a self-built image.**
