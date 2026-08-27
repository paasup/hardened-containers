# readiness-checker — self-built

English · [한국어](README.ko.md)

A small helper binary kyverno's other controllers use as a readiness/liveness probe
helper (`kyverno/readiness-checker` upstream) — it has no controller logic of its own; it
just checks whether a Service has ready endpoints (`check-endpoints`), polls an HTTP URL
until it returns 200 (`check-http`), scales a group of deployments
(`scale-deploy`), or deletes kyverno-managed webhooks (`delete-webhooks`), then exits.
Which chart or environment this image is used by, and how the tag gets rolled out, is not
something this repository knows — it deals only with how the image is made.

> This image is an **unofficial rebuild** of kyverno. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md) — this image is one of the
seven kyverno self-builds that ADR covers. Image selection rules and the build framework
generally are owned by [image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Same root cause as [images/kyverno/](../kyverno/README.md#why-we-build-this-ourselves):
kyverno ships no Dockerfile — all seven of its images, this one included, are built by
`ko` per `.ko.yaml`'s `defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`, a floating tag
with no Alpine version pin that defaults to Alpine's rolling `edge` branch, which trivy's
advisory database does not cover (`CoverageProbe: none`, confirmed by direct measurement
against that base image). The cause is the base image, not this binary's own
dependencies — this binary is statically linked (`CGO_ENABLED=0`, upstream's own
Makefile), so compiling ourselves onto SUSE BCI is a complete fix. See
`images/kyverno/README.md` for the full evidence (`.ko.yaml` diff, `/etc/os-release`
reading, rebuild-cadence check); it is not repeated per image here.

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base image | `ghcr.io/wolfi-dev/static:alpine` (ko's default, unpinned Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | This repository uses SUSE BCI only (rule 2). The binary is statically linked (`CGO_ENABLED=0`), so no shell or package manager is needed |
| Entrypoint path | ko's internal path (`/ko-app/readiness-checker`-style) | `/app/readiness-checker` | kyverno's chart does not hardcode `command:`, only `args:`, so this does not change chart behaviour |

Unlike the kyverno controller binaries built in this repository (`kyverno`,
`background-controller`, `cleanup-controller`, `reports-controller`, `kyverno-cli`,
`kyvernopre`), this image needed **no** `GO_MODULE_UPGRADES` — see "Version management".

## Version management

- `SOURCE_COMMIT` is not tracked automatically — someone reading a new kyverno tag and
  editing `source.build.env` to open a PR is itself the update trigger. This is the same
  commit every kyverno image in this repository pins to, so it moves together with the
  other six.
- `GO_BUILDER_TAG` is semi-automatic — re-derive it with
  `scripts/build/suggest-go-upgrades.py`, do not hand-pick it.
- `GO_MODULE_UPGRADES` in `source.build.env` is intentionally empty. This binary's only
  non-stdlib imports are `k8s.io/apimachinery` and `k8s.io/client-go` (see
  `cmd/readiness-checker/main.go` upstream) — it does not reach `golang.org/x/mod`, the
  module the sibling kyverno controller binaries force-upgrade. This was verified by
  building with no upgrade and confirming `gate: PASS`, not assumed from the sibling
  images' build.env files. No `cve-exceptions.json` entry targets this image.
- **Condition for switching away from self-building**: `ghcr.io/wolfi-dev/static:alpine`
  resolving to, and staying on, a numbered Alpine release trivy actually covers. A newer
  kyverno tag does not help on its own — every kyverno version references the same
  unpinned base.

## Building and verifying

```sh
IMAGE=readiness-checker BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.

`verify.sh` checks that the binary exists and runs, that it runs as nonroot
(`65532:65532`), that the bare invocation (no subcommand) prints the expected usage
banner and exits 1 — this binary's own documented behaviour, not a failure — and that a
subcommand's `-h` (`check-endpoints -h`) prints that subcommand's flag usage and exits 0.
Unlike `images/kyverno/`'s cobra-based CLI, this binary is built on the plain `flag`
package with no top-level `--help`; each subcommand's own `flag.NewFlagSet(...,
flag.ExitOnError)` special-cases `-h`/`--help` to `os.Exit(0)` before the subcommand does
anything that would touch a Kubernetes API server or the network, which is what makes it
usable as a side-effect-free smoke test. Actually running a check (which needs either a
live Kubernetes API connection or a reachable HTTP endpoint) is outside this smoke test's
scope, same as `images/kyverno/`'s controller-startup caveat.

**Same pitfall as every other Go self-build here — no `--keep-git-dir=true` on the git
ADD.** Same root cause as
[images/kyverno/README.md](../kyverno/README.md#building-and-verifying): BuildKit's git
context does not fetch tag refs when checking out a pinned commit, so keeping `.git`
around makes Go's VCS build-info stamping fall back to a low pseudo-version instead of
`v1.19.0`, which caused trivy to flag 15 already-fixed `github.com/kyverno/kyverno` CVEs
as still present on the `kyverno` image before that flag was dropped there. This
Dockerfile skips `--keep-git-dir=true` from the start, so the trap was not re-hit here —
see that README for the full measured explanation.

Read the result from `cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `trivy-reports/*.json` reads `ok` — `none` means the zero findings
were not a measurement but an absence of scanner data for that distribution.

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag, vulnerable-module minimum versions (currently none). Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and injects a guest shell script via `docker run --entrypoint bash` (`bci-micro` has bash and coreutils) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/readiness-checker:v1.19.0-security-hardened-20260827
                              └ app  ┘└ slug  ┘└hardened┘└ build date ┘
```
