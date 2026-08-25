# 0006. Replace the apisix-ingress-controller image with a source-compiled self-build

- Status: Accepted

## Decision

The apisix-ingress-controller image is built here. The build definition is
[images/apisix-ingress-controller/](../../images/apisix-ingress-controller/) — the
commit the upstream v2.1.0 tag points at is compiled as-is, with only the vulnerable
transitive dependencies (`golang.org/x/net`, `golang.org/x/text`,
`google.golang.org/grpc`, `go.opentelemetry.io/otel`, `otel/sdk`) force-upgraded via
`go get` plus `go mod tidy`. This is a single-module project with no `go.work`
workspace, so it cannot be handled with one global `replace` line the way
[0003](0003-etcd-image-self-build.md) (etcd) was. The final runtime base is SUSE BCI
(`bci-micro`) — the same pattern as
[0002](0002-cloudnative-pg-operator-self-build.md) and
[0003](0003-etcd-image-self-build.md).

## Context

Even on the latest tag (v2.1.0), most of the gate-blocking CVEs in the upstream image
came not from OS packages but from **Go module versions statically linked** into the
binary (the evidence at the time: CVE-2026-25681/27136/39821 and others in
`golang.org/x/net`, CVE-2026-56852 in `golang.org/x/text`, CVE-2026-33186
(GHSA-hrxh-6v49-42gf) in `google.golang.org/grpc`, CVE-2026-29181 in
`go.opentelemetry.io/otel`, CVE-2026-39883 in `otel/sdk` — the gate re-measures current
state on every run).

Moving to a newer tag was unavailable (already on the latest). The upstream base is
`gcr.io/distroless/cc-debian12` (distroless-family, almost no OS packages), so a base OS
swap alone would not resolve it either. On top of that, this project has no maintenance
branch — only `master` — so moving to `master` HEAD would pull in post-tag feature
commits, contradicting the minimal-diff principle (docs/image-authoring/README.md).
Nothing but a self-build could respond immediately.

## Rationale

- **After force-upgrading the vulnerable modules with `go get` plus `go mod tidy`, the
  gate was confirmed to flip to PASS.** The exact CVE list and counts are re-produced by
  the scan on every build, so they are not recorded here as a snapshot.
- **`go.opentelemetry.io/otel` core and `otel/sdk` must have matching versions** — both
  modules have to be specified together for `go mod tidy` to settle on a compatible
  combination. This requires naming more modules than the one-line global `replace`
  pattern of [0003](0003-etcd-image-self-build.md).
- **Functional verification passed** (binary execution, `version --long` reflecting the
  pinned commit — confirming ldflags injection, `--help` exiting cleanly, running as
  nonroot 65532:65532). Because a passing gate does not prove the image works, this is
  checked by `images/apisix-ingress-controller/verify.sh`. The Kubernetes API server
  integration the controller needs to actually start is outside this smoke test's
  scope — deployment verification follows a separate procedure.
- **`CGO_ENABLED=0` produces a static binary, confirming no `cc` variant (with glibc) is
  needed** — standardising on `bci-micro` costs nothing.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md),
  [0002](0002-cloudnative-pg-operator-self-build.md), and
  [0003](0003-etcd-image-self-build.md).
- **A person updates `SOURCE_COMMIT` and the minimum versions of the vulnerable
  modules.** They are not tracked automatically — `GO_BUILDER_TAG` candidates come from
  `scripts/build/suggest-go-upgrades.py`, but applying them means a person opening a PR,
  and that is the update trigger.
- **This self-build must be re-evaluated at every patch release** — with no maintenance
  branch there is no "already-backported safe pickup point" (structurally the same cost
  as [0003](0003-etcd-image-self-build.md)).
- **This is a configuration upstream does not test.** A BCI-based build is not in
  apisix-ingress-controller's CI matrix.
- **Whether the force-upgrade reached the actual binary was only confirmed indirectly,
  through the SBOM scan and version string** — deployment verification including real
  Kubernetes API integration has not yet been performed as a separate procedure.

## Conditions for revisiting

- **If upstream ships a release resolving this CVE set, or creates a maintenance branch
  and backports to it** — moving to a newer tag becomes possible again, which takes
  priority over self-building.
- **If unexpected runtime problems appear on `bci-micro`** — promote to `bci-base` or
  reconsider another BCI variant (the same condition as
  [0002](0002-cloudnative-pg-operator-self-build.md)).
- **If separately managed deployment verification (starting up inside a real Kubernetes
  cluster) finds a problem with this self-built image.**
