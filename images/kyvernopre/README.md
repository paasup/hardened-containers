# kyvernopre — self-built

English · [한국어](README.ko.md)

The kyverno init/migration job binary (`kyvernopre`), compiled directly from upstream
source. It runs once at Helm install/upgrade time — cleaning up stale
webhookconfigurations kyverno left behind — then exits. Which chart or environment this
image is used by, and how the tag gets rolled out, is not something this repository
knows — it deals only with how the image is made.

> This image is an **unofficial rebuild** of kyverno. It is not affiliated with,
> endorsed by, or supported by the upstream project. See [NOTICE](../../NOTICE) for
> trademark and licensing notices.

The decision, the candidates compared, and the costs accepted are in
[ADR 0009](../../docs/decisions/0009-kyverno-self-build.md) (covers all seven kyverno
images as one decision); image selection rules and the build framework generally are
owned by [image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

Same root cause as [`images/kyverno/README.md`](../kyverno/README.md): kyverno ships no
Dockerfile — all seven of its images (`kyvernopre` included) are built by `ko` per
`.ko.yaml`'s `defaultBaseImage: ghcr.io/wolfi-dev/static:alpine`, a **floating tag, not a
digest**, that resolves to Alpine's unscannable rolling `edge` branch. trivy's official
Alpine advisory database only covers numbered releases, never `edge`. The full
investigation (byte-identical `.ko.yaml` across versions, the `VERSION_ID` measurement,
the daily-rebuild-yet-unchanged-marker observation, the `CoverageProbe: none` direct
measurement) is in `images/kyverno/README.md` and ADR 0009 — not re-run per image, since
all seven images share the exact same base image and `.ko.yaml`.

The cause is the base image, not OS packages or this binary's own code — `kyvernopre` is
statically linked (`CGO_ENABLED=0`, same as every kyverno binary), so compiling ourselves
is a complete fix. Exact CVE counts are re-measured by `scan-image.sh`/`image-gate.py` on
every build (see "Building and verifying").

## Differences from upstream

| Item | Upstream | This image | Reason |
| --- | --- | --- | --- |
| Final base image | `ghcr.io/wolfi-dev/static:alpine` (ko's default, unpinned Alpine edge) | `registry.suse.com/bci/bci-micro:15.7` | This repository uses SUSE BCI only (rule 2). The binary is statically linked (`CGO_ENABLED=0`), so no shell or package manager is needed |
| Source directory naming | Binary/image name is `kyvernopre`, but the source lives at upstream `cmd/kyverno-init` (not `cmd/kyvernopre`) | Same source directory compiled (`./cmd/kyverno-init`), output named `kyvernopre` — matches upstream Makefile's `KYVERNOPRE_BIN := $(KYVERNOPRE_DIR)/kyvernopre` exactly | Not a deviation, just a naming mismatch worth recording so nobody goes looking for a `cmd/kyvernopre` directory that doesn't exist |
| Entrypoint path | ko's internal path (`/ko-app/kyvernopre`-style) | `/app/kyvernopre` | kyverno's chart does not hardcode `command:` for the init container, only `args:`, so this does not change chart behaviour |
| `golang.org/x/mod` | Version pinned in go.mod | Force-upgraded to `v0.40.0` | CVE-2026-56864, CVE-2026-56865 — effective severity HIGH. Same fix as `images/kyverno/`, confirmed independently: the module shows up in this binary's own SBOM (not assumed from the kyverno result) |

`SOURCE_COMMIT` is not tracked automatically — someone reading a new kyverno tag and
editing `source.build.env` to open a PR is itself the update trigger, same as every other
kyverno image (see `images/kyverno/README.md`).

No `cve-exceptions.json` entry currently targets this image — the one force-upgrade above
is what flips the gate to PASS, same as `images/kyverno/`.

## Building and verifying

```sh
IMAGE=kyvernopre BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict. `verify.sh` checks that the binary exists and runs, that it runs as
nonroot (`65532:65532`), and that `--help` exits cleanly (0). `kyvernopre` is a one-shot
init job — it acquires a lease and cleans up stale kyverno webhookconfigurations, which
requires a connection to a Kubernetes API server. That is outside this smoke test's
scope, same as the kyverno controller's `verify.sh` — deployment verification follows a
separate procedure.

This build uses the same `.git`-dir omission as every other kyverno image here (same root
cause as `images/kyverno/README.md`'s "Building and verifying" section — keeping `.git`
on a pinned-commit-only git context makes Go stamp a bogus low pseudo-version, which
trivy then compares against and false-flags historical `github.com/kyverno/kyverno`
CVEs). `source.Dockerfile` already omits `--keep-git-dir=true`, so this was not
rediscovered the hard way here.

Read the result from `cve-gate.md`. Even when the gate passes, check that
`CoverageProbe` in `trivy-reports/*.json` reads `ok` — `none` means the zero findings
were not a measurement but an absence of scanner data for that distribution.

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and injects a guest shell script via `docker run --entrypoint bash` (`bci-micro` has bash and coreutils) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/kyvernopre:v1.19.0-security-hardened-20260827
                      └ app  ┘└ slug  ┘└hardened┘└ build date ┘
```
