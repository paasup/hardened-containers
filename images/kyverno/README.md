# kyverno — self-built

English · [한국어](README.ko.md)

The kyverno main controller binary, compiled directly from upstream source. Which chart
or environment this image is used by, and how the tag gets rolled out, is not something
this repository knows — it deals only with how the image is made.

> This image is an **unofficial rebuild** of kyverno. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md); image selection rules and
the build framework generally are owned by
[image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

kyverno ships no Dockerfile — all seven of its images are built by `ko` per `.ko.yaml`'s
`defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`. That reference is a **floating tag,
not a digest**, and the image itself pins no specific Alpine release, so it defaults to
Alpine's rolling `edge` branch. trivy's official Alpine advisory database only covers
numbered releases, never `edge`.

This was confirmed, not inferred:

- `.ko.yaml` is byte-for-byte identical between kyverno v1.18.2 (scans cleanly) and
  v1.19.0 (blocked) — the difference is entirely what the floating tag resolved to at
  each build time, not anything in kyverno's own repository.
- Pulling `ghcr.io/wolfi-dev/static:alpine` and reading `/etc/os-release` gives
  `VERSION_ID=3.25.0_alpha20260805` — a real Alpine edge pre-release marker, not
  corrupted metadata.
- That tag is rebuilt daily (`wolfi-dev/tools`' `release.yaml`, 01:00 UTC cron), yet the
  `VERSION_ID` stayed unchanged across a full week (2026-08-20 through 2026-08-27) —
  packages update daily, the pre-release marker only when Alpine's own release
  engineering moves it.
- Running this repository's own coverage self-check
  (`scripts/gate/scan-image.sh`'s probe, the same technique dip-catalog's `sbom.yml`
  uses) against that base image directly still returns `CoverageProbe: none`.

With no branch pin in its apko config, this base keeps tracking `edge` — there is no
guarantee waiting for the next kyverno release fixes it. A newer tag does not help
(v1.19.0 is already newest), and neither does swapping the base (every version
references the same unpinned one). Compiling ourselves is the only immediate answer.

The cause is the base image, not OS packages — kyverno's binaries are statically linked
(`CGO_ENABLED=0`), so compiling ourselves is a complete fix. Exact CVE counts are
re-measured by `scan-image.sh`/`image-gate.py` on every build (see "Building and
verifying").

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base image | `ghcr.io/wolfi-dev/static:alpine` (ko's default, unpinned Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | This repository uses SUSE BCI only (rule 2). The binary is statically linked (`CGO_ENABLED=0`), so no shell or package manager is needed |
| `golang.org/x/mod` | Version pinned in go.mod | Force-upgraded to `v0.40.0` | CVE-2026-56864, CVE-2026-56865 — effective severity HIGH |
| Entrypoint path | ko's internal path (`/ko-app/kyverno`-style) | `/app/kyverno` | kyverno's chart does not hardcode `command:`, only `args:`, so this does not change chart behaviour |

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
IMAGE=kyverno BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict. `verify.sh` checks that the binary exists and runs, that it runs as
nonroot (`65532:65532`), and that `--help` exits cleanly (0). Actually starting the
controller requires a connection to a Kubernetes API server, which is outside this smoke
test's scope — deployment verification follows a separate procedure.

**A pitfall hit during this build — a false-positive Go module version self-stamp**:
the first attempt used `--keep-git-dir=true` on the git ADD, hoping to preserve
kyverno's own `pkg/version.Hash()`/`Time()` (which read Go's `runtime/debug.ReadBuildInfo`
VCS stamping). But BuildKit's git context only checks out the pinned commit — it does
not fetch tag refs — so `git describe` inside the container could not see the `v1.19.0`
tag, and Go auto-stamped the main module's version as a low pseudo-version instead
(`v0.0.0-20260820085256-ee97ce09538b`). trivy's Go binary scan compares against that
pseudo-version, so it flagged every historical `github.com/kyverno/kyverno` CVE fixed
before v1.17.0 as still unresolved — **15 false blocking findings** (measured — e.g.
`CVE-2026-22039`, all with fixed versions between 1.10.x and 1.17.0). Dropping the
`.git` dir (what `docs/image-authoring/builder-languages.md`'s Go section already
recommends — "we build without a `.git`, so we pass `SOURCE_COMMIT` explicitly") left
**2 real CVEs** (`golang.org/x/mod`). This is exactly why every other Go self-build here
skips `.git` — kyverno's build strayed from that for convenience and hit the same trap
directly. The cost is `pkg/version.Hash()`/`Time()` returning `"---"`;
`pkg/version.BuildVersion` (set via ldflags, what `verify.sh` and the chart-visible
version string actually use) is unaffected.

Read the result from `cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `trivy-reports/*.json` reads `ok` — `none` means the zero findings
were not a measurement but an absence of scanner data for that distribution (measured
here: `sles 15.7`, `CoverageProbe: ok` — this coverage was the entire point of this
self-build).

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag, vulnerable-module minimum versions. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and injects a guest shell script via `docker run --entrypoint bash` (`bci-micro` has bash and coreutils) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/kyverno:v1.19.0-security-hardened-20260827
                    └ app  ┘└ slug  ┘└hardened┘└ build date ┘
```
