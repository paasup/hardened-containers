# infisical-secrets-operator — self-built

English · [한국어](README.ko.md)

The Infisical Kubernetes Secrets Operator (`infisical/kubernetes-operator`) binary,
compiled directly from upstream source. Which chart or environment this image is used
by, and how the tag gets rolled out, is not something this repository knows — it deals
only with how the image is made (for reference, this image is consumed by the sibling
repository `dip-catalog`'s `secrets-operator` chart).

> This image is an **unofficial rebuild** of the Infisical Kubernetes Operator. It is
> not affiliated with, endorsed by, or supported by the upstream project. See
> [NOTICE](../../NOTICE) for trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0010](../../docs/decisions/0010-infisical-secrets-operator-self-build.md); image
selection rules and the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Even on the latest tag (`v0.11.8`), every CVE blocking the gate comes not from OS
packages but from **stdlib and Go module versions statically linked** into the binary
(stdlib, `golang.org/x/net`, `golang.org/x/text`, `google.golang.org/grpc`). Moving to a
newer tag is unavailable — confirmed via both Docker Hub and the upstream GitHub tag
list that `v0.11.8` is the newest release. Upstream's own final base is
`gcr.io/distroless/static:nonroot` (distroless-family, effectively no OS packages), so a
base OS swap alone does not resolve it either — recompiling from source with the
vulnerable modules raised to their minimum compatible versions, and the builder's Go
toolchain raised past the stdlib fix, is the only response.

The exact CVE list and counts are re-produced by `scan-image.sh` and `image-gate.py` on
every build — see "Building and verifying" below.

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Application code | The release tag (`infisical-k8-operator/v0.11.8`) as-is | Identical (the tag as-is) | MIT licensed, single-module project. No code changes — only dependencies are force-upgraded |
| Transitive dependencies | The versions pinned in go.mod (`x/net` 0.55.0 · `x/text` 0.37.0 · `grpc` 1.79.3) | Raised to their minimum compatible versions with `go get` plus `go mod tidy` | This is a single-module project with no `go.work` workspace, so one global `replace` line is not enough — several modules must be specified together, and `go get` settles the remaining compatible versions (same pattern as apisix-ingress-controller, ADR 0006) |
| Go toolchain | `golang:1.25` (go.mod requires `go 1.25.0`) | Raised past the stdlib fix version via `GO_BUILDER_TAG` | Stdlib CVEs are a toolchain problem, not a module, so they are tracked separately |
| Final base image | `gcr.io/distroless/static:nonroot` | `registry.suse.com/bci/bci-micro:15.7` | These images use SUSE BCI only ([docs/image-authoring/](../../docs/image-authoring/README.md) rule 2). The binary is statically linked with `CGO_ENABLED=0`, so no glibc-bearing variant was ever needed |

`SOURCE_COMMIT`, the Go toolchain tag, and the dependency minimum versions are not
tracked automatically. Someone reading a new upstream tag (or a commit that already
resolves the CVE) and editing `source.build.env` to open a PR is itself the update
trigger. `GO_BUILDER_TAG` candidates come from
`scripts/build/suggest-go-upgrades.py`, but applying them means a person reviewing and
committing. If upstream ships a release that resolves these CVEs, moving to it always
takes priority over keeping this self-build.

No `cve-exceptions.json` entry currently targets this image — every CVE above is
resolved by a version bump, not an accepted-risk exception.

## Building and verifying

```sh
# local build (no push)
IMAGE=infisical-secrets-operator BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=infisical-secrets-operator BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** `verify.sh` checks that the binary runs, that the ldflags-injected
version actually reached the compiled binary (via the baked-in HTTP User-Agent token,
since upstream's `main.go` exposes no `--version` flag), that `--help` exits cleanly,
and that the image runs as `65532:65532` (nonroot). This operator needs a connection to
a Kubernetes API server to actually start and reconcile, which is outside this smoke
test's scope — deployment verification (installing alongside `infisical-standalone` and
confirming an `InfisicalSecret` actually syncs) follows a separate procedure.

Read the result from `/tmp/out/cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `/tmp/out/trivy-reports/*.json` reads `ok` — `none` means the zero
findings were not a measurement but an absence of scanner data for that distribution.
The verdict logic is described in
[docs/image-authoring/](../../docs/image-authoring/README.md).

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag, vulnerable-module minimum versions. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and extracts the binary to the host via `docker create`/`docker cp` for inspection (`bci-micro` has no grep) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/infisical-secrets-operator:v0.11.8-security-hardened-20260827
                                       └  app  ┘└ slug ┘└hardened┘└ build date ┘
```

## Not done yet — deployment verification

`verify.sh` only checks binary execution, ldflags injection, and nonroot. Installing this
image alongside `infisical-standalone` in a real Kubernetes cluster and confirming an
`InfisicalSecret` CRD actually syncs a secret has not been done yet.
