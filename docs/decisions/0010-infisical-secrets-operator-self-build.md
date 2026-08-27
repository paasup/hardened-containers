# 0010. Replace the infisical-secrets-operator image with a source-compiled self-build

- Status: Accepted

## Decision

The `infisical/kubernetes-operator` image (Infisical's Kubernetes Secrets Operator) is
built here as `infisical-secrets-operator`. The build definition is
[images/infisical-secrets-operator/](../../images/infisical-secrets-operator/) — the
commit the upstream `infisical-k8-operator/v0.11.8` tag points at is compiled as-is, with
only the vulnerable transitive dependencies (`golang.org/x/net`, `golang.org/x/text`,
`google.golang.org/grpc`) force-upgraded via `go get` plus `go mod tidy`, and the Go
toolchain raised past the fixed stdlib versions. This is a single-module project with no
`go.work` workspace, so it is handled the same way as
[0006](0006-apisix-ingress-controller-self-build.md) (apisix-ingress-controller), not
with etcd's one-line global `replace`
([0003](0003-etcd-image-self-build.md)). The final runtime base is SUSE BCI
(`bci-micro`) — the same pattern as
[0002](0002-cloudnative-pg-operator-self-build.md),
[0003](0003-etcd-image-self-build.md), and
[0006](0006-apisix-ingress-controller-self-build.md).

## Context

This image is consumed by the sibling repository `dip-catalog`'s `secrets-operator`
Helm chart. Even on the latest tag (`v0.11.8`), the gate-blocking CVEs in the upstream
image came not from OS packages but from **Go module and stdlib versions statically
linked** into the binary (the evidence at the time: CVE-2026-46600 in
`golang.org/x/net`, CVE-2026-56852 in `golang.org/x/text`, CVE-2026-33186
(GHSA-hrxh-6v49-42gf) in `google.golang.org/grpc`, and a cluster of stdlib CVEs
including CVE-2026-33818/-39821/-56853/-56858/-56859/-56860/-56862 — the gate
re-measures current state on every run).

Moving to a newer tag was unavailable — confirmed via both Docker Hub and the upstream
GitHub tag list that `v0.11.8` is the newest release. Upstream's own final base is
`gcr.io/distroless/static:nonroot` (distroless-family, effectively no OS packages), so a
base OS swap alone would not resolve it either — the vulnerable code is compiled into
the binary regardless of what it sits on. Nothing but a self-build could respond
immediately.

## Rationale

- **After force-upgrading the vulnerable modules with `go get` plus `go mod tidy` and
  raising the builder's Go toolchain, the gate is expected to flip to PASS** — confirmed
  by a local build (`build-hardened-image.sh`); the exact CVE list and counts are
  re-produced by the scan on every build, so they are not recorded here as a snapshot.
- **The upstream Dockerfile is a plain two-stage build with no cgo and no native
  dependencies** (`CGO_ENABLED=0 go build cmd/main.go`, already parameterized on
  `TARGETOS`/`TARGETARCH`) — the smallest-surface case this repository's Go self-build
  pattern targets. MIT licensed, safe to rebuild and redistribute.
- **Functional verification** (binary present and executable, the ldflags-injected
  version reaching the compiled binary — confirmed via the baked-in HTTP User-Agent
  token rather than a `--version` flag, since upstream's `main.go` exposes none —
  `--help` exiting cleanly, and running as nonroot `65532:65532`) is checked by
  `images/infisical-secrets-operator/verify.sh`. The Kubernetes API server connection the
  operator needs to actually reconcile is outside this smoke test's scope — deployment
  verification (installing alongside `infisical-standalone` and confirming an
  `InfisicalSecret` reconciles) follows a separate procedure.
- **`CGO_ENABLED=0` produces a static binary, confirming no glibc-bearing variant is
  needed** — standardising on `bci-micro` costs nothing.

## Costs accepted

- **Upstream signatures, provenance, and SBOM attestation are lost.** The same cost as
  [0001](0001-cnpg-postgresql-image.md) through
  [0009](0009-kyverno-self-build.md).
- **A person updates `SOURCE_COMMIT`, the Go toolchain pin, and the minimum versions of
  the vulnerable modules.** They are not tracked automatically —
  `scripts/build/suggest-go-upgrades.py` derives candidates, but applying them means a
  person opening a PR, and that is the update trigger.
- **This is a configuration upstream does not test.** A BCI-based build is not in
  `infisical/kubernetes-operator`'s own CI matrix.
- **Deployment verification (real Kubernetes API integration, an actual
  `InfisicalSecret` reconciling) has not yet been performed as a separate procedure** —
  only confirmed indirectly through the SBOM scan and the User-Agent string.

## Conditions for revisiting

- **If upstream ships a release resolving this CVE set** — moving to a newer tag
  becomes possible again, which takes priority over self-building.
- **If unexpected runtime problems appear on `bci-micro`** — promote to `bci-base` or
  reconsider another BCI variant (the same condition as
  [0002](0002-cloudnative-pg-operator-self-build.md)).
- **If separately managed deployment verification (installing this image alongside
  `infisical-standalone` in a real cluster) finds a problem.**
