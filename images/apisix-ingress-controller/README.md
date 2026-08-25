# apisix-ingress-controller — self-built

English · [한국어](README.ko.md)

The apisix-ingress-controller binary, compiled directly from upstream source. Which
chart or environment this image is used by, and how the tag gets rolled out, is not
something this repository knows — it deals only with how the image is made.

> This image is an **unofficial rebuild** of Apache APISIX Ingress Controller. It is not
> affiliated with, endorsed by, or supported by the upstream project. See
> [NOTICE](../../NOTICE) for trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0006](../../docs/decisions/0006-apisix-ingress-controller-self-build.md); image
selection rules and the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Even though the upstream image is on the latest tag, most of the CVEs blocking the gate
come from the versions of Go modules **statically linked** into the binary rather than
from OS packages (stdlib, `golang.org/x/net`, `golang.org/x/text`,
`google.golang.org/grpc`, `go.opentelemetry.io/otel` and `otel/sdk`). Moving to a newer
tag cannot resolve them, and because the upstream base is distroless-family (almost no OS
packages) a base OS swap does not resolve them either — recompiling from source with the
vulnerable modules raised to their minimum compatible versions is the only response.

The exact CVE list and counts are re-produced by `scan-image.sh` and `image-gate.py` on
every build — see "Building and verifying" below.

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Application code | The release tag as-is | Identical (the tag as-is) | This project has no maintenance branch, only `master`, so moving to `master` HEAD would mix in new feature commits and violate the minimal-diff principle. The tag is kept and only the vulnerable modules are force-upgraded |
| Transitive dependencies | The versions pinned in go.mod | Raised to their minimum compatible versions with `go get` plus `go mod tidy` | This is a single-module project with no `go.work` workspace, so one global `replace` line is not enough — several modules must be specified together (otel core and sdk in particular must have matching versions), and `go get` settles the remaining compatible versions |
| Final base image | `gcr.io/distroless/cc-debian12` | `registry.suse.com/bci/bci-micro:15.7` | These images use SUSE BCI only ([docs/image-authoring/](../../docs/image-authoring/README.md) rule 2). The binary is statically linked with `CGO_ENABLED=0`, so the `cc` variant that bundles glibc was never needed — with no advantage over `static`, we standardise on `bci-micro` |

`SOURCE_COMMIT` and the dependency minimum versions are not tracked automatically.
Someone reading a new upstream tag (or a commit that already resolves the CVE) and
editing `source.build.env` to open a PR is itself the update trigger. If upstream ships a
release or a maintenance branch that resolves these CVEs, moving to it always takes
priority over keeping this self-build.

## Building and verifying

```sh
# local build (no push)
IMAGE=apisix-ingress-controller BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=apisix-ingress-controller BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** `verify.sh` checks that the binary runs, that `version --long` output
actually reflects the pinned commit (confirming ldflags injection), that `--help` exits
cleanly, and that the image runs as `65532:65532` (nonroot). Actually starting this
controller requires a connection to a Kubernetes API server, which is outside this smoke
test's scope — deployment verification follows a separate procedure.

Read the result from `/tmp/out/cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `/tmp/out/trivy-reports/*.json` reads `ok` — `none` means the zero
findings were not a measurement but an absence of scanner data for that distribution. The
verdict logic is described in
[docs/image-authoring/](../../docs/image-authoring/README.md).

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag, vulnerable-module minimum versions. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and injects a guest shell script via `docker run --entrypoint sh` (`bci-micro` has bash and coreutils) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/apisix-ingress-controller:2.1.0-security-hardened-20260811
                                      └ app ┘└ slug ┘└hardened┘└ build date ┘
```
