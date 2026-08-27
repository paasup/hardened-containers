# cleanup-controller — self-built

English · [한국어](README.ko.md)

The kyverno cleanup-controller binary, compiled directly from upstream source. Which
chart or environment this image is used by, and how the tag gets rolled out, is not
something this repository knows — it deals only with how the image is made.

> This image is an **unofficial rebuild** of kyverno. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md); image selection rules and
the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Same root cause as [images/kyverno/](../kyverno/README.md) — all seven images kyverno
ships are built by `ko` per `.ko.yaml`'s `defaultBaseImage:
ghcr.io/wolfi-dev/static:alpine`, a floating tag with no Alpine version pin that tracks
Alpine's unscannable rolling `edge` branch. This is confirmed for the base image
generally, not this binary specifically — see ADR 0009 for the investigation and
`images/kyverno/README.md` for the measurements. It is not a per-binary problem, so it
is not re-investigated per binary.

The cause is the base image, not OS packages — this binary is statically linked
(`CGO_ENABLED=0`), so compiling ourselves is a complete fix. Exact CVE counts are
re-measured by `scan-image.sh`/`image-gate.py` on every build (see "Building and
verifying").

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base image | `ghcr.io/wolfi-dev/static:alpine` (ko's default, unpinned Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | This repository uses SUSE BCI only (rule 2). The binary is statically linked (`CGO_ENABLED=0`), so no shell or package manager is needed |
| `golang.org/x/mod` | Version pinned in go.mod | Force-upgraded to `v0.40.0` | CVE-2026-56864, CVE-2026-56865 — effective severity HIGH (same finding as `images/kyverno/`, since both share the same go.mod) |
| Entrypoint path | ko's internal path (`/ko-app/cleanup-controller`-style) | `/app/cleanup-controller` | kyverno's chart does not hardcode `command:`, only `args:`, so this does not change chart behaviour |

`SOURCE_COMMIT` and `GO_MODULE_UPGRADES` are not tracked automatically — someone reading
a new kyverno tag and editing `source.build.env` to open a PR is itself the update
trigger. This gap is not a kyverno release problem but a wolfi-dev base problem, so the
usual "upstream will fix it in the next release" condition does not apply — the
condition for revisiting is `ghcr.io/wolfi-dev/static:alpine` resolving to, and staying
on, a numbered Alpine release trivy actually covers.

No `cve-exceptions.json` entry currently targets this image — the one force-upgrade
above is what flips the gate to PASS.

## Building and verifying

```sh
IMAGE=cleanup-controller BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict. `verify.sh` checks that the binary exists and runs, that it runs as
nonroot (`65532:65532`), and that `--help` exits cleanly (0). Actually starting the
controller requires a connection to a Kubernetes API server, which is outside this smoke
test's scope — deployment verification follows a separate procedure.

**The `--keep-git-dir=true` pitfall**: same root cause as
[images/kyverno/README.md](../kyverno/README.md)'s "Building and verifying" section —
keeping `.git` on the git ADD makes BuildKit's git context skip fetching tag refs for a
pinned-commit checkout, so Go's VCS build-info stamping can't find the `v1.19.0` tag and
stamps a low pseudo-version instead, which trivy then compares against every historical
`github.com/kyverno/kyverno` CVE as if it were still present. This Dockerfile omits
`--keep-git-dir=true` from the start (not rediscovered here) — `pkg/version.Hash()`/
`Time()` return `"---"`; `pkg/version.BuildVersion` (set via ldflags, what `verify.sh`
and the chart-visible version string actually use) is unaffected.

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
<registry>/cleanup-controller:v1.19.0-security-hardened-20260827
                               └ app  ┘└ slug  ┘└hardened┘└ build date ┘
```
