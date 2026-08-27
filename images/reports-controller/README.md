# reports-controller — self-built

English · [한국어](README.ko.md)

The kyverno policy-report aggregation controller binary, compiled directly from
upstream source. Which chart or environment this image is used by, and how the tag gets
rolled out, is not something this repository knows — it deals only with how the image
is made.

> This image is an **unofficial rebuild** of kyverno. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md) — it covers all seven images
kyverno builds with `ko` (`kyverno`, `kyverno-cli`, `kyvernopre`,
`background-controller`, `cleanup-controller`, `reports-controller`,
`readiness-checker`), and the root cause and investigation are identical to
`images/kyverno/README.md`. Image selection rules and the build framework generally are
owned by [image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

kyverno ships no Dockerfile — all seven of its images are built by `ko` per `.ko.yaml`'s
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`. That reference is a **floating tag,
not a digest**, and the image itself pins no specific Alpine release, so it defaults to
Alpine's rolling `edge` branch. trivy's official Alpine advisory database only covers
numbered releases, never `edge`. The measured evidence (`.ko.yaml` identical across
versions, `/etc/os-release`'s `edge` marker, the coverage self-check returning
`CoverageProbe: none`) is in `images/kyverno/README.md` in full — it is a base-image
problem, so it applies identically to all seven images.

The cause is the base image, not OS packages — reports-controller's binary is
statically linked (`CGO_ENABLED=0`), same as every other kyverno binary, so compiling
ourselves is a complete fix. Exact CVE counts are re-measured by
`scan-image.sh`/`image-gate.py` on every build (see "Building and verifying").

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base image | `ghcr.io/wolfi-dev/static:alpine` (ko's default, unpinned Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | This repository uses SUSE BCI only (rule 2). The binary is statically linked (`CGO_ENABLED=0`), so no shell or package manager is needed |
| `golang.org/x/mod` | Version pinned in go.mod | Force-upgraded to `v0.40.0` | CVE-2026-56864, CVE-2026-56865 — effective severity HIGH, affects every binary sharing kyverno's single go.mod, same as `images/kyverno` |
| Entrypoint path | ko's internal path (`/ko-app/reports-controller`-style) | `/app/reports-controller` | kyverno's chart does not hardcode `command:`, only `args:`, so this does not change chart behaviour |

## Version management

`SOURCE_COMMIT` and `GO_MODULE_UPGRADES` are not tracked automatically — someone reading
a new kyverno tag and editing `source.build.env` to open a PR is itself the update
trigger. This gap is not a kyverno release problem but a wolfi-dev base problem, so the
usual "upstream will fix it in the next release" condition does not apply — the
condition for revisiting is `ghcr.io/wolfi-dev/static:alpine` resolving to, and staying
on, a numbered Alpine release trivy actually covers. `GO_BUILDER_TAG` is derived
semi-automatically with `suggest-go-upgrades.py` (not fully manual).

No `cve-exceptions.json` entry currently targets this image — the one force-upgrade
above is what flips the gate to PASS.

## Building and verifying

```sh
IMAGE=reports-controller BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict. `verify.sh` checks that the binary exists and runs, that it runs as
nonroot (`65532:65532`), and that `--help` exits cleanly (0). `cmd/reports-controller`
uses the standard `flag` package (`flag.ExitOnError`), same as kyverno's other
controllers, so `--help` exits 0 without needing a Kubernetes API connection. Actually
starting the controller requires a connection to a Kubernetes API server, which is
outside this smoke test's scope — deployment verification follows a separate procedure.

**Why `--keep-git-dir=true` is not used**: same root cause as
`images/kyverno/README.md`'s "Building and verifying" section — BuildKit's git context
only checks out the pinned commit and does not fetch tag refs, so keeping `.git` makes
Go auto-stamp the main module version as a low pseudo-version, which trivy then
compares historical CVEs against and produces false positives. This Dockerfile never
kept `.git` in the first place, so it did not hit that trap.

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
<registry>/reports-controller:v1.19.0-security-hardened-20260827
                                └ app  ┘└ slug  ┘└hardened┘└ build date ┘
```
