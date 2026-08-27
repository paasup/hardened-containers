# kyverno-cli — self-built

English · [한국어](README.ko.md)

The kyverno CLI (`kubectl-kyverno` — `kyverno test`, `kyverno apply`, etc.), compiled
directly from upstream source. Which chart or environment this image is used by, and how
the tag gets rolled out, is not something this repository knows — it deals only with how
the image is made.

> This image is an **unofficial rebuild** of kyverno. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md) (covers all seven kyverno
images as one decision). Image selection rules and the build framework generally are
owned by [image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

The cause is exactly the one in
[images/kyverno/README.md](../kyverno/README.md#why-we-build-this-ourselves) — all seven
kyverno images are built by `ko` per `.ko.yaml`'s
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine` (a floating tag, not a digest,
tracking Alpine's unscannable rolling `edge` branch, for which trivy has no advisory
data). This is not a problem in this CLI image's own dependencies — the evidence and
measurements are in [ADR 0009](../../docs/decisions/0009-kyverno-self-build.md).

The cause is the base image, not OS packages — `kubectl-kyverno` is statically linked
(`CGO_ENABLED=0`) too, so compiling ourselves is a complete fix. Exact CVE counts are
re-measured by `scan-image.sh`/`image-gate.py` on every build (see "Building and
verifying").

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base image | `ghcr.io/wolfi-dev/static:alpine` (ko's default, unpinned Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | This repository uses SUSE BCI only (rule 2). The binary is statically linked (`CGO_ENABLED=0`), so no shell or package manager is needed |
| `golang.org/x/mod` | Version pinned in go.mod | Force-upgraded to `v0.40.0` | CVE-2026-56864, CVE-2026-56865 — same go.mod as images/kyverno/ (single-module repository), so the same vulnerable module applies here too |
| Source directory | `cmd/cli/kubectl-kyverno` (nested one level deeper than the other six kyverno binaries) | Built from that same path | Upstream's own layout — Makefile's `CLI_DIR` |
| Binary name | `kubectl-kyverno` (kubectl-plugin convention) | Kept as-is | Reproduces Makefile's `CLI_BIN := $(CLI_DIR)/kubectl-kyverno` exactly — not renamed to `cli` or `kyverno-cli` |
| Entrypoint path | ko's internal path (`/ko-app/cli`-style) | `/app/kubectl-kyverno` | Standalone CLI, not a chart-deployed controller, so no `command:`/`args:` compatibility concern applies here |

`SOURCE_COMMIT` and `GO_MODULE_UPGRADES` are not tracked automatically — someone reading
a new kyverno tag and editing `source.build.env` to open a PR is itself the update
trigger (same as all seven images — see
[images/kyverno/README.md](../kyverno/README.md)). This gap is not a kyverno release
problem but a wolfi-dev base problem, so the usual "upstream will fix it in the next
release" condition does not apply — the condition for revisiting is
`ghcr.io/wolfi-dev/static:alpine` resolving to, and staying on, a numbered Alpine release
trivy actually covers.

No `cve-exceptions.json` entry currently targets this image — the one force-upgrade
above is what flips the gate to PASS.

## Building and verifying

```sh
IMAGE=kyverno-cli BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.

`verify.sh` checks more than `images/kyverno/`'s controller image does. A controller
cannot do anything beyond `--help` without a Kubernetes API server connection, but this
is a standalone cobra CLI (`cmd/cli/kubectl-kyverno/commands/command.go`) with a real,
side-effect-free `version` subcommand. So `verify.sh` checks the binary exists and runs,
that it runs as nonroot (`65532:65532`), that `--help` exits cleanly (0), **and** that
`kubectl-kyverno version` also exits 0 and its output actually reflects the pinned
`APP_VERSION` (via `pkg/version.BuildVersion` — the same ldflags symbol
`images/kyverno/` relies on). `kyverno test` / `kyverno apply` are not exercised — both
need policy/resource input to do anything meaningful, which is outside a smoke test's
scope.

**A pitfall hit during this build — same root cause as `images/kyverno/`**: a
false-positive Go module version self-stamp occurs if `--keep-git-dir=true` is used on
the git ADD (BuildKit's git context does not fetch tag refs for a pinned-commit
checkout, so Go stamps a low pseudo-version and trivy false-flags every historical
`github.com/kyverno/kyverno` CVE against it). See
[images/kyverno/README.md](../kyverno/README.md#building-and-verifying) for the full
explanation — not repeated here. This image's `source.Dockerfile` never used
`--keep-git-dir=true` in the first place.

Read the result from `cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `trivy-reports/*.json` reads `ok` — `none` means the zero findings
were not a measurement but an absence of scanner data for that distribution.

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag, vulnerable-module minimum versions. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and injects a guest shell script via `docker run --entrypoint bash` (`bci-micro` has bash and coreutils) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/kyverno-cli:v1.19.0-security-hardened-20260827
                       └ app  ┘└ slug  ┘└hardened┘└ build date ┘
```
