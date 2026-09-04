# etcd — self-built

English · [한국어](README.ko.md)

The etcd server plus the `etcdctl` and `etcdutl` binaries, compiled directly from
upstream source.

> This image is an **unofficial rebuild** of etcd. It is not affiliated with, endorsed
> by, or supported by the upstream project. See [NOTICE](../../NOTICE) for trademark and
> licensing notices.

The decision and the costs accepted are in
[ADR 0003](../../docs/decisions/0003-etcd-image-self-build.md); the procedure for adding
a self-built image and the gate mechanism generally are owned by
[docs/image-authoring/](../../docs/image-authoring/README.md).

## Why we build this ourselves

The upstream release image is blocked at the gate by a CVE at blocking severity. The
module responsible is a **Go module statically linked into the binary**, such as
`golang.org/x/text`, and since there is neither a newer tag nor a maintenance-branch
backport, changing the tag cannot address it.

A base OS swap does not work either — the upstream published image's base is
distroless-family (effectively no OS packages), so the CVE lives inside the binary rather
than in an OS package. Raising the version of a statically linked module means
recompiling from source; nothing else does it.

This is the same class of problem as the `cloudnative-pg` operator self-build (the same
module at fault), and the response is the same — **orchestration shares the one
[scripts/build/build-hardened-image.sh](../../scripts/build/build-hardened-image.sh).**

## Differences from upstream

| Item | Upstream | Here | Reason |
| --- | --- | --- | --- |
| Build method | `ADD` prebuilt release binaries into the image | Compile from source at the pinned commit in `source.build.env` | Raising a statically linked Go module's version requires force-upgrading that module and rebuilding — copying a prebuilt binary cannot fix it |
| Final base | `gcr.io/distroless/static-debian12` | `registry.suse.com/bci/bci-micro` | These images use SUSE BCI only ([docs/image-authoring/](../../docs/image-authoring/README.md) rule 2) — the binary is statically linked with no runtime dependencies, so the lightest variant without a package manager suffices |
| Dependency pinning | Whatever each module's `go.mod` (`server`/`etcdctl`/`etcdutl`) specifies | Each `GO_MODULE_UPGRADES` entry turned into a workspace-wide `replace` in `go.work` | etcd manages the three binaries together as a Go workspace — `go get` applies only to the module it runs in, leaving the sibling modules vulnerable. A workspace-wide `replace` covers all three at once and keeps the divergence from upstream minimal |
| Version string (ldflags) | The GitSHA from `git rev-parse --short HEAD`, injected at build time | The full pinned commit hash, injected directly | Checkout happens through BuildKit's git context (`ADD ...#${SOURCE_COMMIT}`), so the commit is already known — the host-side `verify.sh` can then confirm the version string reflects the pinned commit without running git inside the container |

The builder stage (Go compilation) uses the official `golang` image as-is — it does not
survive into the final image, only the compiled artifacts move forward, so it is not
subject to scanning or policy. The rest of the build procedure (compiling `server`,
`etcdutl`, and `etcdctl` separately, statically linked with `CGO_ENABLED=0`) reproduces
`etcd_build()` from the upstream repository's `scripts/build_lib.sh` (unrelated to this
repository's `scripts/`).

`SOURCE_COMMIT` is **not tracked automatically.** Someone reading upstream's `release-3.7`
branch (or the next patch release tag) and editing `source.build.env` to open a PR is
itself the update trigger. If a newer release ships including this fix, moving to it
always takes priority over keeping this self-build.

`GO_MODULE_UPGRADES`, by contrast, **is tracked automatically.** When the daily rescan
finds drift, `suggest-go-upgrades.py --apply` raises the value and it arrives as an
`autofix/go-cves` pull request. The mechanism — a workspace-wide `replace` — is unchanged;
what matters is that the *values* sit in the same key every other Go image uses, because
`--apply` never adds a missing key. That is why the old `XTEXT_FIX_VERSION` became this.

## Building and verifying

```sh
# local build (no push)
IMAGE=etcd BASE_OS=source bash scripts/build/build-hardened-image.sh /tmp/out

# through to a registry push
IMAGE=etcd BASE_OS=source REGISTRY=<your-registry> \
  bash scripts/build/build-hardened-image.sh /tmp/out
```

The order is **build → functional verification (`verify.sh`) → SBOM → all-severity scan →
gate verdict.** `verify.sh` checks that `etcd`, `etcdctl`, and `etcdutl` are on PATH, that
`etcd --version` output actually reflects the pinned commit (confirming ldflags
injection), and that a single node starts up and an `etcdctl` put/get round trip really
works — multi-node quorum, TLS, and the like are outside this smoke test's scope, and
deployment verification follows a separate procedure.

Read the gate verdict from `cve-gate.md` — look at the coverage self-check
(`CoverageProbe`) as well as the effective C/H rating. If `CoverageProbe` reads `none`,
the scanner did not properly recognise this image's packages, so zero findings is not
really zero and the gate blocks. The verdict logic is described in
[docs/image-authoring/](../../docs/image-authoring/README.md).

### File layout

| File | Role |
| --- | --- |
| `source.Dockerfile` | Build definition — source compilation (builder stage) plus SUSE BCI (`bci-micro`) packaging (final stage) |
| `source.build.env` | Pinned commit, versions, builder image tag. Only names listed in `BUILD_ARGS` are passed as `--build-arg` |
| `verify.sh` | Functional verification. Runs on the host under bash and injects a guest shell script via `docker run --entrypoint sh` (`bci-micro` has bash and coreutils — the same pattern as `cnpg-postgresql/verify.sh`, unlike `cloudnative-pg`'s shell-less distroless) |

There is only one base variant, so the filenames are fixed at `source.*`.

### Tags

```
<registry>/etcd:3.7.1-security-hardened-20260731
                 └ app ┘└ slug ┘└hardened┘└ build date ┘
```

Once the build, gate PASS, and push complete, `published.json` records this tag — see
`MEMORY.md` for current state.
